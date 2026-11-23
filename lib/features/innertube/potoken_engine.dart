import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/dio_factory.dart';
import '../../core/storage/secure_store.dart';
import 'ephemeral_webview_broker.dart';
import 'yt_auth_store.dart';

class PoTokenResult {
  final String playerToken;
  final String sessionToken;
  const PoTokenResult({
    required this.playerToken,
    required this.sessionToken,
  });
}

/// Desktop BotGuard poToken engine powered by [EphemeralWebViewBroker].
///
/// Cuts idle memory from ~180-268 MB to 0 MB:
/// - Startup does NOT spawn WebView2/WebKit (loads cached token from [YtAuthStore]).
/// - Ephemeral bursts run off-screen only on 403 / expired token / login.
/// - Hard teardown: WebView2 is destroyed within 500ms of token capture.
class PoTokenEngine {
  final EphemeralWebViewBroker _broker;
  final YtAuthStore? _authStore;

  bool get enabled => _broker.enabled;
  set enabled(bool val) => _broker.enabled = val;

  PoTokenEngine([Dio? dio, YtAuthStore? authStore])
      : _broker = EphemeralWebViewBroker(dio: dio, authStore: authStore),
        _authStore = authStore;

  /// Startup pre-warm: zero WebView spawn! Loads the persisted session bundle into memory.
  Future<void> preWarm({String sessionId = 'lastwave_session'}) async {
    if (_authStore != null) {
      await _authStore.load();
    }
  }

  /// Mints a fresh BotGuard token via ephemeral burst if needed, or returns cached token.
  Future<PoTokenResult?> mintToken(
    String videoId, {
    String sessionId = 'lastwave_session',
    bool forceRefresh = false,
  }) async {
    if (!enabled) return null;
    final res = await _broker.mintToken(
      videoId,
      sessionId: sessionId,
      forceRefresh: forceRefresh,
    );
    if (res == null) return null;
    return PoTokenResult(
      playerToken: res.playerToken,
      sessionToken: res.sessionToken,
    );
  }

  Future<void> dispose() async {
    // Ephemeral broker already tears down WebView after each burst!
  }
}

final ytAuthStoreProvider = Provider<YtAuthStore>((ref) {
  return YtAuthStore(ref.watch(secureStoreProvider));
});

final poTokenEngineProvider = Provider<PoTokenEngine>((ref) {
  final authStore = ref.watch(ytAuthStoreProvider);
  return PoTokenEngine(DioFactory.create(), authStore);
});
