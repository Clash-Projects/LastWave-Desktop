import 'dart:async';
import 'dart:io';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/foundation.dart';

import 'yt_webview_guard.dart';

/// In-app YouTube Music sign-in via a visible system WebView.
///
/// Opens `music.youtube.com` in a real browser window where the user
/// signs in with Google normally. Polls the WebView cookie jar for
/// login markers (`LOGIN_INFO` + SAPISID family) and returns a Cookie
/// header string suitable for [InnerTubeMusicApi.connect].
///
/// Returns `null` when the user closes the window (cancelled), when no
/// usable system WebView exists, or on timeout.
class YtWebLogin {
  YtWebLogin._();

  static const _loginUrl = 'https://music.youtube.com/';
  static const _pollInterval = Duration(seconds: 2);
  static const _timeout = Duration(minutes: 10);

  static bool _inflight = false;

  /// One cached window, reused across logins and NEVER destroyed by
  /// us. Upstream `desktop_webview_window` 0.3.0 segfaults on Linux
  /// when a webview window is destroyed (use-after-free in its Gtk
  /// "destroy" handler + EGL-context teardown poisoning the host's
  /// next frame; coredumps 2026-09-21 PIDs 43393/45028/51987), so the
  /// flow hides the window instead of closing it. On Linux the hide,
  /// show, and X-button interception go through the native
  /// `lastwave/yt_webview` guard (`linux/runner/yt_webview_guard.cc`),
  /// so even the window's own × button is safe (it hides).
  static Webview? _cachedWindow;

  /// Runs the flow. Only one login window at a time; concurrent calls
  /// return `null` immediately.
  static Future<String?> signIn() async {
    if (_inflight) return null;
    _inflight = true;
    try {
      return await _run();
    } finally {
      _inflight = false;
    }
  }

  /// The cached window for out-of-flow uses (brand-channel watching).
  /// Null when never created or dropped after an X-close.
  static Webview? get cachedWindow => _cachedWindow;

  /// Ensure the window exists and is visible. Used by flows that drive
  /// the window themselves (channel watching).
  static Future<Webview?> ensureWindow() => _ensureWindow();

  /// Hide the window without destroying it.
  static Future<void> hideWindow() async {
    final w = _cachedWindow;
    if (w == null) return;
    if (Platform.isLinux) {
      await YtWebviewGuard.hide();
    } else {
      try {
        await w.setWebviewWindowVisibility(false);
      } catch (_) {}
    }
  }

  /// Read the active channel's delegation page ID from the page
  /// (`ytcfg.data_.DELEGATED_SESSION_ID`). Null on the main channel
  /// (primary identity — not a delegation), on non-YouTube pages, or
  /// on any failure. Only 15–25 digit values are accepted.
  static final RegExp _pageIdPattern = RegExp(r'^\d{15,25}$');

  static Future<String?> readDelegatedPageId(
      Webview webview) async {
    try {
      final raw = await webview
          .evaluateJavaScript(
              'window.ytcfg ? String(window.ytcfg.data_'
              '.DELEGATED_SESSION_ID ?? "") : ""')
          .timeout(const Duration(seconds: 8));
      var v = (raw ?? '').trim();
      // evaluateJavaScript returns JSON-encoded strings.
      if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
        v = v.substring(1, v.length - 1);
      }
      v = v.trim();
      if (v.isEmpty || v == 'null' || v == 'undefined') {
        return null;
      }
      final id = _pageIdPattern.hasMatch(v) ? v : null;
      if (kDebugMode) {
        debugPrint(
            'YtWebLogin: delegated pageId=${id == null ? 'main' : '${id.length} digits'}');
      }
      return id;
    } catch (_) {
      return null;
    }
  }

  /// Title must match kYtWindowTitle in linux/runner/yt_webview_guard.cc
  /// (ASCII-only: compared byte-wise in native code).
  static const _windowTitle = 'LastWave YouTube Sign In';

  static Future<Webview?> _ensureWindow() async {
    final cached = _cachedWindow;
    if (cached != null) {
      // Linux: native guard (the plugin visibility call is a no-op
      // there). Elsewhere: the plugin call.
      if (Platform.isLinux) {
        if (await YtWebviewGuard.show()) return cached;
      } else {
        try {
          await cached.setWebviewWindowVisibility(true);
          try {
            await cached.bringToForeground();
          } catch (_) {}
          return cached;
        } catch (_) {}
      }
      // Cached window is gone — create fresh below.
      _cachedWindow = null;
    }
    try {
      if (!await WebviewWindow.isWebviewAvailable()) return null;
    } catch (_) {
      return null;
    }
    try {
      final w = await WebviewWindow.create(
        configuration: CreateConfiguration(
          title: _windowTitle,
          titleBarHeight: 40,
          windowWidth: 480,
          windowHeight: 760,
        ),
      );
      _cachedWindow = w;
      // If the window ever really dies, drop the cache so the next
      // sign-in creates a fresh window instead of talking to a dead one.
      unawaited(w.onClose.then((_) {
        if (identical(_cachedWindow, w)) _cachedWindow = null;
      }));
      if (Platform.isLinux) {
        // Ensure it is visible (create shows it; harmless if so).
        await YtWebviewGuard.show();
      }
      return w;
    } catch (_) {
      // No usable system WebView (missing webkit2gtk/WebView2/etc).
      return null;
    }
  }

  /// Page ID captured alongside the last successful sign-in (null =
  /// main channel). Read after [signIn]/[signInFresh] return non-null.
  static String? lastCapturedPageId;

  /// Clean-room login for adding another Google account: signs the jar
  /// out in place (no window destroy — `clearAll` would close windows
  /// into the upstream destroy bug), then runs the normal capture.
  static const _logoutUrl = 'https://accounts.google.com/Logout';

  static Future<String?> signInFresh() async {
    final w = await _ensureWindow();
    if (w == null) return null;
    try {
      w.launch(_logoutUrl);
      // Let the logout round-trip land before the login page loads.
      await Future<void>.delayed(const Duration(seconds: 4));
    } catch (_) {}
    return signIn();
  }

  /// Wait for a logged-in session in an already-driven window (used
  /// by flows that navigate the window themselves). Null on timeout
  /// or window close.
  static Future<String?> waitForLoginSession(
    Webview webview, {
    Duration timeout = _timeout,
  }) async {
    try {
      return await _waitForLogin(webview).timeout(
        timeout,
        onTimeout: () => null,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _run() async {
    final w = await _ensureWindow();
    if (w == null) return null;
    try {
      w.launch(_loginUrl);
      if (kDebugMode) {
        debugPrint('YtWebLogin: window launched');
      }
      final header = await _waitForLogin(w).timeout(
        _timeout,
        onTimeout: () => null,
      );
      // Capture the active channel alongside the jar (null = main).
      // Best-effort: a miss just means main-channel routing.
      lastCapturedPageId = null;
      if (header != null) {
        lastCapturedPageId = await readDelegatedPageId(w);
      }
      return header;
    } catch (_) {
      return null;
    } finally {
      // Hide, never destroy (see _cachedWindow note above). Linux goes
      // through the native guard; elsewhere the plugin call.
      if (Platform.isLinux) {
        await YtWebviewGuard.hide();
      } else {
        try {
          await w.setWebviewWindowVisibility(false);
        } catch (_) {}
      }
      if (kDebugMode) {
        debugPrint('YtWebLogin: window hidden');
      }
    }
  }

  /// Polls the cookie jar until login markers appear or the user
  /// closes the window. Single in-flight read per cycle: the native
  /// reader runs on the GTK thread, so a second overlapping read
  /// (or a read landing after destroy) risks a use-after-free.
  static Future<String?> _waitForLogin(Webview webview) async {
    // Give the page a moment to load before the first read.
    await Future<void>.delayed(const Duration(seconds: 4));
    var closed = false;
    unawaited(webview.onClose.then((_) => closed = true));
    while (!closed) {
      final header = await _readHeader(webview);
      if (header != null) return header;
      if (closed) return null;
      await Future<void>.delayed(_pollInterval);
    }
    return null;
  }

  /// Returns a Cookie header once login markers are present, else null.
  ///
  /// (Untyped locals: `WebviewCookie` lives in the package's
  /// `src/cookie.dart` which the barrel file doesn't export, so the
  /// type is inferred from `getAllCookies()` instead of named.)
  static Future<String?> _readHeader(Webview webview) async {
    late final List cookies;
    try {
      cookies = await webview
          .getAllCookies()
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      return null;
    }
    String? pick(String name) {
      for (final c in cookies) {
        if (c.name == name && c.value.isNotEmpty) return c.value;
      }
      return null;
    }

    final hasSapisid = pick('__Secure-3PAPISID') != null ||
        pick('SAPISID') != null;
    final loggedIn = pick('LOGIN_INFO') != null;
    if (!hasSapisid || !loggedIn) return null;

    // Jar may hold cookies from other Google properties; keep only
    // YouTube/Google session cookies for the header.
    final pairs = <String, String>{};
    for (final c in cookies) {
      final domain = c.domain.toLowerCase();
      if (!domain.contains('youtube.com') &&
          !domain.contains('google.com')) {
        continue;
      }
      if (c.name.isEmpty || c.value.isEmpty) continue;
      pairs[c.name] = c.value;
    }
    if (pairs.isEmpty) return null;
    final names = pairs.keys.toList()..sort();
    final header =
        names.map((n) => '$n=${pairs[n]}').join('; ');
    if (kDebugMode) {
      debugPrint(
          'YtWebLogin captured ${pairs.length} cookies');
    }
    return header;
  }
}
