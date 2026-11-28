import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/storage/secure_store.dart';
import 'package:lastwave_desktop/features/innertube/innertube_api.dart';

void main() {
  group('signed-out detection', signedOutDetection);

  const jar = 'SAPISID=s; __Secure-1PSIDTS=old1; __Secure-3PSIDTS=old3; '
      'SIDCC=c0';

  test('rotated session cookies replace their stale values', () {
    final out = InnerTubeMusicApi.mergeRotatedCookies(
      jar,
      const [
        '__Secure-1PSIDTS=new1; Domain=.youtube.com; Path=/; Secure; HttpOnly',
        '__Secure-3PSIDTS=new3; Domain=.youtube.com; Path=/; Secure; SameSite=none',
      ],
      host: 'music.youtube.com',
    );
    expect(out, isNotNull);
    expect(out, contains('__Secure-1PSIDTS=new1'));
    expect(out, contains('__Secure-3PSIDTS=new3'));
    expect(out, contains('SAPISID=s'));
    expect(out, contains('SIDCC=c0'));
    expect(out, isNot(contains('old1')));
  });

  test('host-only cookie uses the request host for scoping', () {
    final out = InnerTubeMusicApi.mergeRotatedCookies(
      jar,
      const ['SIDCC=c1; Path=/'],
      host: 'music.youtube.com',
    );
    expect(out, contains('SIDCC=c1'));
  });

  test('unknown names, foreign domains and deletions are ignored', () {
    final out = InnerTubeMusicApi.mergeRotatedCookies(
      jar,
      const [
        'TRACKER=x; Domain=.youtube.com',
        'SIDCC=evil; Domain=.example.com',
        'SAPISID=; Domain=.youtube.com',
        '__Secure-1PSIDTS=gone; Max-Age=0; Domain=.youtube.com',
        '__Secure-3PSIDTS=gone; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Domain=.youtube.com',
      ],
      host: 'music.youtube.com',
    );
    expect(out, isNull);
  });

  test('identical values report no change', () {
    final out = InnerTubeMusicApi.mergeRotatedCookies(
      jar,
      const ['SIDCC=c0; Domain=.youtube.com'],
      host: 'music.youtube.com',
    );
    expect(out, isNull);
  });

  test('adopts newly-issued Google rotation cookies absent from pasted jar', () {
    final out = InnerTubeMusicApi.mergeRotatedCookies(
      'SAPISID=s; LOGIN_INFO=li',
      const [
        '__Secure-1PSIDTS=new1; Domain=.youtube.com; Path=/; Secure',
        'TRACKER=ignore; Domain=.youtube.com',
      ],
      host: 'accounts.youtube.com',
    );
    expect(out, isNotNull);
    expect(out, contains('__Secure-1PSIDTS=new1'));
    expect(out, isNot(contains('TRACKER')));
  });

  test('checkAuth refreshes stale PSIDTS via RotateCookies before marking stale',
      () async {
    final store = SecureStore();
    await store.writeYtCookies(
      'SAPISID=s; __Secure-1PSIDTS=old1; LOGIN_INFO=li',
    );
    final dio = Dio();
    dio.httpClientAdapter = _RotateMockAdapter();
    final api = InnerTubeMusicApi(dio, store);
    await api.loadPersistedConnection();

    final ok = await api.checkAuth();
    expect(ok, isTrue);
    expect(api.authStale, isFalse);
    expect(api.connection.cookies, contains('__Secure-1PSIDTS=fresh1'));
    expect(await store.readYtCookies(), contains('__Secure-1PSIDTS=fresh1'));
  });
}

class _RotateMockAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final url = options.uri.toString();
    if (url.contains('RotateCookiesPage')) {
      return ResponseBody.fromString(
        "<script>init('987654321012345', 1)</script>",
        200,
        headers: {
          Headers.contentTypeHeader: ['text/html'],
        },
      );
    }
    if (url.contains('accounts.youtube.com/RotateCookies')) {
      return ResponseBody.fromString(
        '{}',
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
          'set-cookie': [
            '__Secure-1PSIDTS=fresh1; Domain=.youtube.com; Path=/; Secure',
          ],
        },
      );
    }
    if (url.endsWith('music.youtube.com/')) {
      return ResponseBody.fromString(
        '{"INNERTUBE_API_KEY":"k","INNERTUBE_CLIENT_VERSION":"1.20260101.00.00"}',
        200,
        headers: {
          Headers.contentTypeHeader: ['text/html'],
        },
      );
    }
    final cookie = options.headers['Cookie']?.toString() ?? '';
    final payload = _withLoggedIn(cookie.contains('fresh1') ? '1' : '0');
    return ResponseBody.fromString(
      jsonEncode(payload),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }
}

Map<String, dynamic> _withLoggedIn(String value, {bool contents = true}) => {
      'responseContext': {
        'serviceTrackingParams': [
          {
            'service': 'GFEEDBACK',
            'params': [
              {'key': 'logged_in', 'value': value},
            ],
          },
        ],
      },
      if (contents) 'contents': {'singleColumnBrowseResultsRenderer': {}},
    };

void signedOutDetection() {
  test('a normal-looking guest page is recognised as signed out', () {
    expect(InnerTubeMusicApi.looksSignedOut(_withLoggedIn('0')), isTrue);
  });

  test('logged_in=1 is trusted as signed in', () {
    expect(InnerTubeMusicApi.looksSignedOut(_withLoggedIn('1')), isFalse);
  });

  test('without the flag the old heuristics still apply', () {
    expect(InnerTubeMusicApi.looksSignedOut(const {}), isTrue);
    expect(
      InnerTubeMusicApi.looksSignedOut(const {'contents': {}}),
      isFalse,
    );
  });
}
