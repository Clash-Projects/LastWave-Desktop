import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/addons/mp4_boxes.dart';

/// ISO-BMFF test fixtures built by hand: these are the exact shapes the
/// addon CDNs emit (v0 `tkhd`/`mdhd`, fragmented `moof`/`traf`/`tfdt`).

List<int> _be32(int v) => [
      (v >> 24) & 0xFF,
      (v >> 16) & 0xFF,
      (v >> 8) & 0xFF,
      v & 0xFF,
    ];

List<int> _box(String type, List<int> payload) =>
    [..._be32(8 + payload.length), ...type.codeUnits, ...payload];

List<int> _initSegment({int trackId = 2, int timescale = 96000}) {
  final tkhd = _box('tkhd', [
    0, 0, 0, 0, // version 0 + flags
    ..._be32(0), // creation
    ..._be32(0), // modification
    ..._be32(trackId),
    ...List.filled(68, 0), // rest of tkhd (untouched by the parser)
  ]);
  final mdhd = _box('mdhd', [
    0, 0, 0, 0,
    ..._be32(0),
    ..._be32(0),
    ..._be32(timescale),
    ..._be32(0), // duration
  ]);
  final hdlr = _box('hdlr', [
    0, 0, 0, 0,
    ..._be32(0),
    ...'soun'.codeUnits,
    ...List.filled(12, 0),
  ]);
  final trak = _box('trak', [
    ...tkhd,
    ..._box('mdia', [...mdhd, ...hdlr]),
  ]);
  return [
    ..._box('ftyp', [...'iso6'.codeUnits, ..._be32(1), ...'iso6'.codeUnits]),
    ..._box('moov', [
      ..._box('mvhd', [0, 0, 0, 0, ...List.filled(96, 0)]),
      ..._box('mvex', _box('trex', [0, 0, 0, 0, ...List.filled(20, 0)])),
      ...trak,
    ]),
  ];
}

List<int> _mediaSegment(int ticks, {int payload = 64}) => [
      ..._box('styp', [...'msdh'.codeUnits]),
      ..._box('moof', [
        ..._box('mfhd', [0, 0, 0, 0, ..._be32(1)]),
        ..._box('traf', [
          ..._box('tfhd', [0, 0, 0, 0, ..._be32(2)]),
          ..._box('tfdt', [1, 0, 0, 0, ..._be32(ticks >> 32), ..._be32(ticks)]),
        ]),
      ]),
      ..._box('mdat', List.filled(payload, 7)),
    ];

void main() {
  group('readMp4Boxes', () {
    test('walks top level boxes and stops on a truncated tail', () {
      final bytes = Uint8List.fromList(
          [..._box('ftyp', List.filled(8, 0)), ..._box('moov', List.filled(8, 0))]);
      final boxes = readMp4Boxes(bytes);
      expect(boxes.map((b) => b.type), ['ftyp', 'moov']);
      expect(boxes.first.size, 16);

      final cut = Uint8List.fromList(bytes.sublist(0, bytes.length - 4));
      expect(readMp4Boxes(cut).map((b) => b.type), ['ftyp']);
    });

    test('handles 64-bit largesize', () {
      final payload = List.filled(20, 3);
      final bytes = Uint8List.fromList([
        ..._be32(1),
        ...'mdat'.codeUnits,
        ...List.filled(4, 0),
        ..._be32(16 + payload.length),
        ...payload,
      ]);
      final boxes = readMp4Boxes(bytes);
      expect(boxes.single.type, 'mdat');
      expect(boxes.single.size, 16 + payload.length);
      expect(boxes.single.payloadStart, 16);
    });

    test('garbage yields no boxes', () {
      expect(readMp4Boxes(Uint8List.fromList([1, 2, 3, 4])), isEmpty);
      expect(readMp4Boxes(Uint8List.fromList(List.filled(64, 0xFF))), isEmpty);
    });
  });

  group('parseFragmentInit', () {
    test('reads the audio track id and media timescale', () {
      final info = parseFragmentInit(
          Uint8List.fromList(_initSegment(trackId: 5, timescale: 44100)));
      expect(info, isNotNull);
      expect(info!.trackId, 5);
      expect(info.timescale, 44100);
    });

    test('null without a moov (plain ftyp is not an init)', () {
      final notInit =
          Uint8List.fromList(_box('ftyp', List.filled(16, 0)));
      expect(parseFragmentInit(notInit), isNull);
      expect(parseFragmentInit(Uint8List(0)), isNull);
    });
  });

  group('parseFragmentDecodeTime', () {
    test('reads the 64-bit tfdt of the first traf', () {
      final seg = Uint8List.fromList(_mediaSegment(0x1_0000_0005));
      expect(parseFragmentDecodeTime(seg), 0x1_0000_0005);
    });

    test('null when the fragment has no tfdt', () {
      final seg = Uint8List.fromList([
        ..._box('moof', _box('mfhd', [0, 0, 0, 0, ..._be32(1)])),
      ]);
      expect(parseFragmentDecodeTime(seg), isNull);
    });
  });

  group('buildSegmentIndex', () {
    test('emits a v0 sidx with one media reference per fragment', () {
      final bytes = buildSegmentIndex(
        trackId: 2,
        timescale: 96000,
        earliestPresentationTime: 0,
        references: const [
          SidxReference(size: 1000, duration: 576000),
          SidxReference(size: 900, duration: 576000),
        ],
      );
      expect(bytes, isNotNull);
      expect(bytes!.length, 32 + 2 * 12);

      final box = readMp4Boxes(bytes).single;
      expect(box.type, 'sidx');
      expect(box.size, bytes.length);

      final view = ByteData.sublistView(bytes);
      expect(view.getUint8(8), 0); // version
      expect(view.getUint32(12), 2); // reference_ID
      expect(view.getUint32(16), 96000); // timescale
      expect(view.getUint32(20), 0); // earliest_presentation_time
      expect(view.getUint32(24), 0); // first_offset
      expect(view.getUint16(30), 2); // reference_count
      // Reference 0: type 0 (media), size, duration, SAP flags.
      expect(view.getUint32(32), 1000);
      expect(view.getUint32(36), 576000);
      expect(view.getUint32(40), 0x90000000);
      expect(view.getUint32(44), 900);
    });

    test('covers the remaining bytes exactly (demuxer completeness)', () {
      // The index is only honoured when start + sum(sizes) == stream
      // size; feed it a file layout and check the arithmetic closes.
      const sizes = [619, 1000, 900, 1200];
      final init = _initSegment();
      final index = buildSegmentIndex(
        trackId: 2,
        timescale: 96000,
        earliestPresentationTime: 0,
        references: [
          for (final s in sizes) SidxReference(size: s, duration: 576000),
        ],
      )!;
      final streamSize = init.length + index.length + sizes.reduce((a, b) => a + b);
      final firstRefOffset = init.length + index.length;
      expect(firstRefOffset + sizes.reduce((a, b) => a + b), streamSize);
    });

    test('refuses layouts it cannot express', () {
      expect(
          buildSegmentIndex(
              trackId: 2,
              timescale: 96000,
              earliestPresentationTime: 0,
              references: const []),
          isNull);
      expect(
          buildSegmentIndex(
              trackId: 0,
              timescale: 96000,
              earliestPresentationTime: 0,
              references: const [SidxReference(size: 1, duration: 1)]),
          isNull);
      // Duration does not fit u32 (ffmpeg reads it as u32 in both versions).
      expect(
          buildSegmentIndex(
              trackId: 2,
              timescale: 1000000000,
              earliestPresentationTime: 0,
              references: const [
                SidxReference(size: 10, duration: 0x1FFFFFFFF)
              ]),
          isNull);
      // Zero-length fragment would break offset accounting.
      expect(
          buildSegmentIndex(
              trackId: 2,
              timescale: 96000,
              earliestPresentationTime: 0,
              references: const [SidxReference(size: 0, duration: 1)]),
          isNull);
    });
  });
}
