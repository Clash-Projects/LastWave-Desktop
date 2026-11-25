import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:synchronized/synchronized.dart';

import '../../core/network/dio_factory.dart';
import 'challenge_parser.dart';
import 'webview_profile.dart';
import 'yt_auth_store.dart';
import 'yt_webview_guard.dart';

class EphemeralTokenResult {
  final String playerToken;
  final String sessionToken;
  final DateTime expiresAt;

  const EphemeralTokenResult({
    required this.playerToken,
    required this.sessionToken,
    required this.expiresAt,
  });
}

/// Ephemeral broker for system WebView2 / WebKit operations.
///
/// Unlike persistent session keepers that hold 6-12 `msedgewebview2.exe` processes
/// alive eating ~180-268 MB of RAM, this broker:
/// 1. Only opens on explicit triggers (login, expired token, or 403 recovery).
/// 2. Enforces a single-flight Completer lock to prevent parallel WebView instances.
/// 3. Executes the BotGuard handshake in an off-screen burst.
/// 4. Disposes the WebView within 500ms of capture, returning idle RAM to 0 MB.
/// 5. Attaches a 15-second watchdog timeout that unconditionally tears down the window.
class EphemeralWebViewBroker {
  static const _createUrl = 'https://www.youtube.com/api/jnn/v1/Create';
  static const _generateItUrl = 'https://www.youtube.com/api/jnn/v1/GenerateIT';
  static const _requestKey = 'O43z0dpjhgX20SCx4KAo';
  static const Duration _watchdogTimeout = Duration(seconds: 15);

  final Dio _dio;
  final YtAuthStore? authStore;
  final Lock _lock = Lock();
  Completer<EphemeralTokenResult?>? _inflightCompleter;
  Webview? _activeWebview;
  // On Linux, desktop_webview_window 0.3.0 segfaults on close(), so we hide
  // and reuse a single persistent Webview instance for the process lifetime.
  Webview? _linuxWebview;
  final Set<String> _failedTracks = {};

  bool enabled = true;

  EphemeralWebViewBroker({Dio? dio, this.authStore})
      : _dio = dio ?? DioFactory.create();

  /// Single-flight BotGuard token minting burst with immediate teardown.
  Future<EphemeralTokenResult?> mintToken(
    String videoId, {
    String sessionId = 'lastwave_session',
    bool forceRefresh = false,
  }) async {
    if (!enabled) return null;

    // Check store first for non-stale cached token
    if (!forceRefresh && authStore != null) {
      final current = authStore!.current;
      if (!current.isPoTokenStale && current.poToken.isNotEmpty) {
        return EphemeralTokenResult(
          playerToken: current.poToken,
          sessionToken: current.poToken,
          expiresAt: current.poTokenExpiresAt ?? DateTime.now().add(const Duration(hours: 1)),
        );
      }
    }

    // Max-1-retry guard per track to prevent infinite loops on hard blocks
    if (_failedTracks.contains(videoId) && !forceRefresh) {
      return null;
    }

    // Single-flight lock: coalesce concurrent callers
    return _lock.synchronized(() async {
      if (_inflightCompleter != null) {
        return _inflightCompleter!.future;
      }

      final completer = Completer<EphemeralTokenResult?>();
      _inflightCompleter = completer;
      var cancelled = false;

      try {
        final result = await _runEphemeralBurst(
          videoId,
          sessionId,
          isCancelled: () => cancelled,
        ).timeout(_watchdogTimeout, onTimeout: () {
          cancelled = true;
          debugPrint('EphemeralWebViewBroker: Watchdog timeout (15s) triggered');
          final stuck = _activeWebview;
          _activeWebview = null;
          _teardown(stuck, immediate: true);
          return null;
        });

        if (result != null) {
          _failedTracks.remove(videoId);
          if (authStore != null) {
            await authStore!.updatePoToken(
              poToken: result.playerToken,
              expiresAt: result.expiresAt,
            );
          }
        } else {
          _failedTracks.add(videoId);
        }

        completer.complete(result);
        return result;
      } catch (e) {
        debugPrint('EphemeralWebViewBroker mint error: $e');
        _failedTracks.add(videoId);
        completer.complete(null);
        return null;
      } finally {
        _inflightCompleter = null;
      }
    });
  }

  Future<(Directory, String)?> _writeTempBotGuardHtml(
    bool Function() isCancelled,
  ) async {
    final html = await rootBundle.loadString('assets/po_token.html');
    if (isCancelled()) return null;
    final patched = html.replaceFirst(
      '</script>',
      '\nwindow.__bgLoaded=true;</script>',
    );
    final dir = await Directory.systemTemp.createTemp('lastwave_bg_ephemeral');
    final file = File(
      '${dir.path}${Platform.pathSeparator}po_token.html',
    );
    await file.writeAsString(patched);
    if (isCancelled()) {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
      return null;
    }
    return (dir, Uri.file(file.path).toString());
  }

  /// Executes BotGuard handshake in an isolated, short-lived WebView2 window.
  Future<EphemeralTokenResult?> _runEphemeralBurst(
    String videoId,
    String sessionId, {
    required bool Function() isCancelled,
  }) async {
    Webview? webview;
    Directory? tempDir;
    try {
      if (Platform.isLinux && _linuxWebview != null) {
        webview = _linuxWebview;
        _activeWebview = webview;
        await YtWebviewGuard.hideBotGuard();
        final alreadyLoaded =
            (await _eval(webview, 'window.__bgLoaded')) == 'true';
        if (!alreadyLoaded) {
          final written = await _writeTempBotGuardHtml(isCancelled);
          if (written == null) return null;
          tempDir = written.$1;
          webview!.launch(written.$2);
          await YtWebviewGuard.hideBotGuard();
          final loaded = await _poll(
            () async => (await _eval(webview, 'window.__bgLoaded')) == 'true',
            timeout: const Duration(seconds: 5),
          );
          await YtWebviewGuard.hideBotGuard();
          if (!loaded) throw StateError('Ephemeral bg page failed to load');
        }
      } else {
        final written = await _writeTempBotGuardHtml(isCancelled);
        if (written == null) return null;
        tempDir = written.$1;
        final uri = written.$2;

        final profileFolder = await webviewUserDataFolder('botguard');
        if (isCancelled()) return null;
        webview = await WebviewWindow.create(
          configuration: CreateConfiguration(
            title: 'LastWave BotGuard',
            titleBarHeight: 0,
            windowWidth: 2,
            windowHeight: 2,
            windowPosX: -32000,
            windowPosY: -32000,
            useWindowPositionAndSize: true,
            userDataFolderWindows: profileFolder.isEmpty
                ? 'webview_window_WebView2'
                : profileFolder,
          ),
        );
        if (Platform.isLinux) {
          _linuxWebview = webview;
        }
        if (isCancelled()) return null;
        _activeWebview = webview;

        if (Platform.isLinux || Platform.isWindows) {
          await YtWebviewGuard.hideBotGuard();
        }
        try {
          await webview.setWebviewWindowVisibility(false);
        } catch (_) {}

        webview.launch(uri);
        if (Platform.isLinux || Platform.isWindows) {
          await YtWebviewGuard.hideBotGuard();
        }

        // 1. Wait for HTML page load
        final loaded = await _poll(
          () async => (await _eval(webview, 'window.__bgLoaded')) == 'true',
          timeout: const Duration(seconds: 5),
        );
        if (Platform.isLinux) {
          await YtWebviewGuard.hideBotGuard();
        }
        if (!loaded) throw StateError('Ephemeral bg page failed to load');
      }

      // 2. Fetch challenge
      final challengeJson = await _postJson(_createUrl, [_requestKey]);
      final challenge = parseCreateChallenge(challengeJson);

      // 3. runBotGuard in-page
      await _eval(
        webview,
        'window.__bgOut=null;window.__bgErr=null;'
        'try{var data=$challenge;'
        'runBotGuard(data).then(function(r){'
        'window.__bgW=r.webPoSignalOutput;'
        'window.__bgB=(typeof r.botguardResponse==="string")'
        '?r.botguardResponse:JSON.stringify(r.botguardResponse);'
        '},function(e){window.__bgErr=String((e&&e.stack)||e);});'
        '}catch(e){window.__bgErr=String((e&&e.stack)||e);}',
      );

      final botguardResponse = await _pollString(
        webview,
        'window.__bgB',
        'window.__bgErr',
        timeout: const Duration(seconds: 5),
      );
      if (botguardResponse == null) throw StateError('runBotGuard failed');

      // 4. GenerateIT
      final safeResponse = botguardResponse.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
      final integrity = await _postJson(_generateItUrl, [_requestKey, safeResponse]);
      final (tokenU8, lifetimeSec) = parseIntegrityToken(integrity);
      final expiresAt = DateTime.now().add(
        Duration(seconds: (lifetimeSec - 300).clamp(60, 1 << 30)),
      );

      // 5. createPoTokenMinter
      await _eval(
        webview,
        'window.__bgM=0;window.__bgErr=null;'
        'try{createPoTokenMinter(window.__bgW,$tokenU8)'
        '.then(function(){window.__bgM=1;},'
        'function(e){window.__bgErr=String((e&&e.stack)||e);});'
        '}catch(e){window.__bgErr=String((e&&e.stack)||e);}',
      );

      final minterOk = await _poll(
        () async => (await _eval(webview, 'window.__bgM')) == '1',
        timeout: const Duration(seconds: 5),
      );
      if (!minterOk) throw StateError('minter failed to initialize');

      // 6. Mint session token & video player token
      final sessionToken = await _mint(webview, sessionId);
      final playerToken = await _mint(webview, videoId);

      if (playerToken == null || sessionToken == null) {
        throw StateError('Failed to mint poToken');
      }

      return EphemeralTokenResult(
        playerToken: playerToken,
        sessionToken: sessionToken,
        expiresAt: expiresAt,
      );
    } finally {
      // Hard teardown: destroy WebView2 so no window or msedgewebview2.exe lingers.
      if (identical(_activeWebview, webview)) {
        _activeWebview = null;
      }
      _teardown(webview, immediate: true);
      if (tempDir != null) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
  }

  void _teardown(Webview? w, {bool immediate = false}) {
    if (w == null) return;
    void closeNow() {
      try {
        if (Platform.isLinux) {
          YtWebviewGuard.hideBotGuard();
        } else {
          if (Platform.isWindows) {
            YtWebviewGuard.hideBotGuard();
          }
          w.close();
        }
      } catch (_) {}
    }

    if (immediate) {
      closeNow();
    } else {
      Future.delayed(const Duration(milliseconds: 150), closeNow);
    }
  }

  Future<String?> _mint(Webview? w, String identifier) async {
    if (w == null) return null;
    final u8 = stringToJsUint8Array(identifier);
    await _eval(
      w,
      'window.__bgMint=null;window.__bgErr=null;'
      'try{obtainPoToken($u8)'
      '.then(function(u){window.__bgMint=Array.from(u).join(",");},'
      'function(e){window.__bgErr=String((e&&e.stack)||e);});'
      '}catch(e){window.__bgErr=String((e&&e.stack)||e);}',
    );

    final csv = await _pollString(
      w,
      'window.__bgMint',
      'window.__bgErr',
      timeout: const Duration(seconds: 5),
    );
    if (csv == null || csv.isEmpty) return null;
    try {
      return commaSeparatedBytesToBase64(csv);
    } catch (_) {
      return null;
    }
  }

  Future<String> _postJson(String url, List<String> body) async {
    final res = await _dio.post<String>(
      url,
      data: jsonEncode(body),
      options: Options(
        headers: {'Content-Type': 'application/json'},
        responseType: ResponseType.plain,
      ),
    ).timeout(const Duration(seconds: 10));
    final text = res.data ?? '';
    if (text.isEmpty) throw StateError('empty $url');
    return text;
  }

  Future<String?> _eval(Webview? w, String js) async {
    if (w == null) return null;
    try {
      final v = await w.evaluateJavaScript(js);
      if (v == null) return null;
      var s = v.trim();
      if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
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

  Future<bool> _poll(
    Future<bool> Function() check, {
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        if (await check()) return true;
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return false;
  }

  Future<String?> _pollString(
    Webview? w,
    String resultExpr,
    String errorExpr, {
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final err = await _eval(w, errorExpr);
      if (err != null && err.isNotEmpty && err != 'null') return null;
      final val = await _eval(w, resultExpr);
      if (val != null && val.isNotEmpty && val != 'null') return val;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return null;
  }
}
