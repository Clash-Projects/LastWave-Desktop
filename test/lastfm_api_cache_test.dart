import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/network/lastfm_api.dart';
import 'package:lastwave_desktop/core/network/rate_guard.dart';

class _Adapter implements HttpClientAdapter {
  int calls = 0;
  String body = '{"ok":1}';

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<List<int>>? requestStream, Future<void>? cancelFuture) async {
    calls++;
    return ResponseBody.fromString(body, 200,
        headers: {Headers.contentTypeHeader: ['application/json']});
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late _Adapter adapter;
  late DateTime now;
  late LastFmApiService api;

  setUp(() {
    adapter = _Adapter();
    now = DateTime(2026, 11, 4, 12);
    final dio = Dio()..httpClientAdapter = adapter;
    api = LastFmApiService(dio, LastFmRateGuard(), clock: () => now);
  });

  test('a catalog read is replayed regardless of parameter order', () async {
    await api.get({'method': 'artist.getinfo', 'artist': 'A', 'api_key': 'k'});
    await api.get({'api_key': 'k', 'artist': 'A', 'method': 'artist.getInfo'});
    expect(adapter.calls, 1);
  });

  test('different parameters are different entries', () async {
    await api.get({'method': 'artist.getinfo', 'artist': 'A'});
    await api.get({'method': 'artist.getinfo', 'artist': 'B'});
    expect(adapter.calls, 2);
  });

  test('user data expires after two minutes', () async {
    await api.get({'method': 'user.getinfo', 'user': 'u'});
    now = now.add(const Duration(minutes: 3));
    await api.get({'method': 'user.getinfo', 'user': 'u'});
    expect(adapter.calls, 2);
  });

  test('recent tracks are never cached', () async {
    await api.get({'method': 'user.getrecenttracks', 'user': 'u'});
    await api.get({'method': 'user.getrecenttracks', 'user': 'u'});
    expect(adapter.calls, 2);
  });

  test('an API error body is not kept', () async {
    adapter.body = '{"error":6,"message":"x"}';
    await api.get({'method': 'artist.getinfo', 'artist': 'A'});
    await Future<void>.delayed(Duration.zero);
    adapter.body = '{"ok":1}';
    final again = await api.get({'method': 'artist.getinfo', 'artist': 'A'});
    expect(adapter.calls, 2);
    expect(again['ok'], 1);
  });

  test('concurrent callers share one request', () async {
    await Future.wait([
      api.get({'method': 'track.getsimilar', 'track': 't'}),
      api.get({'method': 'track.getsimilar', 'track': 't'}),
    ]);
    expect(adapter.calls, 1);
  });
}
