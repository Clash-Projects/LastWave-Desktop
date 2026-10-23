import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/addons/local_media_server.dart';
import 'package:lastwave_desktop/features/addons/mp4_boxes.dart';

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
    return ResponseBody.fromBytes(bytes, 200);
  }

  @override
  void close({bool force = false}) {}
}

Map<String, List<int>> _bodies() => {
      'https://cdn.test/t/0.mp4?sig=abc': [0x66, 0x74, 0x79, 0x70],
      for (var i = 1; i <= 4; i++)
        'https://cdn.test/t/$i.mp4?sig=abc': [i, i + 10],
    };

/// Larger bodies matching [_manifest] (init + 4 segments) for the
/// slow-producer tests: big enough that a live GET spans the assembly.
Map<String, List<int>> _bigBodies({required int segmentBytes}) =>
    {
      'https://cdn.test/t/0.mp4?sig=abc':
          List<int>.generate(619, (i) => i % 251),
      for (var i = 1; i <= 4; i++)
        'https://cdn.test/t/$i.mp4?sig=abc':
            List<int>.generate(segmentBytes, (j) => (i * 31 + j) % 251),
    };

List<int> _bigExpected({required int segmentBytes}) => [
      ...List<int>.generate(619, (i) => i % 251),
      for (var i = 1; i <= 4; i++)
        ...List<int>.generate(segmentBytes, (j) => (i * 31 + j) % 251),
    ];

/// Stub that answers every fetch after [delay], so the session is still
/// assembling when the test client connects (the live-stream path).
class _DelayedAdapter implements HttpClientAdapter {
  _DelayedAdapter(this.bodies, this.delay);

  final Map<String, List<int>> bodies;
  final Duration delay;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    await Future.delayed(delay);
    final bytes = bodies[options.uri.toString()];
    if (bytes == null) {
      return ResponseBody.fromString('missing', 404);
    }
    return ResponseBody.fromBytes(bytes, 200);
  }

  @override
  void close({bool force = false}) {}
}

List<int> _expected() => [
      0x66, 0x74, 0x79, 0x70,
      for (var i = 1; i <= 4; i++) ...[i, i + 10],
    ];

Future<List<int>> _get(Uri uri, {Map<String, String>? headers}) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(uri);
    headers?.forEach(req.headers.set);
    final res = await req.close().timeout(const Duration(seconds: 30));
    final bytes = <int>[];
    await for (final chunk in res) {
      bytes.addAll(chunk);
    }
    return [res.statusCode, ...bytes];
  } finally {
    client.close();
  }
}

/// Session files live in the shared temp dir: remove them after each
/// test so runs never see each other's leftovers.
Future<void> _scrub(String cacheName) async {
  final dir =
      '${Directory.systemTemp.path}${Platform.pathSeparator}lastwave_addon${Platform.pathSeparator}assembled';
  for (final ext in ['m4a', 'part']) {
    try {
      await File(
              '$dir${Platform.pathSeparator}$cacheName.$ext')
          .delete();
    } catch (_) {}
  }
  // Fragment-size memo (feeds the front index on repeat plays).
  try {
    await File(
            '${Directory.systemTemp.path}${Platform.pathSeparator}lastwave_addon${Platform.pathSeparator}layout${Platform.pathSeparator}$cacheName.json')
        .delete();
  } catch (_) {}
}

// -- fMP4 fixtures (shape-compatible with the addon CDNs) ----------------

List<int> _be32(int v) =>
    [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];

List<int> _box(String type, List<int> payload) =>
    [..._be32(8 + payload.length), ...type.codeUnits, ...payload];

List<int> _initSegment({int trackId = 2, int timescale = 96000}) => [
      ..._box('ftyp', [...'iso6'.codeUnits, ..._be32(1)]),
      ..._box('moov', [
        ..._box('mvex', _box('trex', [0, 0, 0, 0, ...List.filled(20, 0)])),
        ..._box('trak', [
          ..._box('tkhd', [
            0, 0, 0, 0,
            ..._be32(0),
            ..._be32(0),
            ..._be32(trackId),
            ...List.filled(68, 0),
          ]),
          ..._box('mdia', [
            ..._box('mdhd', [
              0, 0, 0, 0,
              ..._be32(0),
              ..._be32(0),
              ..._be32(timescale),
              ..._be32(0),
            ]),
            ..._box('hdlr', [0, 0, 0, 0, ..._be32(0), ...'soun'.codeUnits]),
          ]),
        ]),
      ]),
    ];

List<int> _mediaSegment(int ticks, {int payload = 64}) => [
      ..._box('styp', [...'msdh'.codeUnits]),
      ..._box('moof', [
        ..._box('mfhd', [0, 0, 0, 0, ..._be32(1)]),
        ..._box('traf', [
          ..._box('tfhd', [0, 0, 0, 0, ..._be32(2)]),
          ..._box('tfdt', [
            1, 0, 0, 0,
            ..._be32(ticks >> 32),
            ..._be32(ticks),
          ]),
        ]),
      ]),
      ..._box('mdat', List.filled(payload, 7)),
    ];

void main() {
  group('LocalMediaServer', () {
    test('streams init + segments in order', () async {
      final dio = Dio();
      dio.httpClientAdapter = _StubAdapter(_bodies());
      final server = LocalMediaServer(dio: dio);
      addTearDown(server.close);
      addTearDown(() => _scrub('srv-test-stream'));
      final uri = await server.urlFor(
          manifestXml: _manifest, cacheName: 'srv-test-stream');
      expect(uri, isNotNull);
      final out = await _get(uri!);
      expect(out.first, HttpStatus.ok);
      expect(out.sublist(1), _expected());
    });

    test('range after completion serves 206', () async {
      final dio = Dio();
      dio.httpClientAdapter = _StubAdapter(_bodies());
      final server = LocalMediaServer(dio: dio);
      addTearDown(server.close);
      addTearDown(() => _scrub('srv-test-range'));
      final uri = await server.urlFor(
          manifestXml: _manifest, cacheName: 'srv-test-range');
      // First pass drives the session to completion.
      final full = await _get(uri!);
      expect(full.first, HttpStatus.ok);
      // Range request: raw client to inspect status + headers.
      final client = HttpClient();
      try {
        final req = await client.getUrl(uri);
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=2-5');
        final res = await req.close().timeout(
            const Duration(seconds: 30));
        final bytes = <int>[];
        await for (final chunk in res) {
          bytes.addAll(chunk);
        }
        expect(res.statusCode, HttpStatus.partialContent);
        expect(
            res.headers.value(HttpHeaders.contentRangeHeader),
            'bytes 2-5/${_expected().length}');
        expect(bytes, _expected().sublist(2, 6));
      } finally {
        client.close();
      }
    });

    test('unknown name 404s', () async {
      final dio = Dio();
      dio.httpClientAdapter = _StubAdapter(_bodies());
      final server = LocalMediaServer(dio: dio);
      addTearDown(server.close);
      addTearDown(() => _scrub('srv-test-known'));
      final uri = await server.urlFor(
          manifestXml: _manifest, cacheName: 'srv-test-known');
      final unknown = uri!.replace(path: '/a/srv-test-nope.m4a');
      final out = await _get(unknown);
      expect(out.first, HttpStatus.notFound);
      // The registration above kicked off a background assembly this
      // test never consumes: let it settle so teardown scrubs final
      // state instead of racing the producer (orphaned partials
      // otherwise litter the shared temp dir between runs).
      final want =
          '${Directory.systemTemp.path}${Platform.pathSeparator}lastwave_addon${Platform.pathSeparator}assembled${Platform.pathSeparator}srv-test-known.m4a';
      for (var i = 0; i < 100; i++) {
        if (File(want).existsSync()) break;
        await Future.delayed(const Duration(milliseconds: 50));
      }
    });

    test('bad manifest ends the stream instead of hanging', () async {
      final dio = Dio();
      dio.httpClientAdapter = _StubAdapter(_bodies());
      final server = LocalMediaServer(dio: dio);
      addTearDown(server.close);
      addTearDown(() => _scrub('srv-test-bad'));
      final uri = await server.urlFor(
          manifestXml: 'junk', cacheName: 'srv-test-bad');
      final out = await _get(uri!);
      expect(out.first, HttpStatus.ok);
      expect(out.sublist(1), isEmpty);
    });

    test('slow producer still delivers the full live stream', () async {
      // The Titli shape: the GET arrives while segments are still
      // downloading, so mpv reads the live (chunked) path. Every byte
      // must arrive — an early close plays the buffered prefix then
      // dies mid-track on a torn frame with a clean-EOF status.
      final bodies = _bigBodies(segmentBytes: 16384);
      final expected = _bigExpected(segmentBytes: 16384);
      final dio = Dio();
      dio.httpClientAdapter = _DelayedAdapter(bodies, const Duration(milliseconds: 50));
      final server = LocalMediaServer(dio: dio);
      addTearDown(server.close);
      for (var i = 0; i < 5; i++) {
        final cacheName = 'srv-test-slow-$i';
        addTearDown(() => _scrub(cacheName));
        final uri = await server.urlFor(
            manifestXml: _manifest, cacheName: cacheName);
        final out = await _get(uri!);
        expect(out.first, HttpStatus.ok, reason: 'iteration $i');
        expect(out.sublist(1), expected, reason: 'iteration $i');
      }
    });

    test('tail range issued mid-assembly waits and serves exact bytes',
        () async {
      final bodies = _bigBodies(segmentBytes: 16384);
      final expected = _bigExpected(segmentBytes: 16384);
      final dio = Dio();
      dio.httpClientAdapter = _DelayedAdapter(bodies, const Duration(milliseconds: 50));
      final server = LocalMediaServer(dio: dio);
      addTearDown(server.close);
      addTearDown(() => _scrub('srv-test-tail'));
      final uri = await server.urlFor(
          manifestXml: _manifest, cacheName: 'srv-test-tail');
      final total = expected.length;
      final client = HttpClient();
      try {
        final req = await client.getUrl(uri!);
        req.headers.set(
            HttpHeaders.rangeHeader, 'bytes=${total - 4}-${total - 1}');
        final res = await req.close().timeout(
            const Duration(seconds: 30));
        final bytes = <int>[];
        await for (final chunk in res) {
          bytes.addAll(chunk);
        }
        expect(res.statusCode, HttpStatus.partialContent);
        expect(res.headers.value(HttpHeaders.contentRangeHeader),
            'bytes ${total - 4}-${total - 1}/$total');
        expect(bytes, expected.sublist(total - 4));
      } finally {
        client.close();
      }
    });

    test('indexed layout puts a file-covering sidx after the init', () async {
      // The whole point of the index: ffmpeg's mov demuxer stops
      // scanning after the first fragment instead of walking to the
      // last byte, so audio starts while the rest is still downloading.
      const manifest = '''
<MPD type="static"><Period><AdaptationSet contentType="audio" mimeType="audio/mp4">
<Representation bandwidth="1500000"><SegmentTemplate timescale="96000"
  initialization="https://cdn.test/i/0.mp4"
  media="https://cdn.test/i/\$Number\$.mp4" startNumber="1">
<SegmentTimeline><S d="576000" r="2"/><S d="288000"/></SegmentTimeline>
</SegmentTemplate></Representation></AdaptationSet></Period></MPD>
''';
      final init = _initSegment(trackId: 2, timescale: 96000);
      final segments = [
        for (var i = 0; i < 4; i++)
          _mediaSegment(576000 * i, payload: 100 + i),
      ];
      final bodies = <String, List<int>>{
        'https://cdn.test/i/0.mp4': init,
        for (var i = 0; i < 4; i++)
          'https://cdn.test/i/${i + 1}.mp4': segments[i],
      };
      final dio = Dio();
      dio.httpClientAdapter = _StubAdapter(bodies);
      final server = LocalMediaServer(dio: dio);
      addTearDown(server.close);
      addTearDown(() => _scrub('srv-test-index'));
      final uri = await server.urlFor(
          manifestXml: manifest, cacheName: 'srv-test-index');
      final out = await _get(uri!);
      expect(out.first, HttpStatus.ok);
      final served = Uint8List.fromList(out.sublist(1));

      expect(served.sublist(0, init.length), init);
      final boxes = readMp4Boxes(served);
      final sidx = boxes.firstWhere((b) => b.type == 'sidx');
      expect(sidx.start, init.length);

      final view = ByteData.sublistView(served);
      expect(view.getUint32(sidx.payloadStart + 4), 2); // reference_ID
      expect(view.getUint32(sidx.payloadStart + 8), 96000); // timescale
      expect(view.getUint32(sidx.payloadStart + 16), 0); // first_offset
      final count = view.getUint16(sidx.payloadStart + 22);
      expect(count, segments.length);

      // Offsets + durations must reconstruct the file exactly: the
      // demuxer only trusts an index whose references end at EOF.
      var cursor = sidx.start + sidx.size;
      for (var i = 0; i < count; i++) {
        final ref = sidx.payloadStart + 24 + i * 12;
        expect(view.getUint32(ref), segments[i].length);
        expect(view.getUint32(ref + 4), i == 3 ? 288000 : 576000);
        expect(served.sublist(cursor, cursor + segments[i].length),
            segments[i]);
        cursor += segments[i].length;
      }
      expect(cursor, served.length);
    });
  });
}
