import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/video/chunked_range_proxy.dart';

/// An origin that behaves like googlevideo: it serves ranges, but answers
/// 403 to anything without an end ("bytes=0-" or no Range at all).
class _Origin {
  _Origin(this.data);
  final Uint8List data;
  late HttpServer server;
  final List<String> ranges = [];
  int rejected = 0;
  int maxSpan = 0;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final header = req.headers.value(HttpHeaders.rangeHeader);
      ranges.add(header ?? '-');
      final m = header == null
          ? null
          : RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(header);
      if (m == null) {
        rejected++;
        req.response.statusCode = HttpStatus.forbidden;
        await req.response.close();
        return;
      }
      final start = int.parse(m.group(1)!);
      var end = int.parse(m.group(2)!);
      if (start >= data.length) {
        req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        req.response.headers.set('content-range', 'bytes */${data.length}');
        await req.response.close();
        return;
      }
      if (end >= data.length) end = data.length - 1;
      if (end - start + 1 > maxSpan) maxSpan = end - start + 1;
      req.response.statusCode = HttpStatus.partialContent;
      req.response.headers
        ..set('content-type', 'video/mp4')
        ..set('content-range', 'bytes $start-$end/${data.length}')
        ..set('content-length', '${end - start + 1}');
      req.response.add(Uint8List.sublistView(data, start, end + 1));
      await req.response.close();
    });
  }

  Uri get uri => Uri.parse('http://127.0.0.1:${server.port}/videoplayback');
  Future<void> stop() => server.close(force: true);
}

Future<({int status, Uint8List body, Map<String, String> headers})> _get(
  Uri uri, {
  String? range,
  String method = 'GET',
}) async {
  final client = HttpClient();
  try {
    final req = await client.openUrl(method, uri);
    if (range != null) req.headers.set('range', range);
    final res = await req.close();
    final body = BytesBuilder();
    await for (final chunk in res) {
      body.add(chunk);
    }
    final headers = <String, String>{};
    res.headers.forEach((k, v) => headers[k] = v.join(','));
    return (status: res.statusCode, body: body.takeBytes(), headers: headers);
  } finally {
    client.close(force: true);
  }
}

void main() {
  late Uint8List data;
  late _Origin origin;
  late ChunkedRangeProxy proxy;
  late Uri local;
  const chunk = 64 * 1024;

  setUp(() async {
    // 1 MiB + a little, so there are many chunks and a short last one.
    data = Uint8List.fromList(
      List<int>.generate(1024 * 1024 + 4321, (i) => (i * 31 + i ~/ 251) & 0xFF),
    );
    origin = _Origin(data);
    await origin.start();
    proxy = ChunkedRangeProxy(chunkBytes: chunk);
    local = await proxy.register(origin.uri.toString());
  });

  tearDown(() async {
    await proxy.close();
    await origin.stop();
  });

  test(
    'an open-ended request from the player is served in bounded pieces',
    () async {
      final r = await _get(local, range: 'bytes=0-');
      expect(r.status, 206);
      expect(r.body, data);
      expect(
        r.headers['content-range'],
        'bytes 0-${data.length - 1}/${data.length}',
      );
      expect(
        origin.rejected,
        0,
        reason: 'the origin must never see an open range',
      );
      expect(origin.maxSpan, lessThanOrEqualTo(chunk));
      expect(origin.ranges.length, greaterThan(10));
    },
  );

  test(
    'no Range header at all still never reaches the origin open-ended',
    () async {
      final r = await _get(local);
      expect(r.status, 200);
      expect(r.body, data);
      expect(origin.rejected, 0);
    },
  );

  test('a seek into the middle returns exactly those bytes', () async {
    const start = 500000;
    final r = await _get(local, range: 'bytes=$start-');
    expect(r.status, 206);
    expect(r.body, Uint8List.sublistView(data, start));
    expect(origin.rejected, 0);
  });

  test('a bounded request is honoured exactly, across chunk edges', () async {
    const start = chunk - 10;
    const end = chunk * 3 + 17;
    final r = await _get(local, range: 'bytes=$start-$end');
    expect(r.status, 206);
    expect(r.body, Uint8List.sublistView(data, start, end + 1));
    expect(r.headers['content-length'], '${end - start + 1}');
    expect(origin.rejected, 0);
  });

  test('a small request is a single upstream request', () async {
    final r = await _get(local, range: 'bytes=100-199');
    expect(r.body, Uint8List.sublistView(data, 100, 200));
    expect(origin.ranges, ['bytes=100-199']);
  });

  test('a suffix range reads from the end', () async {
    final r = await _get(local, range: 'bytes=-1000');
    expect(r.status, 206);
    expect(r.body, Uint8List.sublistView(data, data.length - 1000));
    expect(origin.rejected, 0);
  });

  test('HEAD reports the size', () async {
    final r = await _get(local, method: 'HEAD');
    expect(r.status, 200);
    expect(r.headers['content-length'], '${data.length}');
    expect(r.headers['accept-ranges'], 'bytes');
  });

  test('a range past the end is refused, not hung', () async {
    final r = await _get(local, range: 'bytes=${data.length + 10}-');
    expect(r.status, 416);
  });

  test('an unknown source is a 404', () async {
    final r = await _get(local.replace(path: '/v/999'), range: 'bytes=0-');
    expect(r.status, 404);
  });

  test('several readers at once each get their own correct bytes', () async {
    final results = await Future.wait([
      _get(local, range: 'bytes=0-'),
      _get(local, range: 'bytes=300000-'),
      _get(local, range: 'bytes=900000-1000000'),
    ]);
    expect(results[0].body, data);
    expect(results[1].body, Uint8List.sublistView(data, 300000));
    expect(results[2].body, Uint8List.sublistView(data, 900000, 1000001));
    expect(origin.rejected, 0);
  });

  test('a reader that goes away does not wedge the proxy', () async {
    final client = HttpClient();
    final req = await client.getUrl(local);
    req.headers.set('range', 'bytes=0-');
    final res = await req.close();
    await res.first; // take one piece, then hang up
    client.close(force: true);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final again = await _get(local, range: 'bytes=0-1023');
    expect(again.body, Uint8List.sublistView(data, 0, 1024));
  });
}
