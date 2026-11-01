import 'dart:typed_data';
import 'package:pointycastle/export.dart';

class DecryptException implements Exception {
  final String message;
  const DecryptException(this.message);
  @override
  String toString() => 'DecryptException: $message';
}

class HybridPlan {
  final String cdnUrl;
  final ({int start, int end}) initRange;
  final List<({int start, int end})> ranges;
  final String key;
  final int ivSize;
  final String constantIv;
  final bool encrypted;

  const HybridPlan({
    required this.cdnUrl,
    required this.initRange,
    required this.ranges,
    required this.key,
    required this.ivSize,
    required this.constantIv,
    required this.encrypted,
  });

  static HybridPlan? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final cdnUrl = json['cdnUrl']?.toString() ?? '';
    if (cdnUrl.isEmpty) return null;

    final initMap = json['initRange'] as Map<String, dynamic>?;
    if (initMap == null) return null;
    final initStart = (initMap['start'] as num?)?.toInt() ?? 0;
    final initEnd = (initMap['end'] as num?)?.toInt() ?? 0;

    final rawRanges = json['ranges'] as List<dynamic>? ?? const [];
    final ranges = <({int start, int end})>[];
    for (final r in rawRanges) {
      if (r is Map) {
        final s = (r['start'] as num?)?.toInt() ?? 0;
        final e = (r['end'] as num?)?.toInt() ?? 0;
        ranges.add((start: s, end: e));
      }
    }
    if (ranges.isEmpty) return null;

    return HybridPlan(
      cdnUrl: cdnUrl,
      initRange: (start: initStart, end: initEnd),
      ranges: ranges,
      key: json['key']?.toString() ?? '',
      ivSize: (json['ivSize'] as num?)?.toInt() ?? 16,
      constantIv: json['constantIv']?.toString() ?? '',
      encrypted: json['encrypted'] == true,
    );
  }
}

class TencInfo {
  final int ivSize;
  final Uint8List constantIv;
  const TencInfo({required this.ivSize, required this.constantIv});
}

class SencEntry {
  final Uint8List iv;
  final List<Subsample> subsamples;
  const SencEntry({required this.iv, required this.subsamples});
}

class Subsample {
  final int clear;
  final int enc;
  const Subsample(this.clear, this.enc);
}

class CencBox {
  final String type;
  final int start;
  final int contentStart;
  final int end;
  const CencBox({
    required this.type,
    required this.start,
    required this.contentStart,
    required this.end,
  });
}

const int audioSampleEntryHeader = 36;
const List<String> protectionBoxes = ['senc', 'saiz', 'saio'];
const int sencSubsamplesFlag = 0x000002;

int _u32(Uint8List b, int off) {
  return ((b[off] << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3]) & 0xFFFFFFFF;
}

int _u64(Uint8List b, int off) {
  final high = _u32(b, off);
  final low = _u32(b, off + 4);
  return (high * 0x100000000) + low;
}

void _writeAscii(Uint8List b, int off, String str) {
  for (var i = 0; i < str.length; i++) {
    b[off + i] = str.codeUnitAt(i);
  }
}

String _ascii(Uint8List b, int off, int len) {
  return String.fromCharCodes(b, off, off + len);
}

Iterable<CencBox> iterBoxes(Uint8List buf, int start, int end) sync* {
  var off = start;
  while (off + 8 <= end) {
    var size = _u32(buf, off);
    final type = _ascii(buf, off + 4, 4);
    var header = 8;
    if (size == 1) {
      if (off + 16 > end) break;
      size = _u64(buf, off + 8);
      header = 16;
    } else if (size == 0) {
      size = end - off;
    }
    if (size < header || off + size > end) break;
    yield CencBox(
      type: type,
      start: off,
      contentStart: off + header,
      end: off + size,
    );
    off += size;
  }
}

CencBox? findBox(Uint8List buf, int start, int end, String type) {
  for (final box in iterBoxes(buf, start, end)) {
    if (box.type == type) return box;
  }
  return null;
}

CencBox? findPath(Uint8List buf, int start, int end, List<String> path) {
  var curStart = start;
  var curEnd = end;
  CencBox? found;
  for (final type in path) {
    found = findBox(buf, curStart, curEnd, type);
    if (found == null) return null;
    curStart = found.contentStart;
    curEnd = found.end;
  }
  return found;
}

TencInfo parseTenc(Uint8List buf, int contentStart, int boxEnd) {
  if (contentStart + 8 + 16 > boxEnd) {
    throw const DecryptException('tenc box truncated');
  }
  final isProtected = buf[contentStart + 6];
  final ivSize = buf[contentStart + 7];
  var constantIv = Uint8List(0);
  if (ivSize == 0 && isProtected != 0) {
    final off = contentStart + 8 + 16;
    if (off < boxEnd) {
      final civSize = buf[off];
      constantIv = buf.sublist(off + 1, off + 1 + civSize);
    }
  }
  return TencInfo(ivSize: ivSize, constantIv: constantIv);
}

TencInfo patchInitSegment(Uint8List buf) {
  final moov = findBox(buf, 0, buf.length, 'moov');
  if (moov == null) throw const DecryptException('no moov box found');

  final stsd = findPath(
    buf,
    moov.contentStart,
    moov.end,
    ['trak', 'mdia', 'minf', 'stbl', 'stsd'],
  );
  if (stsd == null) {
    throw const DecryptException('no moov/trak/mdia/minf/stbl/stsd box');
  }

  int? ivSize;
  var constantIv = Uint8List(0);

  for (final entry in iterBoxes(buf, stsd.contentStart + 8, stsd.end)) {
    final childStart = entry.start + audioSampleEntryHeader;
    if (childStart >= entry.end) continue;

    final sinf = findBox(buf, childStart, entry.end, 'sinf');
    if (sinf == null) continue;

    final frma = findBox(buf, sinf.contentStart, sinf.end, 'frma');
    if (frma != null) {
      _writeAscii(buf, entry.start + 4, _ascii(buf, frma.contentStart, 4));
    }

    final schm = findBox(buf, sinf.contentStart, sinf.end, 'schm');
    if (schm != null) {
      final scheme = _ascii(buf, schm.contentStart + 4, 4);
      if (scheme != 'cenc') {
        throw DecryptException('unsupported protection scheme $scheme; only cenc is supported');
      }
    }

    final tenc = findPath(buf, sinf.contentStart, sinf.end, ['schi', 'tenc']);
    if (tenc != null) {
      final info = parseTenc(buf, tenc.contentStart, tenc.end);
      ivSize = info.ivSize;
      constantIv = info.constantIv;
    }

    _writeAscii(buf, sinf.start + 4, 'free');
  }

  if (ivSize == null) {
    throw const DecryptException('no protected sample entry / tenc found in moov');
  }
  return TencInfo(ivSize: ivSize, constantIv: constantIv);
}

List<SencEntry> parseSenc(Uint8List buf, int contentStart, int boxEnd, int ivSize) {
  final flags = ((buf[contentStart + 1] << 16) |
          (buf[contentStart + 2] << 8) |
          buf[contentStart + 3]) &
      0xFFFFFF;
  final sampleCount = _u32(buf, contentStart + 4);
  var off = contentStart + 8;
  final entries = <SencEntry>[];

  for (var i = 0; i < sampleCount; i++) {
    final iv = ivSize > 0 ? buf.sublist(off, off + ivSize) : Uint8List(0);
    off += ivSize;
    final subsamples = <Subsample>[];
    if ((flags & sencSubsamplesFlag) != 0) {
      final subsampleCount = (buf[off] << 8) | buf[off + 1];
      off += 2;
      for (var s = 0; s < subsampleCount; s++) {
        final clear = (buf[off] << 8) | buf[off + 1];
        final enc = _u32(buf, off + 2);
        subsamples.add(Subsample(clear, enc));
        off += 6;
      }
    }
    entries.add(SencEntry(iv: iv, subsamples: subsamples));
  }
  return entries;
}

Uint8List normalizeIv(Uint8List iv, Uint8List constantIv) {
  var value = iv;
  if (value.isEmpty) value = constantIv;
  final out = Uint8List(16);
  final copyLen = value.length < 16 ? value.length : 16;
  out.setRange(0, copyLen, value);
  return out;
}

Uint8List importContentKey(String hexKey) {
  final clean = hexKey.trim().replaceAll(RegExp(r'^0x', caseSensitive: false), '').replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  if (clean.length != 32) {
    throw DecryptException('content key must be 16 bytes of hex, got ${clean.length ~/ 2}');
  }
  final bytes = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    bytes[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return bytes;
}

void decryptSample(
  Uint8List buf,
  int position,
  int size,
  Uint8List iv16,
  List<Subsample> subsamples,
  Uint8List keyBytes,
) {
  final ranges = <({int off, int len})>[];
  if (subsamples.isEmpty) {
    ranges.add((off: position, len: size));
  } else {
    var off = position;
    for (final sub in subsamples) {
      off += sub.clear;
      if (sub.enc > 0) ranges.add((off: off, len: sub.enc));
      off += sub.enc;
    }
  }

  var total = 0;
  for (final r in ranges) {
    total += r.len;
  }
  if (total == 0) return;

  final packed = Uint8List(total);
  var write = 0;
  for (final r in ranges) {
    packed.setRange(write, write + r.len, buf, r.off);
    write += r.len;
  }

  final cipher = CTRStreamCipher(AESEngine())
    ..init(false, ParametersWithIV(KeyParameter(keyBytes), iv16));
  final plain = cipher.process(packed);

  var read = 0;
  for (final r in ranges) {
    buf.setRange(r.off, r.off + r.len, plain, read);
    read += r.len;
  }
}

void processTraf(
  Uint8List buf,
  CencBox traf,
  int moofStartInFile,
  int segmentStart,
  int ivSize,
  Uint8List constantIv,
  Uint8List keyBytes,
) {
  final tfhd = findBox(buf, traf.contentStart, traf.end, 'tfhd');
  if (tfhd == null) return;

  final tfhdFlags = (_u32(buf, tfhd.contentStart + 1) >> 8) & 0xFFFFFF;
  var off = tfhd.contentStart + 8;
  int? baseDataOffset;
  var defaultDuration = 0;
  var defaultSize = 0;

  if ((tfhdFlags & 0x000001) != 0) {
    baseDataOffset = _u64(buf, off);
    off += 8;
  }
  if ((tfhdFlags & 0x000002) != 0) off += 4;
  if ((tfhdFlags & 0x000008) != 0) {
    defaultDuration = _u32(buf, off);
    off += 4;
  }
  if ((tfhdFlags & 0x000010) != 0) {
    defaultSize = _u32(buf, off);
    off += 4;
  }

  final senc = findBox(buf, traf.contentStart, traf.end, 'senc');
  if (senc == null) return;
  final sencEntries = parseSenc(buf, senc.contentStart, senc.end, ivSize);
  if (sencEntries.isEmpty) return;

  final base = baseDataOffset ?? moofStartInFile;

  var sampleIndex = 0;
  for (final box in iterBoxes(buf, traf.contentStart, traf.end)) {
    if (box.type != 'trun') continue;

    final trunFlags = (_u32(buf, box.contentStart + 1) >> 8) & 0xFFFFFF;
    final count = _u32(buf, box.contentStart + 4);
    var toff = box.contentStart + 8;
    int? dataOffset;

    if ((trunFlags & 0x000001) != 0) {
      final raw = _u32(buf, toff);
      dataOffset = raw >= 0x80000000 ? raw - 0x100000000 : raw;
      toff += 4;
    }
    if ((trunFlags & 0x000004) != 0) toff += 4;

    var pos = base + (dataOffset ?? 0);
    for (var i = 0; i < count; i++) {
      var sampleDuration = defaultDuration;
      var sampleSize = defaultSize;
      if ((trunFlags & 0x000100) != 0) {
        sampleDuration = _u32(buf, toff);
        toff += 4;
      }
      if ((trunFlags & 0x000200) != 0) {
        sampleSize = _u32(buf, toff);
        toff += 4;
      }
      if ((trunFlags & 0x000400) != 0) toff += 4;
      if ((trunFlags & 0x000800) != 0) toff += 4;

      final entry = sampleIndex < sencEntries.length ? sencEntries[sampleIndex] : null;
      final iv = entry?.iv ?? Uint8List(0);
      final subsamples = entry?.subsamples ?? const [];

      if (iv.isNotEmpty || constantIv.isNotEmpty) {
        final bufferPos = pos - segmentStart;
        if (bufferPos >= 0 && bufferPos + sampleSize <= buf.length) {
          decryptSample(
            buf,
            bufferPos,
            sampleSize,
            normalizeIv(iv, constantIv),
            subsamples,
            keyBytes,
          );
        }
      }
      pos += sampleSize;
      sampleIndex++;
    }
  }

  // Strip protection boxes
  for (final box in iterBoxes(buf, traf.contentStart, traf.end)) {
    if (protectionBoxes.contains(box.type)) {
      _writeAscii(buf, box.start + 4, 'free');
      continue;
    }
    if (box.type == 'sbgp' || box.type == 'sgpd') {
      if (_ascii(buf, box.contentStart + 4, 4) == 'seig') {
        _writeAscii(buf, box.start + 4, 'free');
      }
    }
  }
}

void decryptSegment(
  Uint8List buf,
  Uint8List keyBytes,
  int ivSize,
  Uint8List constantIv,
  int segmentStart,
) {
  CencBox? pendingMoof;

  for (final box in iterBoxes(buf, 0, buf.length)) {
    if (box.type == 'moof') {
      pendingMoof = box;
      continue;
    }
    if (box.type == 'mdat' && pendingMoof != null) {
      final moofStartInFile = segmentStart + pendingMoof.start;
      for (final child in iterBoxes(buf, pendingMoof.contentStart, pendingMoof.end)) {
        if (child.type != 'traf') continue;
        processTraf(
          buf,
          child,
          moofStartInFile,
          segmentStart,
          ivSize,
          constantIv,
          keyBytes,
        );
      }
      pendingMoof = null;
    }
  }
}
