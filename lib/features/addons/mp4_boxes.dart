import 'dart:typed_data';

/// Minimal ISO-BMFF (MP4) box reader plus the two boxes the loopback
/// assembler needs to hand libmpv an *indexed* file.
///
/// Why this exists (see `local_media_server.dart` for the full story):
/// ffmpeg's `mov` demuxer walks every top-level atom before its first
/// packet unless it can prove the fragment index is complete. For a
/// fragmented MP4 that means it seeks through the WHOLE file — every
/// `moof`/`mdat` pair — so a streamed assembly only starts playing once
/// the last fragment has landed. A `sidx` box that covers the file
/// exactly flips `frag_index.complete`, the scan stops after the first
/// fragment, and seeks use the index instead of a linear walk.
///
/// Pure functions over bytes: no IO, no Dio, unit-tested.

/// One top-level (or nested, via an explicit range) MP4 box.
class Mp4Box {
  const Mp4Box({
    required this.type,
    required this.start,
    required this.size,
    required this.payloadStart,
  });

  /// Four-character box type (ASCII, e.g. `moov`, `sidx`, `tfdt`).
  final String type;

  /// Offset of the box header in the buffer.
  final int start;

  /// Total box length in bytes, header included.
  final int size;

  /// Offset of the first payload byte (after size/type/largesize).
  final int payloadStart;

  int get payloadEnd => start + size;
}

/// Walk the boxes in `bytes` between [start] and [end].
///
/// Stops at the first truncated or nonsensical box instead of throwing:
/// callers hand this partial fragments and probe buffers, and a short
/// tail must never fail an assembly.
List<Mp4Box> readMp4Boxes(Uint8List bytes, {int start = 0, int? end}) {
  final out = <Mp4Box>[];
  final limit = (end ?? bytes.length).clamp(0, bytes.length);
  if (limit - start < 8) return out;
  final data = ByteData.sublistView(bytes);
  var p = start;
  while (p + 8 <= limit) {
    var size = data.getUint32(p);
    final type = String.fromCharCodes(bytes, p + 4, p + 8);
    var header = 8;
    if (size == 1) {
      if (p + 16 > limit) break;
      size = data.getUint64(p + 8);
      header = 16;
    } else if (size == 0) {
      // Extends to the end of the enclosing buffer.
      size = limit - p;
    }
    if (size < header || p + size > limit) break;
    out.add(Mp4Box(
      type: type,
      start: p,
      size: size,
      payloadStart: p + header,
    ));
    p += size;
  }
  return out;
}

/// Track id + media timescale of the fMP4 init segment, i.e. exactly
/// what `mov_read_sidx` uses to match the index to a stream.
class FragmentInitInfo {
  const FragmentInitInfo({required this.trackId, required this.timescale});

  final int trackId;
  final int timescale;

  @override
  String toString() => 'FragmentInitInfo($trackId, ${timescale}Hz)';
}

/// Parse the `moov` of an init segment. Prefers the audio track, falls
/// back to the first usable track. Null when the bytes aren't an fMP4
/// init (the caller then assembles without an index).
FragmentInitInfo? parseFragmentInit(Uint8List init) {
  final moov = _first(readMp4Boxes(init), 'moov');
  if (moov == null) return null;
  final moovKids = readMp4Boxes(init,
      start: moov.payloadStart, end: moov.payloadEnd);
  FragmentInitInfo? fallback;
  for (final trak in moovKids) {
    if (trak.type != 'trak') continue;
    final trakKids = readMp4Boxes(init,
        start: trak.payloadStart, end: trak.payloadEnd);
    final tkhd = _first(trakKids, 'tkhd');
    final mdia = _first(trakKids, 'mdia');
    if (tkhd == null || mdia == null) continue;
    final trackId = _readTrackId(init, tkhd);
    if (trackId == null || trackId <= 0) continue;
    final mdiaKids = readMp4Boxes(init,
        start: mdia.payloadStart, end: mdia.payloadEnd);
    final mdhd = _first(mdiaKids, 'mdhd');
    if (mdhd == null) continue;
    final timescale = _readMdhdTimescale(init, mdhd);
    if (timescale == null || timescale <= 0) continue;
    final info = FragmentInitInfo(trackId: trackId, timescale: timescale);
    if (_handlerType(init, _first(mdiaKids, 'hdlr')) == 'soun') return info;
    fallback ??= info;
  }
  return fallback;
}

/// `tfdt.baseMediaDecodeTime` of the first fragment in [segment] — the
/// presentation time the file index must start from. Null when absent.
int? parseFragmentDecodeTime(Uint8List segment) {
  final moof = _first(readMp4Boxes(segment), 'moof');
  if (moof == null) return null;
  final data = ByteData.sublistView(segment);
  for (final traf in readMp4Boxes(segment,
      start: moof.payloadStart, end: moof.payloadEnd)) {
    if (traf.type != 'traf') continue;
    final tfdt = _first(
        readMp4Boxes(segment,
            start: traf.payloadStart, end: traf.payloadEnd),
        'tfdt');
    if (tfdt == null || tfdt.payloadStart + 4 > tfdt.payloadEnd) continue;
    final version = segment[tfdt.payloadStart];
    if (version == 1) {
      if (tfdt.payloadStart + 12 > tfdt.payloadEnd) continue;
      return data.getUint64(tfdt.payloadStart + 4);
    }
    return data.getUint32(tfdt.payloadStart + 4);
  }
  return null;
}

/// One `sidx` reference: a media subsegment that immediately follows the
/// previous one, with its byte length and duration in index ticks.
class SidxReference {
  const SidxReference({required this.size, required this.duration});

  final int size;
  final int duration;
}

/// Build a version-0 `sidx` describing every fragment from the end of
/// the box to EOF.
///
/// [references] must cover the file exactly: the demuxer marks the index
/// complete only when `start + sum(sizes) == stream size`, so a wrong
/// length silently degrades to the slow scan (never a broken file).
/// Returns null when the layout can't be expressed (u32 overflow) —
/// callers then assemble without an index.
Uint8List? buildSegmentIndex({
  required int trackId,
  required int timescale,
  required int earliestPresentationTime,
  required List<SidxReference> references,
}) {
  if (references.isEmpty || trackId <= 0 || timescale <= 0) return null;
  if (earliestPresentationTime < 0 ||
      earliestPresentationTime > 0xFFFFFFFF) {
    return null;
  }
  for (final r in references) {
    // reference_type 0 (media) keeps the top bit clear.
    if (r.size <= 0 || r.size > 0x7FFFFFFF) return null;
    // u32 in both versions: ffmpeg reads `duration` as u32.
    if (r.duration <= 0 || r.duration > 0xFFFFFFFF) return null;
  }
  // 8 header + 4 fullbox + 4 refId + 4 timescale + 4 ept + 4 firstOffset
  // + 2 reserved + 2 count, then 12 bytes per reference.
  final byteLength = 32 + references.length * 12;
  final out = Uint8List(byteLength);
  final view = ByteData.sublistView(out);
  view.setUint32(0, byteLength);
  out.setRange(4, 8, 'sidx'.codeUnits);
  view.setUint8(8, 0); // version 0 = 32-bit ept/first_offset
  view.setUint8(9, 0);
  view.setUint16(10, 0); // flags
  view.setUint32(12, trackId);
  view.setUint32(16, timescale);
  view.setUint32(20, earliestPresentationTime);
  view.setUint32(24, 0); // first_offset: fragment 0 abuts the box
  view.setUint16(28, 0); // reserved
  view.setUint16(30, references.length);
  var p = 32;
  for (final r in references) {
    view.setUint32(p, r.size);
    view.setUint32(p + 4, r.duration);
    // starts_with_SAP=1, SAP_type=1 (every fragment begins a sync point).
    view.setUint32(p + 8, 0x90000000);
    p += 12;
  }
  return out;
}

Mp4Box? _first(List<Mp4Box> boxes, String type) {
  for (final b in boxes) {
    if (b.type == type) return b;
  }
  return null;
}

int? _readTrackId(Uint8List bytes, Mp4Box tkhd) {
  if (tkhd.payloadStart + 4 > tkhd.payloadEnd) return null;
  final version = bytes[tkhd.payloadStart];
  // fullbox(4) + creation + modification, then track_ID.
  final offset = version == 1 ? 20 : 12;
  if (tkhd.payloadStart + offset + 4 > tkhd.payloadEnd) return null;
  return ByteData.sublistView(bytes).getUint32(tkhd.payloadStart + offset);
}

int? _readMdhdTimescale(Uint8List bytes, Mp4Box mdhd) {
  if (mdhd.payloadStart + 4 > mdhd.payloadEnd) return null;
  final version = bytes[mdhd.payloadStart];
  // fullbox(4) + creation + modification, then timescale.
  final offset = version == 1 ? 20 : 12;
  if (mdhd.payloadStart + offset + 4 > mdhd.payloadEnd) return null;
  return ByteData.sublistView(bytes).getUint32(mdhd.payloadStart + offset);
}

String _handlerType(Uint8List bytes, Mp4Box? hdlr) {
  if (hdlr == null) return '';
  // fullbox(4) + pre_defined(4), then handler_type.
  final at = hdlr.payloadStart + 8;
  if (at + 4 > hdlr.payloadEnd) return '';
  return String.fromCharCodes(bytes, at, at + 4);
}
