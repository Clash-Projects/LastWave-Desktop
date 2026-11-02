import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/addons/hybrid_cenc.dart';
import 'package:pointycastle/export.dart';

Uint8List concat(List<Uint8List> parts) {
  final total = parts.fold<int>(0, (sum, p) => sum + p.length);
  final out = Uint8List(total);
  var off = 0;
  for (final p in parts) {
    out.setRange(off, off + p.length, p);
    off += p.length;
  }
  return out;
}

Uint8List u32Bytes(int value) {
  final out = Uint8List(4);
  ByteData.sublistView(out).setUint32(0, value);
  return out;
}

Uint8List box(String type, List<Uint8List> parts) {
  final body = concat(parts);
  final out = Uint8List(8 + body.length);
  ByteData.sublistView(out).setUint32(0, 8 + body.length);
  out.setRange(4, 8, utf8.encode(type));
  out.setRange(8, 8 + body.length, body);
  return out;
}

Uint8List fullBox(String type, int version, int flags, List<Uint8List> parts) {
  final head = Uint8List(4);
  head[0] = version;
  head[1] = (flags >> 16) & 0xff;
  head[2] = (flags >> 8) & 0xff;
  head[3] = flags & 0xff;
  return box(type, [head, ...parts]);
}

final sampleIv = Uint8List.fromList([
  0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
  0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00,
]);

const contentKeyHex = '00112233445566778899aabbccddeeff';

Uint8List buildInitSegment({int ivSize = 16}) {
  final tencPayload = Uint8List(2 + 1 + 1 + 16 + 1 + 16);
  tencPayload[2] = 1; // isProtected
  tencPayload[3] = ivSize; // per-sample IV size
  tencPayload.setRange(4, 20, sampleIv); // KID
  tencPayload[20] = 16; // constant IV size
  tencPayload.setRange(21, 37, sampleIv); // constant IV

  final tenc = fullBox('tenc', 0, 0, [tencPayload]);
  final schi = box('schi', [tenc]);
  final schm = fullBox('schm', 0, 0, [Uint8List.fromList(utf8.encode('cenc'))]);
  final frma = box('frma', [Uint8List.fromList(utf8.encode('fLaC'))]);
  final sinf = box('sinf', [frma, schm, schi]);

  final sampleEntry = box('encv', [Uint8List(28), sinf]);
  final stsd = fullBox('stsd', 0, 0, [u32Bytes(1), sampleEntry]);
  final stbl = box('stbl', [stsd]);
  final minf = box('minf', [stbl]);
  final mdia = box('mdia', [minf]);
  final trak = box('trak', [mdia]);
  return box('moov', [trak]);
}

Uint8List buildMediaSegment(Uint8List payload) {
  Uint8List makeMoof(int dataOffset) {
    final senc = fullBox('senc', 0, 0, [u32Bytes(1), sampleIv]);
    final offsetBytes = Uint8List(4);
    ByteData.sublistView(offsetBytes).setInt32(0, dataOffset);
    final trun = fullBox(
      'trun',
      0,
      0x301,
      [
        u32Bytes(1),
        offsetBytes,
        u32Bytes(payload.length),
        u32Bytes(payload.length),
      ],
    );
    final tfhd = fullBox('tfhd', 0, 0x000, []);
    final traf = box('traf', [tfhd, trun, senc]);
    final mfhd = fullBox('mfhd', 0, 0, [u32Bytes(1)]);
    return box('moof', [mfhd, traf]);
  }

  final probe = makeMoof(0);
  final dataOffset = probe.length + 8;
  final moof = makeMoof(dataOffset);
  final mdat = box('mdat', [payload]);
  return concat([moof, mdat]);
}

void main() {
  group('patchInitSegment', () {
    test('restores original sample format and marks sinf as free', () {
      final init = buildInitSegment(ivSize: 16);
      final before = init.length;

      final stsdBox = findPath(init, 0, init.length, ['moov', 'trak', 'mdia', 'minf', 'stbl', 'stsd'])!;
      final entry = iterBoxes(init, stsdBox.contentStart + 8, stsdBox.end).first;
      final sinfPos = findBox(init, entry.start + 36, entry.end, 'sinf')!.start;

      final info = patchInitSegment(init);

      expect(info.ivSize, equals(16));
      expect(info.constantIv, isEmpty);
      expect(init.length, equals(before));

      expect(String.fromCharCodes(init, sinfPos + 4, sinfPos + 8), equals('free'));
      expect(String.fromCharCodes(init, entry.start + 4, entry.start + 8), equals('fLaC'));
    });

    test('reads constant IV when per-sample IV size is zero', () {
      final info = patchInitSegment(buildInitSegment(ivSize: 0));
      expect(info.ivSize, equals(0));
      expect(info.constantIv, equals(sampleIv));
    });
  });

  group('decryptSegment', () {
    test('restores plaintext and marks senc as free', () {
      final keyBytes = importContentKey(contentKeyHex);

      final plaintext = Uint8List(64);
      for (var i = 0; i < plaintext.length; i++) {
        plaintext[i] = (i * 7 + 3) & 0xff;
      }

      final cipher = CTRStreamCipher(AESEngine())
        ..init(true, ParametersWithIV(KeyParameter(keyBytes), sampleIv));
      final ciphertext = cipher.process(plaintext);

      final segment = buildMediaSegment(ciphertext);
      final lengthBefore = segment.length;
      final sencPos = findPath(segment, 0, segment.length, ['moof', 'traf', 'senc'])!.start;

      decryptSegment(segment, keyBytes, 16, Uint8List(0), 0);

      expect(segment.length, equals(lengthBefore));

      final mdat = findBox(segment, 0, segment.length, 'mdat')!;
      final restored = segment.sublist(mdat.contentStart, mdat.end);
      expect(restored, equals(plaintext));

      expect(String.fromCharCodes(segment, sencPos + 4, sencPos + 8), equals('free'));
    });
  });
}
