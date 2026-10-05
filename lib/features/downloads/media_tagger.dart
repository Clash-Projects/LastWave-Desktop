import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// Embedded-metadata writer for downloaded audio.
///
/// Pure Dart, no native dependencies: desktop music clients tag downloads
/// with title / artist / album / lyrics / cover art, so LastWave does the
/// same instead of dumping raw stream bytes.
///
/// - YouTube Opus (WebM container) is remuxed into a standard Ogg Opus
///   `.opus` file: `OpusHead` (copied from the WebM `CodecPrivate`) +
///   `OpusTags` (Vorbis comments + `METADATA_BLOCK_PICTURE` cover) +
///   repackaged audio packets with correct granule positions.
/// - FLAC gets rebuilt `VORBIS_COMMENT` + `PICTURE` blocks (seektable is
///   dropped — its absolute offsets would be wrong after the rebuild).
/// - FLAC-in-MP4 (addon DASH assemblies: `iso8/mp41dashcmfc` with an
  ///   `fLaC` sample entry) is transmuxed into a native `.flac` file:
  ///   `STREAMINFO` from the `dfLa` box + raw FLAC frames from the
  ///   `mdat` boxes (sized by the `moof/traf/trun` entries), then tagged
  ///   via [tagFlac]. A bit-for-bit remux — no decode, still lossless.
/// - MP3 gets a fresh ID3v2.3 tag (`TIT2/TPE1/TALB/USLT/APIC`).
/// - M4A gets a `moov/udta/meta/ilst` tag (`©nam/©ART/©alb/©lyr/covr`)
///   with `stco/co64` offset fixup. Fragmented files without a `moov`
///   box are left untouched. FLAC-in-MP4 never stays `.m4a` — see
///   [remuxFlacInMp4ToFlac].
///
/// Every entry point throws [TaggerSkip] when the input is not in the
/// expected shape — callers must catch it and keep the untagged bytes
/// (a download must never be lost because tagging failed).
class DownloadTags {
  final String title;
  final String artist;
  final String album;
  final String lyrics;
  final Uint8List? coverBytes;
  final String coverMime;

  const DownloadTags({
    this.title = '',
    this.artist = '',
    this.album = '',
    this.lyrics = '',
    this.coverBytes,
    this.coverMime = '',
  });

  bool get hasCover =>
      coverBytes != null && coverBytes!.isNotEmpty && coverMime.isNotEmpty;
}

/// Thrown when tagging is impossible for an input (wrong container,
/// truncated file, ...). Not an error — the caller keeps raw bytes.
class TaggerSkip implements Exception {
  final String reason;
  const TaggerSkip(this.reason);
  @override
  String toString() => 'TaggerSkip: $reason';
}

class MediaTagger {
  MediaTagger._();

  /// Container of an audio buffer from magic bytes: `webm` (EBML),
  /// `mp4` (`ftyp`), `flac`, `mp3` (ID3 or frame sync), else `unknown`.
  /// Tagging must route on this — never on MIME strings or file
  /// extensions, which can disagree with the actual bytes.
  static String detectContainer(Uint8List bytes) {
    if (bytes.length >= 4 &&
        bytes[0] == 0x1A &&
        bytes[1] == 0x45 &&
        bytes[2] == 0xDF &&
        bytes[3] == 0xA3) {
      return 'webm';
    }
    if (bytes.length >= 8 &&
        bytes[4] == 0x66 &&
        bytes[5] == 0x74 &&
        bytes[6] == 0x79 &&
        bytes[7] == 0x70) {
      return 'mp4';
    }
    if (bytes.length >= 4 &&
        bytes[0] == 0x66 &&
        bytes[1] == 0x4C &&
        bytes[2] == 0x61 &&
        bytes[3] == 0x43) {
      return 'flac';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0x49 &&
        bytes[1] == 0x44 &&
        bytes[2] == 0x33) {
      return 'mp3';
    }
    if (bytes.length >= 2 &&
        bytes[0] == 0xFF &&
        (bytes[1] & 0xE0) == 0xE0) {
      return 'mp3';
    }
    return 'unknown';
  }

  /// Image MIME from magic bytes. Null when unrecognized.
  static String? sniffImageMime(Uint8List bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'image/jpeg';
    }
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'image/webp';
    }
    if (bytes.length >= 6 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46) {
      return 'image/gif';
    }
    return null;
  }

  // -- WebM Opus -> Ogg Opus ------------------------------------------------

  /// Remuxes a YouTube Opus-in-WebM buffer into a tagged Ogg Opus file.
  ///
  /// Throws [TaggerSkip] when the buffer is not Opus-in-WebM or carries
  /// no audio packets.
  static Uint8List remuxWebmOpusToOgg(
      Uint8List webm, DownloadTags tags) {
    final parsed = _parseWebmAudio(webm);
    if (parsed.packets.isEmpty) {
      throw const TaggerSkip('no audio packets');
    }
    final serial = Random().nextInt(0x7fffffff);
    final out = <Uint8List>[];
    var seq = 0;
    // OpusHead (identification header, BOS).
    out.add(_oggPage(
      serial: serial,
      seq: seq++,
      flags: 0x02,
      granule: 0,
      packets: [parsed.opusHead],
    ));
    // OpusTags (comment header).
    out.add(_oggPage(
      serial: serial,
      seq: seq++,
      flags: 0x00,
      granule: 0,
      packets: [_opusTagsPacket(tags)],
    ));
    // Audio packets, packed greedily (<= 255 segments per page).
    var granule = parsed.preskip;
    final granules = <int>[];
    for (final p in parsed.packets) {
      granule += _opusPacketSamples(p.data);
      granules.add(granule);
    }
    var idx = 0;
    while (idx < parsed.packets.length) {
      final pagePackets = <Uint8List>[];
      final pageGranules = <int>[];
      var segCount = 0;
      while (idx < parsed.packets.length) {
        final need = _oggSegCount(parsed.packets[idx].data.length);
        if (pagePackets.isNotEmpty && segCount + need > 255) break;
        pagePackets.add(parsed.packets[idx].data);
        pageGranules.add(granules[idx]);
        segCount += need;
        idx++;
      }
      final last = idx >= parsed.packets.length;
      out.add(_oggPage(
        serial: serial,
        seq: seq++,
        flags: last ? 0x04 : 0x00,
        granule: pageGranules.last,
        packets: pagePackets,
      ));
    }
    final total = out.fold<int>(0, (a, p) => a + p.length);
    final merged = Uint8List(total);
    var w = 0;
    for (final p in out) {
      merged.setRange(w, w + p.length, p);
      w += p.length;
    }
    return merged;
  }

  // -- FLAC -----------------------------------------------------------------

  /// Rebuilds FLAC metadata with Vorbis comments + front-cover picture.
  ///
  /// Throws [TaggerSkip] on non-FLAC or truncated input.
  static Uint8List tagFlac(Uint8List flac, DownloadTags tags) {
    if (flac.length < 42 || !_isAscii(flac, 0, 'fLaC')) {
      throw const TaggerSkip('not flac');
    }
    var pos = 4;
    Uint8List? streaminfo;
    final others = <Uint8List>[];
    var ended = false;
    while (!ended) {
      if (pos + 4 > flac.length) throw const TaggerSkip('flac truncated');
      final hb = flac[pos];
      final type = hb & 0x7F;
      final last = (hb & 0x80) != 0;
      final len =
          (flac[pos + 1] << 16) | (flac[pos + 2] << 8) | flac[pos + 3];
      if (pos + 4 + len > flac.length) {
        throw const TaggerSkip('flac block overrun');
      }
      final body = flac.sublist(pos + 4, pos + 4 + len);
      if (type == 0) {
        if (streaminfo != null || body.length != 34) {
          throw const TaggerSkip('bad streaminfo');
        }
        streaminfo = body;
      } else if (type == 3 || type == 4 || type == 6) {
        // Drop seektable (absolute offsets), old comments, old pictures.
      } else {
        others.add(flac.sublist(pos, pos + 4 + len));
      }
      pos += 4 + len;
      if (last) ended = true;
    }
    if (streaminfo == null) throw const TaggerSkip('no streaminfo');
    final audio = Uint8List.fromList(flac.sublist(pos));
    final blocks = <Uint8List>[];
    blocks.add(_flacBlock(0, Uint8List.fromList(streaminfo), false));
    blocks.add(_flacBlock(4, _vorbisCommentBlock(tags), false));
    if (tags.hasCover) {
      blocks.add(_flacBlock(
          6,
          _flacPictureBlock(
              tags.coverMime, tags.coverBytes!, type: 3),
          false));
    }
    for (final raw in others) {
      blocks.add(Uint8List.fromList(raw));
    }
    // Only the true final metadata block carries the last-flag.
    for (var i = 0; i < blocks.length; i++) {
      blocks[i][0] = i == blocks.length - 1
          ? (blocks[i][0] | 0x80)
          : (blocks[i][0] & 0x7F);
    }
    final total = 4 +
        blocks.fold<int>(0, (a, b) => a + b.length) +
        audio.length;
    final out = Uint8List(total);
    out.setRange(0, 4, utf8.encode('fLaC'));
    var w = 4;
    for (final b in blocks) {
      out.setRange(w, w + b.length, b);
      w += b.length;
    }
    out.setRange(w, w + audio.length, audio);
    return out;
  }

  // -- MP3 (ID3v2.3) ----------------------------------------------------------

  /// Prepends a fresh ID3v2.3 tag (old v2 tag + v1 trailer are dropped).
  ///
  /// Throws [TaggerSkip] on empty input.
  static Uint8List tagMp3(Uint8List mp3, DownloadTags tags) {
    var start = 0;
    var end = mp3.length;
    if (end >= 10 &&
        mp3[0] == 0x49 &&
        mp3[1] == 0x44 &&
        mp3[2] == 0x33) {
      final size = _syncsafe(mp3, 6);
      start = 10 + size;
      if (start > end) throw const TaggerSkip('bad id3');
    }
    if (end - start >= 128 &&
        mp3[end - 128] == 0x54 &&
        mp3[end - 127] == 0x41 &&
        mp3[end - 126] == 0x47) {
      end -= 128;
    }
    if (end <= start) throw const TaggerSkip('empty mp3');
    final audio = mp3.sublist(start, end);
    final tag = _id3v23Tag(tags);
    final out = Uint8List(tag.length + audio.length);
    out.setRange(0, tag.length, tag);
    out.setRange(tag.length, tag.length + audio.length, audio);
    return out;
  }

  // -- M4A (moov/udta/meta/ilst) ----------------------------------------------

  /// Inserts an iTunes-style `ilst` tag into `moov/udta/meta`.
  ///
  /// Only works when a `moov` box exists (progressive files and DASH
  /// init segments qualify); fragmented files without `moov`, or any
  /// structural surprise, throw [TaggerSkip].
  static Uint8List tagM4a(Uint8List m4a, DownloadTags tags) {
    final top = _mp4ReadBoxes(m4a, 0, m4a.length);
    var moovIndex = -1;
    for (var i = 0; i < top.length; i++) {
      if (top[i].type == 'moov') {
        moovIndex = i;
        break;
      }
    }
    if (moovIndex < 0) throw const TaggerSkip('no moov');
    final moov = top[moovIndex];
    final kids = _mp4ReadBoxes(
        m4a, moov.contentStart, moov.contentEnd);
    _Mp4Box? udta;
    for (final k in kids) {
      if (k.type == 'udta') udta = k;
    }
    final ilstPayload =
        _mp4BoxRaw('ilst', _concat(_mp4IlstItems(tags)));
    Uint8List newUdtaPayload;
    if (udta == null) {
      final hdlr = _mp4MetaHdlr();
      final meta = _mp4BoxRaw(
          'meta', _concat([Uint8List(4), hdlr, ilstPayload]));
      newUdtaPayload = meta;
      kids.add(_Mp4Box(
          type: 'udta',
          headerLen: 8,
          boxStart: -1,
          contentStart: -1,
          contentEnd: -1,
          freshPayload: newUdtaPayload));
    } else {
      final ukids = _mp4ReadBoxes(
          m4a, udta.contentStart, udta.contentEnd);
      var metaIndex = -1;
      for (var i = 0; i < ukids.length; i++) {
        if (ukids[i].type == 'meta') metaIndex = i;
      }
      if (metaIndex < 0) {
        final hdlr = _mp4MetaHdlr();
        final meta = _mp4BoxRaw(
            'meta', _concat([Uint8List(4), hdlr, ilstPayload]));
        final rebuilt = <int>[];
        for (final k in ukids) {
          rebuilt.addAll(_mp4CopyBox(m4a, k));
        }
        rebuilt.addAll(meta);
        newUdtaPayload = Uint8List.fromList(rebuilt);
      } else {
        final meta = ukids[metaIndex];
        // meta content = 4 fullbox bytes + children.
        final mkids = _mp4ReadBoxes(
            m4a, meta.contentStart + 4, meta.contentEnd);
        final rebuilt = <int>[0, 0, 0, 0];
        var ilstReplaced = false;
        for (final k in mkids) {
          if (k.type == 'ilst' && !ilstReplaced) {
            rebuilt.addAll(ilstPayload);
            ilstReplaced = true;
          } else if (k.type == 'ilst') {
            // Drop duplicate ilst boxes.
          } else {
            rebuilt.addAll(_mp4CopyBox(m4a, k));
          }
        }
        if (!ilstReplaced) rebuilt.addAll(ilstPayload);
        final newMetaPayload = Uint8List.fromList(rebuilt);
        final urebuilt = <int>[];
        for (var i = 0; i < ukids.length; i++) {
          if (i == metaIndex) {
            urebuilt.addAll(
                _mp4BoxRaw('meta', newMetaPayload));
          } else {
            urebuilt.addAll(_mp4CopyBox(m4a, ukids[i]));
          }
        }
        newUdtaPayload = Uint8List.fromList(urebuilt);
      }
      udta.freshPayload = newUdtaPayload;
    }
    // Serialize new moov children; delta shifts stco/co64 entries.
    final oldMoovContentLen = moov.contentEnd - moov.contentStart;
    // First pass: serialize with unpatched stco to measure delta.
    var newChildren = _mp4SerializeKids(m4a, kids);
    final delta = newChildren.length - oldMoovContentLen;
    if (delta != 0) {
      _mp4ShiftChunkOffsets(kids, m4a, delta);
      newChildren = _mp4SerializeKids(m4a, kids);
    }
    final newMoov = _mp4BoxRaw(moov.type, newChildren,
        headerLen: moov.headerLen);
    final oldTotal = moov.contentEnd - moov.boxStart;
    final out = Uint8List(m4a.length + newMoov.length - oldTotal);
    out.setRange(0, moov.boxStart, m4a);
    out.setRange(moov.boxStart, moov.boxStart + newMoov.length,
        newMoov);
    out.setRange(moov.boxStart + newMoov.length, out.length,
        m4a.sublist(moov.boxStart + oldTotal));
    return out;
  }

  // -- FLAC-in-MP4 (fLaC sample entry -> native FLAC) --------------------------

  /// Audio sample-entry fourcc of the first audio track (`fLaC`, `alac`,
  /// `mp4a`, ...). Throws [TaggerSkip] when there is no `moov/stsd`.
  static String mp4AudioSampleEntry(Uint8List mp4) {
    final entry = _mp4FirstAudioSampleEntry(mp4);
    return entry.$1;
  }

  /// True when [mp4] is FLAC-in-MP4 (sample entry `fLaC`/`flac` with a
  /// `dfLa` box). Never throws — returns false on any unparseable input.
  static bool isFlacInMp4(Uint8List mp4) {
    try {
      final entry = _mp4FirstAudioSampleEntry(mp4);
      return entry.$1 == 'fLaC' || entry.$1 == 'flac';
    } catch (_) {
      return false;
    }
  }

  /// Transmuxes FLAC-in-MP4 into a tagged native FLAC file.
  ///
  /// `STREAMINFO` comes from the `dfLa` box, audio frames from the
  /// `mdat` boxes (sized by the `moof/traf/trun` sample-size entries
  /// for fragmented DASH assemblies). The result is passed through
  /// [tagFlac] so title/artist/album/lyrics/cover are embedded.
  ///
  /// Throws [TaggerSkip] on any structural surprise (non-FLAC entry,
  /// progressive layout without `moof`, size mismatch, bad frame sync)
  /// — callers must keep the `.m4a` bytes in that case.
  static Uint8List remuxFlacInMp4ToFlac(Uint8List mp4, DownloadTags tags) {
    final entry = _mp4FirstAudioSampleEntry(mp4);
    final fourcc = entry.$1;
    if (fourcc != 'fLaC' && fourcc != 'flac') {
      throw TaggerSkip('mp4 entry $fourcc');
    }
    final streaminfo = _mp4FlacStreaminfo(entry.$2);
    final frames = _mp4CollectFlacFrames(mp4);
    if (frames.isEmpty) throw const TaggerSkip('no flac frames');
    // Minimal native FLAC: header + single STREAMINFO block, then the
    // raw frames. tagFlac rebuilds the metadata (comments + picture).
    final head = Uint8List(4 + 4 + streaminfo.length);
    head.setRange(0, 4, utf8.encode('fLaC'));
    head[4] = 0x80; // last-block + type 0 (STREAMINFO)
    head[5] = 0;
    head[6] = 0;
    head[7] = 34;
    head.setRange(8, 8 + streaminfo.length, streaminfo);
    final total = head.length + frames.length;
    if (total > 512 * 1024 * 1024) {
      throw const TaggerSkip('flac too large');
    }
    final minimal = Uint8List(total);
    minimal.setRange(0, head.length, head);
    minimal.setRange(head.length, total, frames);
    return tagFlac(minimal, tags);
  }

  /// (fourcc, full sample-entry bytes incl. size+type header) of the
  /// first audio track's sample entry.
  static (String, Uint8List) _mp4FirstAudioSampleEntry(Uint8List d) {
    final top = _mp4ReadBoxes(d, 0, d.length);
    _Mp4Box? moov;
    for (final b in top) {
      if (b.type == 'moov') moov = b;
    }
    if (moov == null) throw const TaggerSkip('no moov');
    final traks = _mp4FindChildren(d, moov, 'trak');
    for (final trak in traks) {
      final mdias = _mp4FindChildren(d, trak, 'mdia');
      for (final mdia in mdias) {
        final minf = _mp4FindChild(d, mdia, 'minf');
        if (minf == null) continue;
        final stbl = _mp4FindChild(d, minf, 'stbl');
        if (stbl == null) continue;
        final stsd = _mp4FindChild(d, stbl, 'stsd');
        if (stsd == null) continue;
        final payload = d.sublist(stsd.contentStart, stsd.contentEnd);
        if (payload.length < 8) throw const TaggerSkip('bad stsd');
        final entryCount = _readU32be(payload, 4);
        var pos = 8;
        for (var i = 0; i < entryCount; i++) {
          if (pos + 8 > payload.length) {
            throw const TaggerSkip('stsd overrun');
          }
          final size = _readU32be(payload, pos);
          final fourcc = String.fromCharCodes(payload.sublist(pos + 4, pos + 8));
          if (size < 8 || pos + size > payload.length) {
            throw const TaggerSkip('stsd entry overrun');
          }
          // First entry of the first audio track wins. Non-audio tracks
          // (e.g. cover-art video track) are skipped by checking the
          // handler: only `soun` tracks are considered.
          if (_mp4TrackIsAudio(d, trak)) {
            return (fourcc,
                Uint8List.fromList(payload.sublist(pos, pos + size)));
          }
          pos += size;
        }
      }
    }
    throw const TaggerSkip('no audio stsd');
  }

  static bool _mp4TrackIsAudio(Uint8List d, _Mp4Box trak) {
    try {
      final mdias = _mp4FindChildren(d, trak, 'mdia');
      for (final mdia in mdias) {
        final hdlr = _mp4FindChild(d, mdia, 'hdlr');
        if (hdlr == null) continue;
        final payload = d.sublist(hdlr.contentStart, hdlr.contentEnd);
        // hdlr content: version/flags(4) + pre_defined(4) + handler(4).
        if (payload.length >= 12) {
          final handler =
              String.fromCharCodes(payload.sublist(8, 12));
          if (handler == 'soun') return true;
        }
      }
    } catch (_) {}
    return false;
  }

  /// 34-byte STREAMINFO body from an `fLaC` sample entry.
  static Uint8List _mp4FlacStreaminfo(Uint8List entry) {
    // Entry: size(4) + type(4) + fixed sample-entry fields(28) +
    // sub-boxes. dfLa is a FullBox: size + type + version/flags(4) +
    // FLAC block header(4: 0x80/0x00 + type 0 + len 34) + STREAMINFO(34).
    if (entry.length < 8 + 28 + 8) {
      throw const TaggerSkip('short flac entry');
    }
    final payload = entry.sublist(8);
    var pos = 28;
    while (pos + 8 <= payload.length) {
      final size = _readU32be(payload, pos);
      if (size < 8 || pos + size > payload.length) {
        throw const TaggerSkip('flac box overrun');
      }
      final type = String.fromCharCodes(payload.sublist(pos + 4, pos + 8));
      if (type == 'dfLa') {
        final body = payload.sublist(pos + 8, pos + size);
        if (body.length < 4 + 4 + 34) {
          throw const TaggerSkip('short dfLa');
        }
        final blockHeader = body.sublist(4, 8);
        final streaminfo = body.sublist(8, 8 + 34);
        // Tolerate both last-flag states; type must be 0 (STREAMINFO)
        // with length 34.
        if ((blockHeader[0] & 0x7F) != 0 ||
            blockHeader[1] != 0 ||
            blockHeader[2] != 0 ||
            blockHeader[3] != 34) {
          throw const TaggerSkip('bad dfLa header');
        }
        return Uint8List.fromList(streaminfo);
      }
      pos += size;
    }
    throw const TaggerSkip('no dfLa');
  }

  /// Concatenated raw FLAC frames from a fragmented MP4 (moof/mdat).
  /// Sizes come from every `trun` sample-size entry in file order and
  /// must exactly cover the concatenated `mdat` payloads.
  static Uint8List _mp4CollectFlacFrames(Uint8List d) {
    final top = _mp4ReadBoxes(d, 0, d.length);
    final hasMoof = top.any((b) => b.type == 'moof');
    if (!hasMoof) {
      throw const TaggerSkip('progressive flac-in-mp4 unsupported');
    }
    final sizes = <int>[];
    final mdatPayloads = <Uint8List>[];
    var totalMdat = 0;
    for (final b in top) {
      if (b.type == 'moof') {
        sizes.addAll(_mp4TrunSampleSizes(d, b));
      } else if (b.type == 'mdat') {
        final payload =
            d.sublist(b.contentStart, b.contentEnd);
        mdatPayloads.add(payload);
        totalMdat += payload.length;
        if (totalMdat > 512 * 1024 * 1024) {
          throw const TaggerSkip('mdat too large');
        }
      }
    }
    if (sizes.isEmpty) throw const TaggerSkip('no trun sizes');
    var totalSizes = 0;
    for (final s in sizes) {
      if (s <= 0 || s > 16 * 1024 * 1024) {
        throw const TaggerSkip('bad sample size');
      }
      totalSizes += s;
    }
    if (totalSizes != totalMdat) {
      throw const TaggerSkip('size mismatch');
    }
    final out = Uint8List(totalMdat);
    var w = 0;
    for (final p in mdatPayloads) {
      out.setRange(w, w + p.length, p);
      w += p.length;
    }
    // Validate FLAC frame sync on every sample boundary: 0xFF + top 3
    // bits set (0xF8..0xFF). Catches mis-slicing before writing.
    var pos = 0;
    for (final s in sizes) {
      if (pos + 2 > out.length || pos + s > out.length) {
        throw const TaggerSkip('frame overrun');
      }
      if (out[pos] != 0xFF || (out[pos + 1] & 0xF8) != 0xF8) {
        throw const TaggerSkip('bad flac sync');
      }
      pos += s;
    }
    return out;
  }

  /// All `trun` sample sizes under a `moof`, in box order.
  static List<int> _mp4TrunSampleSizes(Uint8List d, _Mp4Box moof) {
    final sizes = <int>[];
    final trafs = _mp4FindChildren(d, moof, 'traf');
    for (final traf in trafs) {
      final truns = _mp4FindChildren(d, traf, 'trun');
      for (final trun in truns) {
        final raw = d.sublist(trun.contentStart, trun.contentEnd);
        if (raw.length < 8) throw const TaggerSkip('short trun');
        final flags =
            (raw[1] << 16) | (raw[2] << 8) | raw[3];
        final sampleCount = _readU32be(raw, 4);
        if (sampleCount <= 0 || sampleCount > 100000) {
          throw const TaggerSkip('bad sample count');
        }
        var pos = 8;
        if ((flags & 0x1) != 0) pos += 4; // data_offset
        if ((flags & 0x4) != 0) pos += 4; // first_sample_flags
        var perSample = 0;
        var sizeOffset = 0;
        if ((flags & 0x100) != 0) {
          sizeOffset = perSample;
          perSample += 4; // duration
        }
        var hasSize = false;
        if ((flags & 0x200) != 0) {
          sizeOffset = perSample;
          perSample += 4; // size
          hasSize = true;
        }
        if ((flags & 0x400) != 0) perSample += 4; // flags
        if ((flags & 0x800) != 0) perSample += 4; // cts
        if (!hasSize) throw const TaggerSkip('trun without sizes');
        if (raw.length < pos + perSample * sampleCount) {
          throw const TaggerSkip('trun overrun');
        }
        for (var i = 0; i < sampleCount; i++) {
          sizes.add(_readU32be(raw, pos + i * perSample + sizeOffset));
        }
      }
    }
    return sizes;
  }

  static _Mp4Box? _mp4FindChild(Uint8List d, _Mp4Box parent, String type) {
    final kids =
        _mp4ReadBoxes(d, parent.contentStart, parent.contentEnd);
    for (final k in kids) {
      if (k.type == type) return k;
    }
    return null;
  }

  static List<_Mp4Box> _mp4FindChildren(
      Uint8List d, _Mp4Box parent, String type) {
    final kids =
        _mp4ReadBoxes(d, parent.contentStart, parent.contentEnd);
    return kids.where((k) => k.type == type).toList();
  }

  static int _readU32be(List<int> d, int off) {
    return ((d[off] & 0xFF) << 24) |
        ((d[off + 1] & 0xFF) << 16) |
        ((d[off + 2] & 0xFF) << 8) |
        (d[off + 3] & 0xFF);
  }

  // == internals: bytes ======================================================

  static bool _isAscii(Uint8List d, int off, String s) {
    if (off + s.length > d.length) return false;
    for (var i = 0; i < s.length; i++) {
      if (d[off + i] != s.codeUnitAt(i)) return false;
    }
    return true;
  }

  static Uint8List _concat(List<Uint8List> parts) {
    final total = parts.fold<int>(0, (a, p) => a + p.length);
    final out = Uint8List(total);
    var w = 0;
    for (final p in parts) {
      out.setRange(w, w + p.length, p);
      w += p.length;
    }
    return out;
  }

  static Uint8List _u32le(int v) {
    final d = ByteData(4)..setUint32(0, v, Endian.little);
    return d.buffer.asUint8List();
  }

  static Uint8List _u32be(int v) {
    final d = ByteData(4)..setUint32(0, v, Endian.big);
    return d.buffer.asUint8List();
  }

  /// UTF-16LE with BOM (ID3v2.3-safe Unicode text).
  static Uint8List _utf16leBom(String s) {
    final units = <int>[0xFF, 0xFE];
    for (final r in s.runes) {
      if (r < 0x10000) {
        units.add(r & 0xFF);
        units.add((r >> 8) & 0xFF);
      } else {
        final v = r - 0x10000;
        final hi = 0xD800 + (v >> 10);
        final lo = 0xDC00 + (v & 0x3FF);
        units.add(hi & 0xFF);
        units.add((hi >> 8) & 0xFF);
        units.add(lo & 0xFF);
        units.add((lo >> 8) & 0xFF);
      }
    }
    return Uint8List.fromList(units);
  }

  // == internals: Ogg ==========================================================

  static final List<int> _oggCrcTable = _makeOggCrcTable();

  static List<int> _makeOggCrcTable() {
    final table = List<int>.filled(256, 0);
    for (var i = 0; i < 256; i++) {
      var r = i << 24;
      for (var j = 0; j < 8; j++) {
        r = ((r & 0x80000000) != 0)
            ? ((r << 1) ^ 0x04C11DB7) & 0xFFFFFFFF
            : (r << 1) & 0xFFFFFFFF;
      }
      table[i] = r;
    }
    return table;
  }

  static int _oggCrc(Uint8List page) {
    var crc = 0;
    for (var i = 0; i < page.length; i++) {
      crc = ((_oggCrcTable[((crc >> 24) ^ page[i]) & 0xFF] ^
              ((crc << 8) & 0xFFFFFFFF))) &
          0xFFFFFFFF;
    }
    return crc;
  }

  static int _oggSegCount(int packetLen) => packetLen ~/ 255 + 1;

  static Uint8List _oggPage({
    required int serial,
    required int seq,
    required int flags,
    required int granule,
    required List<Uint8List> packets,
  }) {
    final segs = <int>[];
    var bodyLen = 0;
    for (final p in packets) {
      var rem = p.length;
      while (rem >= 255) {
        segs.add(255);
        rem -= 255;
      }
      segs.add(rem);
      bodyLen += p.length;
    }
    if (segs.length > 255) throw const TaggerSkip('ogg page overflow');
    final out = Uint8List(27 + segs.length + bodyLen);
    final d = ByteData.sublistView(out);
    out[0] = 0x4F; // OggS
    out[1] = 0x67;
    out[2] = 0x67;
    out[3] = 0x53;
    out[4] = 0;
    out[5] = flags;
    d.setUint64(6, granule, Endian.little);
    d.setUint32(14, serial, Endian.little);
    d.setUint32(18, seq, Endian.little);
    out[26] = segs.length;
    for (var i = 0; i < segs.length; i++) {
      out[27 + i] = segs[i];
    }
    var w = 27 + segs.length;
    for (final p in packets) {
      out.setRange(w, w + p.length, p);
      w += p.length;
    }
    d.setUint32(22, _oggCrc(out), Endian.little);
    return out;
  }

  /// Opus frame size in samples @48kHz per TOC config byte high bits.
  static const List<int> _opusFrameSamples = [
    480, 960, 1920, 2880, // 0-3 Silk NB
    480, 960, 1920, 2880, // 4-7 Silk MB
    480, 960, 1920, 2880, // 8-11 Silk WB
    480, 960, // 12-13 Hybrid SWB
    480, 960, // 14-15 Hybrid FB
    120, 240, 480, 960, // 16-19 CELT NB
    120, 240, 480, 960, // 20-23 CELT WB
    120, 240, 480, 960, // 24-27 CELT SWB
    120, 240, 480, 960, // 28-31 CELT FB
  ];

  static int _opusPacketSamples(Uint8List p) {
    if (p.isEmpty) throw const TaggerSkip('empty opus packet');
    final toc = p[0];
    final frame = _opusFrameSamples[(toc >> 3) & 31];
    final code = toc & 3;
    if (code == 0) return frame;
    if (code == 3) {
      if (p.length < 2) throw const TaggerSkip('bad opus toc');
      final count = p[1] & 63;
      if (count == 0) throw const TaggerSkip('bad opus count');
      return frame * count;
    }
    return frame * 2;
  }

  static Uint8List _opusTagsPacket(DownloadTags tags) {
    final comments = <String>[];
    if (tags.title.trim().isNotEmpty) {
      comments.add('TITLE=${tags.title.trim()}');
    }
    if (tags.artist.trim().isNotEmpty) {
      comments.add('ARTIST=${tags.artist.trim()}');
    }
    if (tags.album.trim().isNotEmpty) {
      comments.add('ALBUM=${tags.album.trim()}');
    }
    final lyrics = tags.lyrics.replaceAll('\r\n', '\n').trim();
    if (lyrics.isNotEmpty) {
      comments.add('LYRICS=$lyrics');
    }
    if (tags.hasCover) {
      final pic = base64Encode(_flacPictureBlock(
          tags.coverMime, tags.coverBytes!,
          type: 3));
      comments.add('METADATA_BLOCK_PICTURE=$pic');
    }
    final vendor = utf8.encode('LastWave Desktop');
    final parts = <Uint8List>[];
    parts.add(utf8.encode('OpusTags'));
    parts.add(_u32le(vendor.length));
    parts.add(Uint8List.fromList(vendor));
    parts.add(_u32le(comments.length));
    for (final c in comments) {
      final b = utf8.encode(c);
      parts.add(_u32le(b.length));
      parts.add(Uint8List.fromList(b));
    }
    return _concat(parts);
  }

  // == internals: shared picture ===============================================

  /// FLAC `METADATA_BLOCK_PICTURE` body (also the base64 payload for
  /// OpusTags). Type 3 = front cover.
  static Uint8List _flacPictureBlock(String mime, Uint8List data,
      {int type = 3}) {
    final mimeBytes = utf8.encode(mime);
    final dims = _imageDims(data);
    final parts = <Uint8List>[
      _u32be(type),
      _u32be(mimeBytes.length),
      Uint8List.fromList(mimeBytes),
      _u32be(0), // description length (empty)
      _u32be(dims.$1),
      _u32be(dims.$2),
      _u32be(0), // depth
      _u32be(0), // colors
      _u32be(data.length),
      data,
    ];
    return _concat(parts);
  }

  /// (width, height), zeros when undetectable (allowed by the spec).
  static (int, int) _imageDims(Uint8List d) {
    try {
      if (d.length >= 24 &&
          d[0] == 0x89 &&
          d[1] == 0x50 &&
          d[2] == 0x4E &&
          d[3] == 0x47) {
        final w = ByteData.sublistView(d, 16, 20)
            .getUint32(0, Endian.big);
        final h = ByteData.sublistView(d, 20, 24)
            .getUint32(0, Endian.big);
        if (w > 0 && h > 0 && w <= 16000 && h <= 16000) return (w, h);
        return (0, 0);
      }
      if (d.length >= 4 && d[0] == 0xFF && d[1] == 0xD8) {
        var pos = 2;
        while (pos + 9 < d.length) {
          if (d[pos] != 0xFF) break;
          final marker = d[pos + 1];
          if (marker == 0xD8 ||
              (marker >= 0xD0 && marker <= 0xD9) ||
              marker == 0x01) {
            pos += 2;
            continue;
          }
          if (pos + 4 > d.length) break;
          final segLen = (d[pos + 2] << 8) | d[pos + 3];
          if (segLen < 2) break;
          if (marker >= 0xC0 && marker <= 0xC3) {
            if (pos + 9 >= d.length) break;
            final h = (d[pos + 5] << 8) | d[pos + 6];
            final w = (d[pos + 7] << 8) | d[pos + 8];
            if (w > 0 && h > 0 && w <= 16000 && h <= 16000) {
              return (w, h);
            }
            return (0, 0);
          }
          pos += 2 + segLen;
        }
      }
    } catch (_) {}
    return (0, 0);
  }

  // == internals: FLAC comments ==================================================

  static Uint8List _vorbisCommentBlock(DownloadTags tags) {
    final comments = <String>[];
    if (tags.title.trim().isNotEmpty) {
      comments.add('TITLE=${tags.title.trim()}');
    }
    if (tags.artist.trim().isNotEmpty) {
      comments.add('ARTIST=${tags.artist.trim()}');
    }
    if (tags.album.trim().isNotEmpty) {
      comments.add('ALBUM=${tags.album.trim()}');
    }
    final lyrics = tags.lyrics.replaceAll('\r\n', '\n').trim();
    if (lyrics.isNotEmpty) comments.add('LYRICS=$lyrics');
    comments.add('ENCODER=LastWave Desktop');
    final vendor = utf8.encode('LastWave Desktop');
    final parts = <Uint8List>[
      _u32le(vendor.length),
      Uint8List.fromList(vendor),
      _u32le(comments.length),
    ];
    for (final c in comments) {
      final b = utf8.encode(c);
      parts.add(_u32le(b.length));
      parts.add(Uint8List.fromList(b));
    }
    return _concat(parts);
  }

  static Uint8List _flacBlock(int type, Uint8List body, bool last) {
    final out = Uint8List(4 + body.length);
    out[0] = (last ? 0x80 : 0) | (type & 0x7F);
    out[1] = (body.length >> 16) & 0xFF;
    out[2] = (body.length >> 8) & 0xFF;
    out[3] = body.length & 0xFF;
    out.setRange(4, 4 + body.length, body);
    return out;
  }

  // == internals: ID3v2.3 ==========================================================

  static int _syncsafe(Uint8List d, int off) {
    return ((d[off] & 0x7F) << 21) |
        ((d[off + 1] & 0x7F) << 14) |
        ((d[off + 2] & 0x7F) << 7) |
        (d[off + 3] & 0x7F);
  }

  static Uint8List _id3Frame(String id, Uint8List payload) {
    final head = Uint8List(10);
    final idBytes = utf8.encode(id);
    for (var i = 0; i < 4 && i < idBytes.length; i++) {
      head[i] = idBytes[i];
    }
    final d = ByteData.sublistView(head);
    d.setUint32(4, payload.length, Endian.big);
    // flags stay zero.
    return _concat([head, payload]);
  }

  static Uint8List _id3Text(String id, String text) {
    if (text.trim().isEmpty) return Uint8List(0);
    return _id3Frame(
        id, _concat([Uint8List.fromList([0x01]), _utf16leBom(text)]));
  }

  static Uint8List _id3v23Tag(DownloadTags tags) {
    final frames = <Uint8List>[
      _id3Text('TIT2', tags.title),
      _id3Text('TPE1', tags.artist),
      _id3Text('TALB', tags.album),
    ];
    final lyrics = tags.lyrics.replaceAll('\r\n', '\n').trim();
    if (lyrics.isNotEmpty) {
      frames.add(_id3Frame(
          'USLT',
          _concat([
            Uint8List.fromList([0x01]),
            utf8.encode('eng'),
            Uint8List.fromList([0x00]),
            _utf16leBom(lyrics),
          ])));
    }
    if (tags.hasCover) {
      frames.add(_id3Frame(
          'APIC',
          _concat([
            Uint8List.fromList([0x00]),
            Uint8List.fromList(utf8.encode(tags.coverMime)),
            Uint8List.fromList([0x00, 0x03, 0x00]),
            tags.coverBytes!,
          ])));
    }
    final body = _concat(frames.where((f) => f.isNotEmpty).toList());
    final head = Uint8List(10);
    head[0] = 0x49; // ID3
    head[1] = 0x44;
    head[2] = 0x33;
    head[3] = 0x03; // v2.3
    final size = body.length;
    head[6] = (size >> 21) & 0x7F;
    head[7] = (size >> 14) & 0x7F;
    head[8] = (size >> 7) & 0x7F;
    head[9] = size & 0x7F;
    return _concat([head, body]);
  }

  // == internals: MP4 ==============================================================

  static Uint8List _mp4BoxRaw(String type, Uint8List payload,
      {int headerLen = 8}) {
    final out = Uint8List(headerLen + payload.length);
    final d = ByteData.sublistView(out);
    if (headerLen == 8) {
      d.setUint32(0, out.length, Endian.big);
      _writeAscii(out, 4, type);
    } else {
      d.setUint32(0, 1, Endian.big);
      _writeAscii(out, 4, type);
      d.setUint64(8, out.length, Endian.big);
    }
    out.setRange(headerLen, headerLen + payload.length, payload);
    return out;
  }

  static void _writeAscii(Uint8List d, int off, String s) {
    for (var i = 0; i < s.length; i++) {
      d[off + i] = s.codeUnitAt(i) & 0xFF;
    }
  }

  static Uint8List _mp4MetaHdlr() {
    final name = Uint8List.fromList([0x00]);
    final parts = <Uint8List>[
      Uint8List(4), // version/flags
      Uint8List(4), // pre_defined
      Uint8List.fromList(utf8.encode('mdirappl')),
      Uint8List(12), // reserved
      name,
    ];
    return _mp4BoxRaw('hdlr', _concat(parts));
  }

  static Uint8List _mp4DataBox(int type, Uint8List payload) {
    final head = Uint8List(8);
    final d = ByteData.sublistView(head);
    d.setUint32(0, type, Endian.big);
    d.setUint32(4, 0, Endian.big); // locale
    return _mp4BoxRaw('data', _concat([head, payload]));
  }

  static Uint8List _mp4TextItem(String fourcc, String text) {
    if (text.trim().isEmpty) return Uint8List(0);
    return _mp4BoxRaw(fourcc,
        _mp4DataBox(1, Uint8List.fromList(utf8.encode(text.trim()))));
  }

  static List<Uint8List> _mp4IlstItems(DownloadTags tags) {
    final items = <Uint8List>[
      _mp4TextItem('©nam', tags.title),
      _mp4TextItem('©ART', tags.artist),
      _mp4TextItem('©alb', tags.album),
    ];
    final lyrics = tags.lyrics.replaceAll('\r\n', '\n').trim();
    if (lyrics.isNotEmpty) {
      items.add(_mp4TextItem('©lyr', lyrics));
    }
    if (tags.hasCover) {
      final mime = tags.coverMime.toLowerCase();
      final kind = mime.contains('png') ? 14 : 13;
      items.add(_mp4BoxRaw(
          'covr', _mp4DataBox(kind, tags.coverBytes!)));
    }
    return items.where((b) => b.isNotEmpty).toList();
  }

  static List<_Mp4Box> _mp4ReadBoxes(
      Uint8List d, int start, int end) {
    final boxes = <_Mp4Box>[];
    var pos = start;
    while (pos + 8 <= end) {
      final size32 = ByteData.sublistView(d, pos, pos + 4)
          .getUint32(0, Endian.big);
      final type = String.fromCharCodes(d.sublist(pos + 4, pos + 8));
      var headerLen = 8;
      var size = size32;
      if (size32 == 1) {
        if (pos + 16 > end) throw const TaggerSkip('mp4 largesize');
        size = ByteData.sublistView(d, pos + 8, pos + 16)
            .getUint64(0, Endian.big);
        headerLen = 16;
      } else if (size32 == 0) {
        size = end - pos;
      }
      if (size < headerLen || pos + size > end) {
        throw const TaggerSkip('mp4 box overrun');
      }
      boxes.add(_Mp4Box(
        type: type,
        headerLen: headerLen,
        boxStart: pos,
        contentStart: pos + headerLen,
        contentEnd: pos + size,
      ));
      pos += size;
    }
    if (pos != end) throw const TaggerSkip('mp4 trailing bytes');
    return boxes;
  }

  static Uint8List _mp4CopyBox(Uint8List d, _Mp4Box b) {
    if (b.freshPayload != null) {
      return _mp4BoxRaw(b.type, b.freshPayload!,
          headerLen: b.headerLen);
    }
    return Uint8List.fromList(
        d.sublist(b.boxStart, b.contentEnd));
  }

  static Uint8List _mp4SerializeKids(
      Uint8List d, List<_Mp4Box> kids) {
    final parts = <Uint8List>[];
    for (final k in kids) {
      parts.add(_mp4CopyBox(d, k));
    }
    return _concat(parts);
  }

  static const _mp4Containers = {
    'moov', 'trak', 'mdia', 'minf', 'stbl', 'edts', 'dinf', 'udta',
  };

  /// Adds [delta] to every stco/co64 entry under [kids] (in place on
  /// fresh payload copies; original bytes untouched until serialize).
  static void _mp4ShiftChunkOffsets(
      List<_Mp4Box> kids, Uint8List d, int delta) {
    for (final k in kids) {
      if (k.freshPayload != null) {
        // Already rebuilt (e.g. the new udta) — nothing inside to shift.
        continue;
      }
      if (k.type == 'stco' || k.type == 'co64') {
        final raw = Uint8List.fromList(
            d.sublist(k.contentStart, k.contentEnd));
        if (raw.length < 8) throw const TaggerSkip('bad stco');
        final dd = ByteData.sublistView(raw);
        final count = dd.getUint32(4, Endian.big);
        if (k.type == 'stco') {
          if (raw.length < 8 + count * 4) {
            throw const TaggerSkip('bad stco entries');
          }
          for (var i = 0; i < count; i++) {
            dd.setUint32(8 + i * 4,
                dd.getUint32(8 + i * 4, Endian.big) + delta,
                Endian.big);
          }
        } else {
          if (raw.length < 8 + count * 8) {
            throw const TaggerSkip('bad co64 entries');
          }
          for (var i = 0; i < count; i++) {
            dd.setUint64(8 + i * 8,
                dd.getUint64(8 + i * 8, Endian.big) + delta,
                Endian.big);
          }
        }
        k.freshPayload = raw;
      } else if (_mp4Containers.contains(k.type)) {
        final sub = _mp4ReadBoxes(d, k.contentStart, k.contentEnd);
        _mp4ShiftChunkOffsets(sub, d, delta);
        k.freshPayload = _mp4SerializeKids(d, sub);
      } else if (k.type == 'meta') {
        // meta children sit after 4 fullbox bytes.
        final sub = _mp4ReadBoxes(d, k.contentStart + 4, k.contentEnd);
        _mp4ShiftChunkOffsets(sub, d, delta);
        final head = Uint8List.fromList(
            d.sublist(k.contentStart, k.contentStart + 4));
        k.freshPayload =
            _concat([head, _mp4SerializeKids(d, sub)]);
      }
    }
  }

  // == internals: EBML / WebM ========================================================

  static _WebmAudio _parseWebmAudio(Uint8List webm) {
    final c = _EbmlCursor(webm);
    final (hid, _) = c.readId();
    if (hid != 0x1A45DFA3) throw const TaggerSkip('not ebml');
    final (hsize, _) = c.readSize();
    if (hsize < 0) throw const TaggerSkip('bad ebml header');
    c.skip(hsize);
    final (sid, _) = c.readId();
    if (sid != 0x18538067) throw const TaggerSkip('no segment');
    final (segSize, _) = c.readSize();
    final segEnd =
        segSize < 0 ? webm.length : (c.pos + segSize);
    if (segEnd > webm.length) throw const TaggerSkip('segment overrun');
    var timeScale = 1000000;
    var trackNo = -1;
    Uint8List? codecPrivate;
    final packets = <_WebmPacket>[];
    // Two passes: Tracks/Info first (Clusters may legally precede
    // Tracks, and block parsing needs the audio track number).
    final clusterRanges = <(int, int)>[];
    while (c.pos < segEnd) {
      final (eid, _) = c.readId();
      final (esize, _) = c.readSize();
      final eEnd = esize < 0 ? segEnd : (c.pos + esize);
      if (eEnd > segEnd) throw const TaggerSkip('element overrun');
      if (eid == 0x1654AE6B) {
        final t = _parseTracks(webm, c.pos, eEnd);
        trackNo = t.$1;
        codecPrivate = t.$2;
      } else if (eid == 0x1549A966) {
        timeScale = _parseInfoTimeScale(webm, c.pos, eEnd);
      } else if (eid == 0x1F43B675) {
        clusterRanges.add((c.pos, eEnd));
      }
      c.pos = eEnd;
    }
    for (final r in clusterRanges) {
      _parseCluster(webm, r.$1, r.$2, trackNo, packets);
    }
    if (trackNo < 0) throw const TaggerSkip('no audio track');
    if (codecPrivate == null ||
        codecPrivate.length < 19 ||
        !_isAscii(codecPrivate, 0, 'OpusHead')) {
      throw const TaggerSkip('not opus');
    }
    return _WebmAudio(
      opusHead: codecPrivate.sublist(0, 19),
      preskip: ByteData.sublistView(codecPrivate, 10, 12)
          .getUint16(0, Endian.little),
      timeScale: timeScale,
      packets: packets,
    );
  }

  /// (audioTrackNumber, codecPrivate). Throws when Tracks is malformed.
  static (int, Uint8List?) _parseTracks(
      Uint8List d, int start, int end) {
    final c = _EbmlCursor(d)..pos = start;
    var trackNo = -1;
    Uint8List? priv;
    String codec = '';
    while (c.pos < end) {
      final (eid, _) = c.readId();
      final (esize, _) = c.readSize();
      final eEnd = esize < 0 ? end : (c.pos + esize);
      if (eEnd > end) throw const TaggerSkip('tracks overrun');
      if (eid == 0xAE) {
        final cc = _EbmlCursor(d)..pos = c.pos;
        var no = -1;
        var type = -1;
        String cid = '';
        Uint8List? cp;
        while (cc.pos < eEnd) {
          final (fid, _) = cc.readId();
          final (fsize, _) = cc.readSize();
          final fEnd = fsize < 0 ? eEnd : (cc.pos + fsize);
          if (fEnd > eEnd) throw const TaggerSkip('track overrun');
          if (fid == 0xD7) {
            no = _ebmlUint(d, cc.pos, fEnd);
          } else if (fid == 0x83) {
            type = _ebmlUint(d, cc.pos, fEnd);
          } else if (fid == 0x86) {
            cid = utf8
                .decode(d.sublist(cc.pos, fEnd),
                    allowMalformed: true)
                .replaceAll('\x00', '')
                .trim();
          } else if (fid == 0x63A2) {
            cp = Uint8List.fromList(d.sublist(cc.pos, fEnd));
          }
          cc.pos = fEnd;
        }
        if (type == 2 && trackNo < 0) {
          trackNo = no;
          priv = cp;
          codec = cid;
        }
      }
      c.pos = eEnd;
    }
    if (codec.isNotEmpty && codec != 'A_OPUS') {
      throw TaggerSkip('codec $codec');
    }
    return (trackNo, priv);
  }

  static int _parseInfoTimeScale(Uint8List d, int start, int end) {
    final c = _EbmlCursor(d)..pos = start;
    while (c.pos < end) {
      final (eid, _) = c.readId();
      final (esize, _) = c.readSize();
      final eEnd = esize < 0 ? end : (c.pos + esize);
      if (eEnd > end) throw const TaggerSkip('info overrun');
      if (eid == 0x2AD7B1) {
        final v = _ebmlUint(d, c.pos, eEnd);
        if (v > 0) return v;
      }
      c.pos = eEnd;
    }
    return 1000000;
  }

  static void _parseCluster(Uint8List d, int start, int end,
      int wantTrack, List<_WebmPacket> out) {
    final c = _EbmlCursor(d)..pos = start;
    var clusterTime = 0;
    while (c.pos < end) {
      final (eid, _) = c.readId();
      final (esize, _) = c.readSize();
      final eEnd = esize < 0 ? end : (c.pos + esize);
      if (eEnd > end) throw const TaggerSkip('cluster overrun');
      if (eid == 0xE7) {
        clusterTime = _ebmlUint(d, c.pos, eEnd);
      } else if (eid == 0xA3) {
        // One corrupt block must never kill the whole file.
        try {
          _collectBlock(d, c.pos, eEnd, clusterTime, wantTrack, out);
        } catch (_) {}
      } else if (eid == 0xA0) {
        final cc = _EbmlCursor(d)..pos = c.pos;
        while (cc.pos < eEnd) {
          final (bid, _) = cc.readId();
          final (bsize, _) = cc.readSize();
          final bEnd = bsize < 0 ? eEnd : (cc.pos + bsize);
          if (bEnd > eEnd) throw const TaggerSkip('blockgroup overrun');
          if (bid == 0xA1) {
            try {
              _collectBlock(d, cc.pos, bEnd, clusterTime, wantTrack, out);
            } catch (_) {}
          }
          cc.pos = bEnd;
        }
      }
      c.pos = eEnd;
    }
  }

  static void _collectBlock(Uint8List d, int start, int end,
      int clusterTime, int wantTrack, List<_WebmPacket> out) {
    if (wantTrack < 0) return; // Tracks not seen yet; Clusters first.
    var pos = start;
    final (track, trackLen) = _readVint(d, pos, end);
    pos += trackLen;
    if (pos + 3 > end) return;
    var tc = (d[pos] << 8) | d[pos + 1];
    if (tc >= 0x8000) tc -= 0x10000;
    final flags = d[pos + 2];
    pos += 3;
    if (track != wantTrack) return;
    final lace = (flags >> 1) & 3;
    final frames = <Uint8List>[];
    if (lace == 0) {
      if (pos >= end) return;
      frames.add(Uint8List.fromList(d.sublist(pos, end)));
    } else {
      if (pos >= end) return;
      final count = d[pos++] + 1;
      final sizes = <int>[];
      if (lace == 1) {
        for (var i = 0; i < count - 1; i++) {
          var s = 0;
          while (true) {
            if (pos >= end) return;
            final b = d[pos++];
            s += b;
            if (b != 255) break;
          }
          sizes.add(s);
        }
      } else if (lace == 2) {
        final each = (end - pos) ~/ count;
        if (each * count != end - pos) return;
        for (var i = 0; i < count - 1; i++) {
          sizes.add(each);
        }
      } else {
        final (first, flen) = _readVint(d, pos, end);
        pos += flen;
        sizes.add(first);
        for (var i = 1; i < count - 1; i++) {
          final (v, vl) = _readVint(d, pos, end);
          pos += vl;
          final bias = (1 << (7 * vl - 1)) - 1;
          sizes.add(sizes[i - 1] + v - bias);
        }
      }
      for (final s in sizes) {
        if (pos + s > end) return;
        frames.add(Uint8List.fromList(d.sublist(pos, pos + s)));
        pos += s;
      }
      if (pos < end) {
        frames.add(Uint8List.fromList(d.sublist(pos, end)));
      } else if (frames.length < count - 1) {
        // Sizes consumed every byte: only valid when the (empty)
        // final frame is the sole one missing.
        return;
      }
    }
    var t = clusterTime + tc;
    if (t < 0) t = 0;
    for (final f in frames) {
      if (f.isEmpty) continue;
      out.add(_WebmPacket(timeMs: t, data: f));
    }
  }

  static int _ebmlUint(Uint8List d, int start, int end) {
    var v = 0;
    for (var i = start; i < end; i++) {
      v = (v << 8) | d[i];
    }
    return v;
  }

  /// Raw vint value (marker masked). Returns (value, length).
  static (int, int) _readVint(Uint8List d, int pos, int end) {
    if (pos >= end) throw const TaggerSkip('vint overrun');
    final b = d[pos];
    int len;
    int mask;
    if ((b & 0x80) != 0) {
      len = 1;
      mask = 0x7F;
    } else if ((b & 0x40) != 0) {
      len = 2;
      mask = 0x3F;
    } else if ((b & 0x20) != 0) {
      len = 3;
      mask = 0x1F;
    } else if ((b & 0x10) != 0) {
      len = 4;
      mask = 0x0F;
    } else if ((b & 0x08) != 0) {
      len = 5;
      mask = 0x07;
    } else if ((b & 0x04) != 0) {
      len = 6;
      mask = 0x03;
    } else if ((b & 0x02) != 0) {
      len = 7;
      mask = 0x01;
    } else if (b == 0x01) {
      len = 8;
      mask = 0x00;
    } else {
      throw const TaggerSkip('bad vint');
    }
    if (pos + len > end) throw const TaggerSkip('vint overrun');
    var v = b & mask;
    for (var i = 1; i < len; i++) {
      v = (v << 8) | d[pos + i];
    }
    return (v, len);
  }
}

class _EbmlCursor {
  final Uint8List data;
  int pos = 0;
  _EbmlCursor(this.data);

  int _readByte() {
    if (pos >= data.length) throw const TaggerSkip('truncated');
    return data[pos++];
  }

  void skip(int n) {
    if (n < 0 || pos + n > data.length) {
      throw const TaggerSkip('skip overrun');
    }
    pos += n;
  }

  (int, int) readId() {
    final b = _readByte();
    int len;
    if ((b & 0x80) != 0) {
      len = 1;
    } else if ((b & 0x40) != 0) {
      len = 2;
    } else if ((b & 0x20) != 0) {
      len = 3;
    } else if ((b & 0x10) != 0) {
      len = 4;
    } else {
      throw const TaggerSkip('bad EBML id');
    }
    var id = b;
    for (var i = 1; i < len; i++) {
      id = (id << 8) | _readByte();
    }
    return (id, len);
  }

  /// (size, length); size -1 = unknown (all value bits set).
  (int, int) readSize() {
    final b = _readByte();
    int len;
    int mask;
    if ((b & 0x80) != 0) {
      len = 1;
      mask = 0x7F;
    } else if ((b & 0x40) != 0) {
      len = 2;
      mask = 0x3F;
    } else if ((b & 0x20) != 0) {
      len = 3;
      mask = 0x1F;
    } else if ((b & 0x10) != 0) {
      len = 4;
      mask = 0x0F;
    } else if ((b & 0x08) != 0) {
      len = 5;
      mask = 0x07;
    } else if ((b & 0x04) != 0) {
      len = 6;
      mask = 0x03;
    } else if ((b & 0x02) != 0) {
      len = 7;
      mask = 0x01;
    } else if (b == 0x01) {
      len = 8;
      mask = 0x00;
    } else {
      throw const TaggerSkip('bad EBML size');
    }
    var v = b & mask;
    for (var i = 1; i < len; i++) {
      v = (v << 8) | _readByte();
    }
    if (v == (1 << (7 * len)) - 1) return (-1, len);
    return (v, len);
  }
}

class _WebmPacket {
  final int timeMs;
  final Uint8List data;
  const _WebmPacket({required this.timeMs, required this.data});
}

class _WebmAudio {
  final Uint8List opusHead;
  final int preskip;
  final int timeScale;
  final List<_WebmPacket> packets;
  const _WebmAudio({
    required this.opusHead,
    required this.preskip,
    required this.timeScale,
    required this.packets,
  });
}

class _Mp4Box {
  final String type;
  final int headerLen;
  final int boxStart;
  final int contentStart;
  final int contentEnd;
  Uint8List? freshPayload;
  _Mp4Box({
    required this.type,
    required this.headerLen,
    required this.boxStart,
    required this.contentStart,
    required this.contentEnd,
    this.freshPayload,
  });
}
