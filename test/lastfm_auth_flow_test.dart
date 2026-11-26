import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/app/auth_gate.dart';
import 'package:lastwave_desktop/core/network/lastfm_api.dart';
import 'package:lastwave_desktop/core/network/rate_guard.dart';
import 'package:lastwave_desktop/core/storage/prefs.dart';
import 'package:lastwave_desktop/core/storage/secure_store.dart';
import 'package:lastwave_desktop/features/lastfm/auth_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StubLastFmAdapter implements HttpClientAdapter {
  _StubLastFmAdapter(this.handler);

  final ResponseBody Function(RequestOptions options) handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async =>
      handler(options);

  @override
  void close({bool force = false}) {}
}

ResponseBody _jsonBody(Map<String, dynamic> data, [int status = 200]) =>
    ResponseBody.fromString(
      jsonEncode(data),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Guest Last.fm OAuth handshake preserves gate and completes session',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await Prefs.load();
    await prefs.setGuestMode(true);

    final dio = Dio(BaseOptions(baseUrl: LastFmApiService.baseUrl));
    dio.httpClientAdapter = _StubLastFmAdapter((options) {
      final method = options.queryParameters['method'];
      if (method == 'auth.getToken') {
        return _jsonBody({'token': 'tok123'});
      }
      if (method == 'auth.getSession') {
        return _jsonBody({
          'session': {'key': 'sk_abc', 'name': 'alice'},
        });
      }
      return _jsonBody({'error': 1}, 400);
    });

    final repo = AuthRepository(
      LastFmApiService(dio, LastFmRateGuard()),
      prefs,
      SecureStore(),
    );
    expect(repo.state.status, AuthStatus.guest);

    final gate = AuthGate(initialInside: prefs.isAuthenticated || prefs.isGuest);
    addTearDown(gate.dispose);
    repo.addListener((next) {
      if (next.status == AuthStatus.signedIn || next.status == AuthStatus.guest) {
        gate.update(true);
      } else if (next.status == AuthStatus.signedOut) {
        gate.update(prefs.isGuest);
      }
    });

    await repo.saveCustomKeys('my_key', 'my_secret');
    expect(repo.state.status, AuthStatus.guest);
    expect(gate.signedIn, isTrue);

    final handshake = await repo.beginWebAuth();
    expect(handshake.token, 'tok123');
    expect(
      handshake.url,
      'https://www.last.fm/api/auth/?api_key=my_key&token=tok123',
    );
    expect(repo.state.status, AuthStatus.signingIn);
    expect(gate.signedIn, isTrue);

    await repo.completeWebAuth(handshake.token);
    expect(repo.state.status, AuthStatus.signedIn);
    expect(repo.state.username, 'alice');
    expect(gate.signedIn, isTrue);

    await repo.clearCustomKeys();
    expect(prefs.isLastFmConfigured, isFalse);
  });

  test('beginWebAuth transitions cleanly to error state on token fetch failure',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await Prefs.load();
    await prefs.setGuestMode(true);
    await prefs.saveLastFmKeys(apiKey: 'my_key', apiSecret: 'my_secret');

    final dio = Dio(BaseOptions(baseUrl: LastFmApiService.baseUrl));
    dio.httpClientAdapter = _StubLastFmAdapter(
      (_) => _jsonBody({'error': 10, 'message': 'Invalid API key'}),
    );

    final repo = AuthRepository(
      LastFmApiService(dio, LastFmRateGuard()),
      prefs,
      SecureStore(),
    );

    await expectLater(repo.beginWebAuth(), throwsA(isA<LastFmException>()));
    expect(repo.state.status, AuthStatus.error);
  });
}
