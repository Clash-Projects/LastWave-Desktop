import 'dart:async';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/foundation.dart';

import '../innertube/yt_web_login.dart';

/// Why the last [SpotifyWebLogin.signIn] produced no cookie.
enum SpotifySignInFailure { none, unavailable, windowClosed, timeout }

/// In-app Spotify sign-in via the system WebView (login route #1; the
/// pasted `sp_dc` cookie is route #2).
///
/// Port of LastWave-Native `SpotifyLoginScreen`. `sp_dc` is issued by
/// Spotify's *authentication* response, so it only counts once the window
/// has left the anonymous pages (login / sign-up / reset): reading it on
/// the login page would capture a guest session that can never produce a
/// personal token. The captured value is verified by
/// `SpotifyAuth.connectWithSpDc` before anything reports success.
///
/// The window is the one shared, never-destroyed sign-in window owned by
/// [YtWebLogin] (upstream `desktop_webview_window` crashes on Linux when
/// a second window is destroyed), so this only navigates and hides it.
class SpotifyWebLogin {
  SpotifyWebLogin._();

  /// Bare localized login entry point: with a `continue` parameter Spotify
  /// sends the browser to the web player instead of the accounts status
  /// page, and the cookie is never read where it is issued.
  static const loginUrl = 'https://accounts.spotify.com/en/login';

  static const _poll = Duration(seconds: 2);
  static const _timeout = Duration(minutes: 10);

  static bool _inflight = false;
  static SpotifySignInFailure lastFailure = SpotifySignInFailure.none;

  static final _status = RegExp(
    r'^https://accounts\.spotify\.com/(?:[^/]+/)?status(?:\?.*)?$',
  );
  static final _anonymous = RegExp(
    r'^https://accounts\.spotify\.com/(?:[^/]+/)?'
    r'(?:login|signup|sign-up|reset-password|password-reset)(?:[/?#].*)?$',
  );

  /// True for a page that can only be reached once the sign-in finished.
  @visibleForTesting
  static bool isPostAuth(String? url) {
    if (url == null || url.isEmpty) return false;
    if (_status.hasMatch(url)) return true;
    if (!url.startsWith('https://accounts.spotify.com/')) {
      return url.startsWith('https://open.spotify.com/');
    }
    return !_anonymous.hasMatch(url);
  }

  /// Opens the sign-in window and resolves with the `sp_dc` value, or
  /// null when cancelled / unavailable / timed out ([lastFailure] says
  /// which). One flow at a time.
  static Future<String?> signIn() async {
    if (_inflight) return null;
    _inflight = true;
    lastFailure = SpotifySignInFailure.none;
    Webview? window;
    try {
      window = await YtWebLogin.ensureWindow();
      if (window == null) {
        lastFailure = SpotifySignInFailure.unavailable;
        return null;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      window.launch(loginUrl, triggerOnUrlRequestEvent: false);
      return await _wait(window).timeout(
        _timeout,
        onTimeout: () {
          lastFailure = SpotifySignInFailure.timeout;
          return null;
        },
      );
    } catch (_) {
      lastFailure = SpotifySignInFailure.unavailable;
      return null;
    } finally {
      _inflight = false;
      await YtWebLogin.hideWindow();
    }
  }

  static Future<String?> _wait(Webview window) async {
    await Future<void>.delayed(const Duration(seconds: 3));
    var closed = false;
    unawaited(window.onClose.then((_) => closed = true));
    while (!closed) {
      final url = await _url(window);
      final cookie = await _spDc(window);
      if (cookie != null && isPostAuth(url)) return cookie;
      await Future<void>.delayed(_poll);
    }
    lastFailure = SpotifySignInFailure.windowClosed;
    return null;
  }

  static Future<String?> _url(Webview window) async {
    try {
      final raw = await window
          .evaluateJavaScript('window.location.href')
          .timeout(const Duration(seconds: 4));
      if (raw == null) return null;
      var v = raw.trim();
      if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
        v = v.substring(1, v.length - 1);
      }
      return v;
    } catch (_) {
      return null;
    }
  }

  /// `sp_dc` out of the jar. WebView2 appends a trailing NUL to cookie
  /// names/values, which silently breaks exact matching — strip it.
  static Future<String?> _spDc(Webview window) async {
    try {
      final jar = await window.getAllCookies().timeout(
        const Duration(seconds: 5),
      );
      for (final c in jar) {
        final name = _strip(c.name.toString());
        final domain = _strip(c.domain.toString()).toLowerCase();
        if (name == 'sp_dc' && domain.contains('spotify.com')) {
          final value = _strip(c.value.toString());
          if (value.isNotEmpty) return value;
        }
      }
    } catch (_) {}
    return null;
  }

  static String _strip(String s) {
    var v = s;
    while (v.endsWith('\x00')) {
      v = v.substring(0, v.length - 1);
    }
    return v.trim();
  }
}
