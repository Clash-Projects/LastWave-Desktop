import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/addons/dash_assembler.dart';

const _manifest = '''
<MPD type="static" mediaPresentationDuration="PT4M7S">
  <Period id="0">
    <AdaptationSet contentType="audio" mimeType="audio/mp4">
      <Representation id="FLAC_HIRES,48000,24" codecs="flac"
          bandwidth="1548763" audioSamplingRate="48000">
        <SegmentTemplate timescale="48000"
            initialization="https://cdn.test/t/0.mp4?sig=abc"
            media="https://cdn.test/t/\$Number\$.mp4?sig=abc"
            startNumber="1">
          <SegmentTimeline><S d="188416" r="2"/><S d="13581"/></SegmentTimeline>
        </SegmentTemplate>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>
''';

/// In-memory HTTP stub: maps exact URLs to bodies.
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.bodies);

  final Map<String, List<int>> bodies;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final bytes = bodies[options.uri.toString()];
    if (bytes == null) {
      return ResponseBody.fromString('missing', 404);
    }
    return ResponseBody.fromBytes(bytes, 200, headers: {
      Headers.contentLengthHeader: [bytes.length.toString()],
    });
  }

  @override
  void close({bool force = false}) {}
}

Dio _dioWith(Map<String, List<int>> bodies) {
  final dio = Dio();
  dio.httpClientAdapter = _StubAdapter(bodies);
  return dio;
}

void main() {
  group('planForManifest', () {
    test('numbered timeline counts segments', () {
      final plan = DashAssembler.planForManifest(_manifest);
      expect(plan, isNotNull);
      expect(plan!.initUrl, 'https://cdn.test/t/0.mp4?sig=abc');
      expect(plan.startNumber, 1);
      // r="2" -> 3 segments + trailing S -> 4 total.
      expect(plan.segmentCount, 4);
    });

    test('richest representation wins', () {
      const multi = '''
<MPD type="static"><Period>
<AdaptationSet contentType="audio" mimeType="audio/mp4">
<Representation bandwidth="320000">
<SegmentTemplate initialization="https://cdn.test/lo/0.mp4"
media="https://cdn.test/lo/\$Number\$.mp4">
<SegmentTimeline><S d="1"/></SegmentTimeline>
</SegmentTemplate></Representation>
<Representation bandwidth="1500000">
<SegmentTemplate initialization="https://cdn.test/hi/0.mp4"
media="https://cdn.test/hi/\$Number\$.mp4">
<SegmentTimeline><S d="1" r="1"/></SegmentTimeline>
</SegmentTemplate></Representation>
</AdaptationSet></Period></MPD>
''';
      final plan = DashAssembler.planForManifest(multi);
      expect(plan?.initUrl, 'https://cdn.test/hi/0.mp4');
      expect(plan?.segmentCount, 2);
    });

    test('rejects non-audio, SegmentList, missing timeline', () {
      expect(
          DashAssembler.planForManifest(
              '<MPD><Period><AdaptationSet contentType="video"/></Period></MPD>'),
          isNull);
      expect(
          DashAssembler.planForManifest(
              '<MPD><Period><AdaptationSet contentType="audio"><Representation><SegmentList/></Representation></AdaptationSet></Period></MPD>'),
          isNull);
      expect(
          DashAssembler.planForManifest(
              '<MPD><Period><AdaptationSet contentType="audio"><Representation><SegmentTemplate initialization="i" media="m\$Number\$"/></Representation></AdaptationSet></Period></MPD>'),
          isNull);
    });

    test('rejects absurd segment counts', () {
      final huge = _manifest.replaceFirst('r="2"', 'r="9999"');
      expect(DashAssembler.planForManifest(huge), isNull);
    });

    test('rejects garbage xml', () {
      expect(DashAssembler.planForManifest('not xml'), isNull);
      expect(DashAssembler.planForManifest(''), isNull);
    });
  });

  group('segmentUrlFor', () {    test('plain \$Number\$', () {
      expect(
          DashAssembler.segmentUrlFor(
              'https://cdn.test/t/\$Number\$.mp4?sig=abc', 7),
          'https://cdn.test/t/7.mp4?sig=abc');
    });

    test('zero-padded \$Number%03d\$', () {
      expect(
          DashAssembler.segmentUrlFor(
              'https://cdn.test/t/\$Number%03d\$.mp4', 7),
          'https://cdn.test/t/007.mp4');
    });
  });

  group('fetchSegments', () {
    test('fills slots and reports batches', () async {
      final bodies = <String, List<int>>{
        for (var i = 1; i <= 4; i++)
          'https://cdn.test/t/$i.mp4?sig=abc':
              List.filled(300, i),
      };
      final slots = List<List<int>?>.filled(4, null);
      final batches = <List<int>>[];
      final ok = await DashAssembler.fetchSegments(
        _dioWith(bodies),
        mediaTemplate: 'https://cdn.test/t/\$Number\$.mp4?sig=abc',
        startNumber: 1,
        count: 4,
        onSegment: (i, bytes) => slots[i] = bytes,
        onBatch: (base, end) async => batches.add([base, end]),
      );
      expect(ok, isTrue);
      for (var i = 0; i < 4; i++) {
        expect(slots[i], List.filled(300, i + 1));
      }
      // 4 segments < one parallel batch.
      expect(batches, [
        [0, 4]
      ]);
    });

    test('false on any miss (fall through, never crash)', () async {
      final bodies = <String, List<int>>{
        'https://cdn.test/t/1.mp4?sig=abc': List.filled(300, 1),
        // 2..4 missing -> 404s.
      };
      final ok = await DashAssembler.fetchSegments(
        _dioWith(bodies),
        mediaTemplate: 'https://cdn.test/t/\$Number\$.mp4?sig=abc',
        startNumber: 1,
        count: 4,
        onSegment: (i, bytes) {},
      );
      expect(ok, isFalse);
    });
  });

  group('fetchInit', () {
    test('stalled attempts retry with quick timeouts', () async {
      var calls = 0;
      final dio = Dio();
      dio.httpClientAdapter = _CountingAdapter((url) {
        calls++;
        // First two attempts fail fast (500s); third succeeds.
        if (calls < 3) return null;
        return [1, 2, 3];
      });
      final bytes = await DashAssembler.fetchInit(
          dio, 'https://cdn.test/init.mp4');
      expect(bytes, [1, 2, 3]);
      expect(calls, 3);
    });

    test('all attempts failing returns null', () async {
      final dio = Dio();
      dio.httpClientAdapter = _CountingAdapter((url) => null);
      expect(await DashAssembler.fetchInit(dio, 'https://cdn.test/x'),
          isNull);
    });
  });
}

/// Adapter with scripted per-URL bodies (null = instant 500).
class _CountingAdapter implements HttpClientAdapter {
  _CountingAdapter(this.script);

  final List<int>? Function(String url) script;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final bytes = script(options.uri.toString());
    if (bytes == null) {
      return ResponseBody.fromString('blip', 500);
    }
    return ResponseBody.fromBytes(bytes, 200);
  }

  @override
  void close({bool force = false}) {}
}
