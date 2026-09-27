import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/addons/local_media_server.dart';

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
}

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
  });
}
