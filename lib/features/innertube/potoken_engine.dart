import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:synchronized/synchronized.dart';

import '../../core/network/dio_factory.dart';
import 'challenge_parser.dart';
import 'yt_webview_guard.dart';

class PoTokenResult {
  final String playerToken;
  final String sessionToken;
  const PoTokenResult({
    required this.playerToken,
    required this.sessionToken,
  });
}

/// Desktop BotGuard poToken engine.
///
/// Faithful port of LastWave-native `BotGuardTokenGenerator`:
/// same endpoints, request key, challenge flow, caching (200
/// player tokens, session token, lifetime-300s expiry), cold/warm
/// timeouts and fail-open nulls. Only the host differs — a hidden
/// system WebView instead of Android WebView — driven through a
/// polling bridge (no message channels needed).
///
/// Lifetime: ONE persistent hidden WebView per app run, never destroyed
/// and recreated per song. Linux `desktop_webview_window` 0.3.0
/// segfaults on every webview destroy and implements no hide/move API,
/// so on Linux the window is hidden via the native `lastwave/yt_webview`
/// guard and reused; `close()` is never called there. On Windows the
/// same reuse avoids the per-song popup + taskbar flash + 9s stall.
class PoTokenEngine {
  static const _createUrl =
      'https://www.youtube.com/api/jnn/v1/Create';
  static const _generateItUrl =
      'https://www.youtube.com/api/jnn/v1/GenerateIT';
  static const _requestKey = 'O43z0dpjhgX20SCx4KAo';

  static const Duration _coldTimeout = Duration(seconds: 10);
  static const Duration _warmTimeout = Duration(seconds: 3);

  final Dio _dio;
  final Lock _mutex = Lock();
  // Serializes in-page mints: the hidden WebView shares
  // window.__bgMint/__bgErr vars, so concurrent mints would clobber
  // each other. One persistent WebView, one mint at a time.
  final Lock _mintLock = Lock();
  final Map<String, Future<PoTokenResult?>> _mintInflight = {};

  Webview? _webview;
  String? _engineSessionId;
  String? _cachedSessionToken;
  DateTime? _expiresAt;
  bool _ready = false;
  bool _permanentlyBroken = false;
  final Map<String, String> _playerCache = {};

  /// Kill-switch (Settings → direct-only mode). When false, no WebView
  /// is ever created and every mint returns null (fail-open to direct
  /// clients).
  bool enabled = true;

  /// Fail-open backoff: after an engine-init failure, don't recreate the
  /// window on every song — return null until this passes.
  DateTime? _coolingUntil;

  PoTokenEngine([Dio? dio])
      : _dio = dio ?? DioFactory.create();

  Future<void> preWarm(
      {String sessionId = 'lastwave_session'}) async {
    if (!enabled || _permanentlyBroken || sessionId.isEmpty) return;
    // Reuse the single hidden WebView when tokens are still valid —
    // never recreate a warm engine just to pre-warm.
    final warm = await _mutex.synchronized(() async =>
        _ready &&
        _engineSessionId == sessionId &&
        _cachedSessionToken != null &&
        _expiresAt != null &&
        DateTime.now().isBefore(_expiresAt!));
    if (warm) return;
    try {
      await _ensureEngine(sessionId)
          .timeout(_coldTimeout);
    } catch (_) {}
  }

  Future<PoTokenResult?> mintToken(
    String videoId, {
    String sessionId = 'lastwave_session',
  }) async {
    if (!enabled || _permanentlyBroken) return null;
    if (videoId.isEmpty) return null;
    final ready = await _mutex.synchronized(() async =>
        _ready &&
        _engineSessionId == sessionId &&
        _cachedSessionToken != null &&
        _expiresAt != null &&
        DateTime.now().isBefore(_expiresAt!));
    if (ready) {
      final cachedPlayer = _playerCache[videoId];
      final sessionToken = _cachedSessionToken;
      if (cachedPlayer != null && sessionToken != null) {
        return PoTokenResult(
            playerToken: cachedPlayer,
            sessionToken: sessionToken);
      }
    }
    // Prevent duplicate resolver requests for the same videoId.
    final inflightKey = '$sessionId|$videoId';
    final existing = _mintInflight[inflightKey];
    if (existing != null) {
      try {
        return await existing.timeout(
            ready ? _warmTimeout : _coldTimeout);
      } catch (_) {
        return null;
      }
    }
    final timeout =
        ready ? _warmTimeout : _coldTimeout;
    final future = _mintLock.synchronized(() => _mintInternal(
        videoId, sessionId,
        forceNewEngine: false));
    _mintInflight[inflightKey] = future;
    try {
      final result = await future.timeout(timeout);
      if (result != null) {
        await _mutex.synchronized(() async {
          if (_playerCache.length >= 200) {
            _playerCache
                .remove(_playerCache.keys.first);
          }
          _playerCache[videoId] = result.playerToken;
        });
      }
      return result;
    } catch (_) {
      return null;
    } finally {
      _mintInflight.remove(inflightKey);
    }
  }

  Future<PoTokenResult?> _mintInternal(
    String videoId,
    String sessionId, {
    required bool forceNewEngine,
  }) async {
    // Single pass, fail-open. A per-video or session miss must NOT
    // destroy/recreate the window (that destroy+recreate overlap is what
    // flashed two BotGuard windows per song, and on Linux close() = SEGV).
    // Direct clients don't need poTokens anyway; WEB_REMIX proceeds
    // without one.
    final sessionToken =
        await _ensureEngine(sessionId, force: forceNewEngine);
    if (sessionToken == null) return null;
    try {
      final playerToken = await _mint(videoId);
      if (playerToken == null) return null;
      return PoTokenResult(
          playerToken: playerToken,
          sessionToken: sessionToken);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _ensureEngine(String sessionId,
      {bool force = false}) async {
    return _mutex.synchronized(() async {
      final usable = !force &&
          _ready &&
          _engineSessionId == sessionId &&
          _cachedSessionToken != null &&
          _expiresAt != null &&
          DateTime.now().isBefore(_expiresAt!);
      if (usable) return _cachedSessionToken;
      // Fail-open backoff: a recent init failure means the network or
      // page is down — don't spin up a new window per song.
      final cooling = _coolingUntil;
      if (!force &&
          cooling != null &&
          DateTime.now().isBefore(cooling)) {
        return null;
      }
      // Soft reset: drop tokens but KEEP the WebView alive and hidden.
      // Recreating the OS window per song is the popup/lag/crash.
      _ready = false;
      _engineSessionId = null;
      _cachedSessionToken = null;
      _expiresAt = null;
      try {
        await _ensureWebview();
        // Init the minter in the SAME persistent page (Create/GenerateIT),
        // then mint the session token with it. No window recreation.
        await _initMinter();
        final sessionToken = await _mint(sessionId);
        if (sessionToken == null) {
          throw StateError('session mint null');
        }
        _engineSessionId = sessionId;
        _cachedSessionToken = sessionToken;
        _ready = true;
        _coolingUntil = null;
        // Re-hide: init takes 10-30s (Create/GenerateIT) and on Linux
        // neither the plugin hide nor the first guard hide is guaranteed
        // to have landed before the GTK window mapped.
        await _hideWebview();
        return sessionToken;
      } catch (_) {
        // Keep the hidden window for the next attempt (don't close —
        // Linux close() segfaults), but back off before retrying.
        _ready = false;
        _engineSessionId = null;
        _cachedSessionToken = null;
        _expiresAt = null;
        _coolingUntil =
            DateTime.now().add(const Duration(seconds: 60));
        await _hideWebview();
        return null;
      }
    });
  }

  /// Hard close. Only ever called on dispose, and NEVER on Linux
  /// (upstream destroy use-after-free → SEGV). The OS reclaims the
  /// window on process exit anyway.
  Future<void> _closeWebviewLocked() async {
    final w = _webview;
    _webview = null;
    if (w == null) return;
    if (Platform.isLinux) {
      await _hideWebview();
      return;
    }
    try {
      w.close();
    } catch (_) {}
  }

  /// Creates the single persistent hidden WebView on first use, hides it
  /// immediately (plugin hide is a no-op on Linux — the native guard does
  /// the hide), and reuses it for app lifetime.
  Future<void> _ensureWebview() async {
    if (_webview != null) return;
    final html = await rootBundle.loadString(
        'assets/po_token.html');
    final patched = html.replaceFirst(
        '</script>', '\nwindow.__bgLoaded=true;</script>');
    final dir = await Directory.systemTemp
        .createTemp('lastwave_bg');
    final file = File(
        '${dir.path}${Platform.pathSeparator}po_token.html');
    await file.writeAsString(patched);
    Webview? webview;
    try {
      webview = await WebviewWindow.create(
        configuration: CreateConfiguration(
          title: 'LastWave BotGuard',
          titleBarHeight: 0,
          windowWidth: 2,
          windowHeight: 2,
          windowPosX: -32000,
          windowPosY: -32000,
          useWindowPositionAndSize: true,
        ),
      );
    } catch (_) {
      // No usable system WebView on this machine: never retry.
      _permanentlyBroken = true;
      rethrow;
    }
    _webview = webview;
    await _hideWebview();
    webview.launch(Uri.file(file.path).toString());
    final loaded = await _poll(
      () async {
        final v = await _eval('window.__bgLoaded');
        return v == 'true';
      },
      timeout: const Duration(seconds: 10),
    );
    if (!loaded) throw StateError('bg page not loaded');
    // The GTK window may have mapped after the pre-launch hide (the
    // plugin hide is a no-op on Linux) — hide again now that it exists.
    await _hideWebview();
  }

  /// Hides the BotGuard window without destroying it. The plugin hide
  /// call is a no-op on Linux, so the native guard does it there; the
  /// delete-event blocker it arms also converts the window's own X into
  /// a hide (upstream destroy segfaults).
  Future<void> _hideWebview() async {
    if (Platform.isLinux) {
      await YtWebviewGuard.hideBotGuard();
    }
    try {
      await _webview?.setWebviewWindowVisibility(false);
    } catch (_) {}
  }

  /// Runs the Create/GenerateIT handshake in the persistent page and
  /// (re)creates the in-page minter. Safe to re-run on session expiry
  /// or visitor rotation — no OS window is touched.
  Future<void> _initMinter() async {
    if (_webview == null) throw StateError('no webview');
    // POST Create (Dart side, like Android).
    final challengeJson = await _postJson(
      _createUrl,
      [_requestKey],
    );
    final challenge = parseCreateChallenge(challengeJson);
    // Stage A: runBotGuard in-page, keep live refs in window vars.
    await _eval(
        'window.__bgOut=null;window.__bgErr=null;'
        'try{var data=$challenge;'
        'runBotGuard(data).then(function(r){'
        'window.__bgW=r.webPoSignalOutput;'
        'window.__bgB=(typeof r.botguardResponse==="string")'
        '?r.botguardResponse:JSON.stringify(r.botguardResponse);'
        '},function(e){window.__bgErr=String((e&&e.stack)||e);});'
        '}catch(e){window.__bgErr=String((e&&e.stack)||e);}');
    final botguardResponse = await _pollString(
      'window.__bgB',
      'window.__bgErr',
      timeout: const Duration(seconds: 10),
    );
    if (botguardResponse == null) {
      throw StateError('runBotGuard failed');
    }
    // POST GenerateIT (Dart side).
    final safeResponse = botguardResponse
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"');
    final integrity = await _postJson(
      _generateItUrl,
      [_requestKey, safeResponse],
    );
    final (tokenU8, lifetimeSec) =
        parseIntegrityToken(integrity);
    _expiresAt = DateTime.now().add(
        Duration(seconds: (lifetimeSec - 300).clamp(60, 1 << 30)));
    // Stage B: create the minter in-page.
    await _eval(
        'window.__bgM=0;window.__bgErr=null;'
        'try{createPoTokenMinter(window.__bgW,$tokenU8)'
        '.then(function(){window.__bgM=1;},'
        'function(e){window.__bgErr=String((e&&e.stack)||e);});'
        '}catch(e){window.__bgErr=String((e&&e.stack)||e);}');
    final minterOk = await _poll(
      () async {
        final v = await _eval('window.__bgM');
        return v == '1';
      },
      timeout: const Duration(seconds: 10),
    );
    if (!minterOk) throw StateError('minter not ready');
  }

  /// Mint one poToken for [identifier] (videoId or session id).
  Future<String?> _mint(String identifier) async {
    final w = _webview;
    if (w == null) return null;
    final u8 = stringToJsUint8Array(identifier);
    await _eval(
        'window.__bgMint=null;window.__bgErr=null;'
        'try{obtainPoToken($u8)'
        '.then(function(u){window.__bgMint=Array.from(u).join(",");},'
        'function(e){window.__bgErr=String((e&&e.stack)||e);});'
        '}catch(e){window.__bgErr=String((e&&e.stack)||e);}');
    final csv = await _pollString(
      'window.__bgMint',
      'window.__bgErr',
      timeout: const Duration(seconds: 10),
    );
    if (csv == null || csv.isEmpty) return null;
    try {
      return commaSeparatedBytesToBase64(csv);
    } catch (_) {
      return null;
    }
  }

  Future<String> _postJson(
      String url, List<String> body) async {
    final res = await _dio.post<String>(
      url,
      data: jsonEncode(body),
      options: Options(
        headers: {'Content-Type': 'application/json'},
        responseType: ResponseType.plain,
      ),
    ).timeout(const Duration(seconds: 20));
    final text = res.data ?? '';
    if (text.isEmpty) throw StateError('empty $url');
    return text;
  }

  Future<String?> _eval(String js) async {
    try {
      final v = await _webview?.evaluateJavaScript(js);
      if (v == null) return null;
      var s = v.trim();
      if (s.length >= 2 &&
          s.startsWith('"') &&
          s.endsWith('"')) {
        try {
          final decoded = jsonDecode(s);
          if (decoded is String) return decoded;
        } catch (_) {}
      }
      return s;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _poll(Future<bool> Function() check,
      {required Duration timeout}) async {
    final deadline =
        DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        if (await check()) return true;
      } catch (_) {}
      await Future<void>.delayed(
          const Duration(milliseconds: 100));
    }
    return false;
  }

  /// Poll a result-or-error window-var pair. Returns result, or
  /// null on error/timeout.
  Future<String?> _pollString(
    String resultExpr,
    String errorExpr, {
    required Duration timeout,
  }) async {
    final deadline =
        DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final err = await _eval(errorExpr);
      if (err != null &&
          err.isNotEmpty &&
          err != 'null') {
        return null;
      }
      final value = await _eval(resultExpr);
      if (value != null &&
          value.isNotEmpty &&
          value != 'null') {
        return value;
      }
      await Future<void>.delayed(
          const Duration(milliseconds: 100));
    }
    return null;
  }

  /// App-shutdown teardown. Never destroys the window on Linux (upstream
  /// destroy use-after-free → SEGV); the OS reclaims it on exit.
  Future<void> dispose() async {
    await _mutex.synchronized(() async {
      _ready = false;
      await _closeWebviewLocked();
    });
  }
}

final poTokenEngineProvider =
    Provider<PoTokenEngine>((_) => PoTokenEngine());
