import 'dart:async';
import 'dart:io';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/foundation.dart';

import 'webview_profile.dart';
import 'yt_webview_guard.dart';

/// Why the last [YtWebLogin.signIn] attempt produced no session.
///
/// The UI reads [YtWebLogin.lastFailure] to offer the right recovery
/// instead of a generic "no session was captured": Google refusing the
/// embedded browser (macOS `disallowed_useragent`) is not the same
/// problem as a blank WebView2 environment or a user who never
/// finished signing in.
enum YtSignInFailure {
  /// No failure — a session was captured.
  none,

  /// No usable system WebView (missing WebView2 / WebKitGTK).
  unavailable,

  /// The user closed the sign-in window.
  windowClosed,

  /// Poll timed out with no session (user never completed sign-in).
  timeout,

  /// The window kept sitting on about:blank / a network-error page.
  blankPage,

  /// Google refused to serve the sign-in page to this browser.
  browserBlocked,

  /// The jar never contained a complete session.
  noSession,
}

/// A cookie as read from the system WebView jar. Small value type so
/// the capture/merge logic stays unit-testable without a real window.
@immutable
class YtJarCookie {
  final String name;
  final String value;

  /// Cookie domain as reported by the WebView (`youtube.com`,
  /// `.youtube.com`, `accounts.google.com`, …). Empty when unknown.
  final String domain;

  const YtJarCookie({
    required this.name,
    required this.value,
    this.domain = '',
  });
}

/// In-app YouTube Music sign-in via a visible system WebView.
///
/// Opens `music.youtube.com` in a real browser window where the user
/// signs in with Google normally. Polls the WebView cookie jar for
/// login markers (SAPISID + PSID family) and returns a Cookie header
/// string suitable for [InnerTubeMusicApi.connectAs].
///
/// Capture is deliberately conservative: a candidate header is only
/// accepted once the page is settled on `music.youtube.com` AND two
/// consecutive jar reads produce the identical header, so a
/// mid-redirect jar (`accounts.google.com` sets the Google-scoped
/// cookies before YouTube mints its own) can never be persisted. A jar
/// without `__Secure-*PSIDTS`/`LOGIN_INFO` is rejected — that cookie is
/// what Google rotates on every request, and persisting a jar without
/// it is what made the app demand a fresh login every launch.
///
/// Returns `null` when the user closes the window (cancelled), when no
/// usable system WebView exists, when Google blocks the embedded
/// browser, or on timeout. [lastFailure] says which.
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

  /// Why the last flow returned nothing. Reset at the start of every
  /// [signIn]/[signInFresh] attempt.
  static YtSignInFailure lastFailure = YtSignInFailure.none;

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
    _expectVisible = false;
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

  /// Tracks whether the login window SHOULD be visible right now.
  /// Guards delayed foreground retries so they never re-show a
  /// window the flow already hid (hide, never destroy).
  static bool _expectVisible = false;

  /// Bring the login window above the main window. A single
  /// `bringToForeground()` often loses to Windows' foreground lock
  /// silently (window ends up flashing in the taskbar / behind the
  /// app — the "Add account opens in background" report), so the
  /// first attempt is awaited inline and two more are re-asserted
  /// shortly after. All guarded by [_expectVisible].
  static Future<void> _foreground(Webview w) async {
    _expectVisible = true;
    if (Platform.isLinux) {
      await YtWebviewGuard.show();
      return;
    }
    await _foregroundOnce(w);
    unawaited(_foregroundRetries(w));
  }

  static Future<void> _foregroundOnce(Webview w) async {
    if (!identical(_cachedWindow, w) || !_expectVisible) return;
    try {
      await w.setWebviewWindowVisibility(true);
    } catch (_) {}
    if (!identical(_cachedWindow, w) || !_expectVisible) return;
    try {
      await w.bringToForeground();
    } catch (_) {}
  }

  static Future<void> _foregroundRetries(Webview w) async {
    for (var i = 0; i < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (!identical(_cachedWindow, w) || !_expectVisible) return;
      await _foregroundOnce(w);
    }
  }

  /// Read the active channel's delegation page ID from the page
  /// (`ytcfg.data_.DELEGATED_SESSION_ID`). Null on the main channel
  /// (primary identity — not a delegation), on non-YouTube pages, or
  /// on any failure. Only 15–25 digit values are accepted.
  static final RegExp _pageIdPattern = RegExp(r'^\d{15,25}$');

  static Future<String?> readDelegatedPageId(Webview webview) async {
    try {
      final raw = await webview
          .evaluateJavaScript('window.ytcfg ? String(window.ytcfg.data_'
              '.DELEGATED_SESSION_ID ?? "") : ""')
          .timeout(const Duration(seconds: 8));
      var v = _unquote(raw) ?? '';
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

  /// Reload the login page in the cached window without destroying
  /// it. Used as a manual escape hatch (and by the passkey-stall
  /// auto-recovery below): the WebView2 user-data folder persists
  /// cookies, so a reload after Windows Hello completes lands the
  /// page signed-in and the cookie poller captures normally.
  static Future<void> reloadLoginPage() async {
    final w = _cachedWindow;
    if (w == null) return;
    try {
      w.launch(_loginUrl, triggerOnUrlRequestEvent: false);
    } catch (_) {}
    // The user just clicked Reload in the main window — pull the
    // login window back above it (fresh input ⇒ foreground succeeds).
    await _foreground(w);
    if (kDebugMode) {
      debugPrint('YtWebLogin: login page reloaded');
    }
  }

  /// Pure page-text matcher for the Google passkey stall:
  /// "Verifying that it's you..." + a passkey reference. Unit-tested;
  /// kept as a static so tests don't need a WebView.
  static bool isPasskeyVerificationStall(String pageText) {
    final t = pageText.toLowerCase();
    return t.contains('verifying') && t.contains('passkey');
  }

  /// Pure page-text matcher for Google's embedded-browser rejection.
  ///
  /// macOS WKWebView is served "Couldn't sign you in — This browser or
  /// app may not be secure. Try using a different browser." Google
  /// detects the embedded webview (no `window.chrome`, no
  /// `navigator.userAgentData`, Safari UA underneath). No amount of
  /// in-app retrying fixes that page — the only honest response is to
  /// stop early and hand the user the cookie-paste path.
  static bool isBrowserBlockedPage(String pageText) {
    final t = pageText.toLowerCase();
    if (t.contains('may not be secure')) return true;
    if (t.contains('disallowed_useragent')) return true;
    if (t.contains('this browser or app')) return true;
    if (t.contains('try using a different browser')) return true;
    // "Couldn't sign you in" only counts when it is the block page
    // (the apostrophe is either ASCII or the typographic variant).
    if (t.contains("couldn't sign you in") ||
        t.contains('couldn’t sign you in')) {
      return true;
    }
    return false;
  }

  /// Pure check for blank page URLs (about:blank, data:,, or empty).
  static bool isBlankUrl(String url) {
    final u = url.trim().toLowerCase();
    return u.isEmpty || u == 'about:blank' || u.startsWith('data:,');
  }

  /// Pure check for a failed-navigation URL. WebView2 (Chromium) parks
  /// failed loads on `chrome-error://chromewebdata/`, WKWebView on an
  /// empty/about:blank document — both mean the window never loaded a
  /// page and waiting the full 10-minute timeout is pointless.
  static bool isErrorUrl(String url) {
    final u = url.trim().toLowerCase();
    return u.startsWith('chrome-error:') ||
        u.startsWith('edge-error:') ||
        u.startsWith('webkit-error') ||
        u.contains('chromewebdata');
  }

  /// Best-effort read of the current page text. Null on any failure
  /// (non-YouTube pages, JS errors, closed window).
  static Future<String?> _pageText(Webview webview) async {
    try {
      final raw = await webview
          .evaluateJavaScript(
              'document.body ? document.body.innerText.slice(0, 1200) : ""')
          .timeout(const Duration(seconds: 4));
      return _unquote(raw);
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _currentUrl(Webview webview) async {
    try {
      final raw = await webview
          .evaluateJavaScript('window.location.href')
          .timeout(const Duration(seconds: 4));
      return _unquote(raw);
    } catch (_) {
      return null;
    }
  }

  /// `evaluateJavaScript` returns JSON-encoded strings on the native
  /// side; strip the surrounding quotes.
  static String? _unquote(String? raw) {
    if (raw == null) return null;
    var v = raw.trim();
    if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
      v = v.substring(1, v.length - 1);
    }
    return v;
  }

  /// True when the polled URL is a place we may accept a session from.
  /// Null (JS read failed) is accepted — the jar itself is the gate.
  static bool _isAcceptableHost(String? url) {
    if (url == null || url.trim().isEmpty) return true;
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    return host == 'music.youtube.com' || host == 'www.youtube.com';
  }

  /// Strict variant for the fast path: the SPA must have landed on
  /// YouTube Music itself, not on an intermediate Google page.
  static bool _isMusicHost(String? url) {
    if (url == null || url.trim().isEmpty) return false;
    return Uri.tryParse(url)?.host.toLowerCase() == 'music.youtube.com';
  }

  /// Title must match kYtWindowTitle in linux/runner/yt_webview_guard.cc
  /// (ASCII-only: compared byte-wise in native code).
  static const _windowTitle = 'LastWave YouTube Sign In';

  /// Appended to the system WebView's default UA before the first
  /// navigation. On macOS the plugin hosts a WKWebView whose default
  /// Safari UA (no `Chrome/` token) makes music.youtube.com render
  /// "not optimized for your browser". The native call sets
  /// `customUserAgent = defaultUA + suffix`, so the leading space
  /// matters. Called once per window creation; the cached window
  /// keeps it for reuse.
  static const _macChromeSuffix = ' Chrome/131.0.0.0 Safari/537.36';

  /// Document-start compatibility shim for macOS only.
  ///
  /// Google's `disallowed_useragent` block keys off the embedded
  /// browser fingerprint (WKWebView reports no `navigator.userAgentData`
  /// and no `window.chrome`). This shim presents a coherent desktop
  /// Chrome surface before any page script runs. It is a best-effort
  /// compatibility measure — Google can change the check at any time,
  /// and when it fails the flow fails FAST into the paste path instead
  /// of pretending the browser can be fixed.
  static const _macCompatShim = r'''
(function () {
  try {
    var ua = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
      + 'AppleWebKit/537.36 (KHTML, like Gecko) '
      + 'Chrome/131.0.0.0 Safari/537.36';
    Object.defineProperty(navigator, 'userAgent', { get: function () { return ua; } });
    if (!navigator.userAgentData) {
      var brands = [
        { brand: 'Chromium', version: '131' },
        { brand: 'Google Chrome', version: '131' },
        { brand: 'Not_A Brand', version: '24' }
      ];
      Object.defineProperty(navigator, 'userAgentData', {
        get: function () {
          return {
            brands: brands,
            mobile: false,
            platform: 'macOS',
            getHighEntropyValues: function () {
              return Promise.resolve({
                brands: brands,
                mobile: false,
                platform: 'macOS',
                platformVersion: '14.0.0',
                architecture: 'arm',
                bitness: '64',
                uaFullVersion: '131.0.0.0'
              });
            }
          };
        }
      });
    }
    if (!window.chrome) { window.chrome = { runtime: {} }; }
    Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
  } catch (e) {}
})();
''';

  /// Absolute WebView2 user-data folder for a window slot. See
  /// [webviewUserDataFolder] for why the plugin default is unusable.
  static Future<String> _userDataFolder(String slot) =>
      webviewUserDataFolder(slot);

  static Future<Webview?> _ensureWindow() async {
    final cached = _cachedWindow;
    if (cached != null) {
      // Linux: native guard (the plugin visibility call is a no-op
      // there). Elsewhere: the plugin call.
      if (Platform.isLinux) {
        if (await YtWebviewGuard.show()) return cached;
      } else {
        try {
          // Liveness probe: throws when the native window is gone,
          // falling through to fresh-create below.
          await cached.setWebviewWindowVisibility(true);
          await _foreground(cached);
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
      final folder = await _userDataFolder('auth');
      final w = await WebviewWindow.create(
        configuration: CreateConfiguration(
          title: _windowTitle,
          titleBarHeight: 40,
          windowWidth: 480,
          windowHeight: 760,
          userDataFolderWindows:
              folder.isEmpty ? 'webview_window_WebView2' : folder,
        ),
      );
      _cachedWindow = w;
      if (Platform.isMacOS) {
        try {
          w.addScriptToExecuteOnDocumentCreated(_macCompatShim);
        } catch (_) {}
        try {
          await w.setApplicationNameForUserAgent(_macChromeSuffix);
        } catch (_) {}
      }
      // If the window ever really dies, drop the cache so the next
      // sign-in creates a fresh window instead of talking to a dead one.
      unawaited(w.onClose.then((_) {
        if (identical(_cachedWindow, w)) _cachedWindow = null;
      }));
      if (Platform.isLinux) {
        // Ensure it is visible (create shows it; harmless if so).
        await YtWebviewGuard.show();
      } else {
        // A fresh window doesn't reliably activate above the main
        // window on its own — assert z-order explicitly.
        await _foreground(w);
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
    if (w == null) {
      lastFailure = YtSignInFailure.unavailable;
      return null;
    }
    try {
      // Same Windows gate bypass as _run (see comment there).
      w.launch(_logoutUrl, triggerOnUrlRequestEvent: false);
      // Show progress: the logout round-trip is the first visible
      // step of the add-account flow, and asserting z-order here
      // (not just after the later login launch) keeps the window
      // from settling behind the app during the 4s wait.
      await _foreground(w);
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
      final r = await _waitForLogin(webview).timeout(
        timeout,
        onTimeout: () => const _LoginResult(null, YtSignInFailure.timeout),
      );
      lastFailure = r.header == null
          ? (r.failure == YtSignInFailure.none
              ? YtSignInFailure.noSession
              : r.failure)
          : YtSignInFailure.none;
      return r.header;
    } catch (_) {
      lastFailure = YtSignInFailure.noSession;
      return null;
    }
  }

  /// Silently refresh the session in the cached (hidden) window.
  ///
  /// Only works when this process already created the sign-in window —
  /// i.e. within the same app run as a webview sign-in. That is
  /// deliberate: spawning a hidden WebView at startup would cost a
  /// WebView2 environment (and on Linux a GTK window) for every launch
  /// even when the session is healthy. With a cached window, reloading
  /// `music.youtube.com` lets Google re-mint the rotating
  /// `__Secure-*PSIDTS` cookies against the persisted jar, and the
  /// caller can replace the stored session without showing any UI.
  ///
  /// Returns a Cookie header, or null when there is no cached window,
  /// a login flow is already running, or nothing usable was captured.
  static Future<String?> refreshSilently({
    Duration timeout = const Duration(seconds: 75),
  }) async {
    final w = _cachedWindow;
    if (w == null || _inflight) return null;
    _inflight = true;
    try {
      _expectVisible = false;
      if (Platform.isLinux) {
        await YtWebviewGuard.hide();
      } else {
        try {
          await w.setWebviewWindowVisibility(false);
        } catch (_) {}
      }
      try {
        w.launch(_loginUrl, triggerOnUrlRequestEvent: false);
      } catch (_) {
        return null;
      }
      final r = await _waitForLogin(w, silent: true).timeout(
        timeout,
        onTimeout: () => const _LoginResult(null, YtSignInFailure.timeout),
      );
      if (kDebugMode) {
        debugPrint(
            'YtWebLogin: silent refresh ${r.header != null ? 'captured' : 'failed (${r.failure.name})'}');
      }
      return r.header;
    } catch (_) {
      return null;
    } finally {
      _inflight = false;
      _expectVisible = false;
    }
  }

  static Future<String?> _run() async {
    lastFailure = YtSignInFailure.none;
    final w = await _ensureWindow();
    if (w == null) {
      lastFailure = YtSignInFailure.unavailable;
      return null;
    }
    try {
      // Allow WebView host/controller a moment to attach before initiating navigation
      await Future<void>.delayed(const Duration(milliseconds: 300));
      // Windows: load directly without the navigation-approval round-trip.
      // With triggerOnUrlRequestEvent=true (the default) native WebView2
      // cancels the navigation and only re-issues it after a Dart
      // round-trip; if that silently fails the window sits on about:blank
      // forever.
      w.launch(_loginUrl, triggerOnUrlRequestEvent: false);
      // Re-assert z-order AFTER navigation starts: a single
      // pre-launch foreground is what left the window behind the app
      // when Windows' foreground lock swallowed the attempt.
      await _foreground(w);
      if (kDebugMode) {
        debugPrint('YtWebLogin: window launched');
      }
      final r = await _waitForLogin(w).timeout(
        _timeout,
        onTimeout: () => const _LoginResult(null, YtSignInFailure.timeout),
      );
      lastFailure = r.header == null
          ? (r.failure == YtSignInFailure.none
              ? YtSignInFailure.noSession
              : r.failure)
          : YtSignInFailure.none;
      // Capture the active channel alongside the jar (null = main).
      // Best-effort: a miss just means main-channel routing.
      lastCapturedPageId = null;
      if (r.header != null) {
        lastCapturedPageId = await readDelegatedPageId(w);
      }
      return r.header;
    } catch (_) {
      lastFailure = YtSignInFailure.noSession;
      return null;
    } finally {
      // Hide, never destroy (see _cachedWindow note above). Linux goes
      // through the native guard; elsewhere the plugin call.
      // Clears _expectVisible so in-flight foreground retries from
      // _foreground() never re-show the just-hidden window.
      _expectVisible = false;
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

  /// Polls the cookie jar until a settled login session appears, the
  /// page is provably unusable (blocked / blank), or the user closes
  /// the window. Single in-flight read per cycle: the native reader
  /// runs on the GTK thread, so a second overlapping read (or a read
  /// landing after destroy) risks a use-after-free.
  ///
  /// Windows passkey recovery: after Windows Hello completes, the
  /// embedded WebView2 sometimes leaves Google's "Verifying that it's
  /// you..." page stalled (the WebAuthn result never resumes the page
  /// JS). The session IS minted though — a reload lands signed-in —
  /// so when the stall text persists, the login page is reloaded
  /// in place (cookies survive) instead of polling forever.
  ///
  /// [silent] is used by [refreshSilently]: the window is intentionally
  /// hidden, so Linux visibility must not be read as "user closed it".
  static Future<_LoginResult> _waitForLogin(
    Webview webview, {
    bool silent = false,
  }) async {
    // Give the page a moment to load before the first read.
    await Future<void>.delayed(const Duration(seconds: 4));
    var closed = false;
    unawaited(webview.onClose.then((_) => closed = true));

    Future<bool> gone() async {
      if (closed) return true;
      if (silent) return false;
      if (Platform.isLinux && !await YtWebviewGuard.isVisible()) return true;
      return false;
    }

    var stuckCycles = 0;
    var autoReloads = 0;
    var blankCycles = 0;
    var blankReloads = 0;
    var baselineTaken = false;
    String? baseline;
    String? stableCandidate;

    while (!closed) {
      if (await gone()) {
        return const _LoginResult(null, YtSignInFailure.windowClosed);
      }

      // 1. Jar read (sequential — never overlap native cookie reads).
      final cookies = await _readCookies(webview);
      final header = cookies == null ? null : buildCookieHeader(cookies);
      if (!baselineTaken) {
        // What the jar held before the user touched anything. A
        // complete session that was already there (re-login over a
        // stale jar) must NOT satisfy the capture — only a jar that
        // CHANGED after sign-in proves the user just authenticated.
        baselineTaken = true;
        baseline = header;
      }
      final url = await _currentUrl(webview);

      if (await gone()) {
        return const _LoginResult(null, YtSignInFailure.windowClosed);
      }

      // 2. Failed/blank navigation: WebView2 on `chrome-error://` or
      //    stuck on about:blank never recovers on its own. Relaunch a
      //    few times, then give up instead of burning the timeout.
      final blank = url == null
          ? false
          : (isBlankUrl(url) || isErrorUrl(url));
      if (blank) {
        blankCycles++;
        if (blankCycles >= 2) {
          blankCycles = 0;
          blankReloads++;
          if (blankReloads > 3) {
            if (kDebugMode) {
              debugPrint('YtWebLogin: page never loaded (blank/error), giving up');
            }
            return const _LoginResult(null, YtSignInFailure.blankPage);
          }
          if (kDebugMode) {
            debugPrint(
                'YtWebLogin: $url — re-launching $_loginUrl ($blankReloads/3)');
          }
          try {
            webview.launch(_loginUrl, triggerOnUrlRequestEvent: false);
            await webview
                .evaluateJavaScript('window.location.href = "$_loginUrl";');
          } catch (_) {}
          if (!silent) {
            if (!await gone()) await _foreground(webview);
          }
          await Future<void>.delayed(const Duration(seconds: 3));
          continue;
        }
      } else {
        blankCycles = 0;
      }

      // 3. Page text is only needed while no session exists: it drives
      //    both the embedded-browser-rejection check and the passkey
      //    stall recovery. One read per cycle, reused below.
      String? text;
      if (header == null && !silent) {
        text = await _pageText(webview);
        final onGoogle = url == null || url.contains('google.com');
        if (onGoogle && text != null && isBrowserBlockedPage(text)) {
          if (kDebugMode) {
            debugPrint('YtWebLogin: Google blocked the embedded browser');
          }
          return const _LoginResult(null, YtSignInFailure.browserBlocked);
        }
        if (await gone()) {
          return const _LoginResult(null, YtSignInFailure.windowClosed);
        }
      }

      // 4. Accept only a SETTLED jar:
      //    - a header that CHANGED since the pre-flow baseline while the
      //      tab is on music.youtube.com is a fresh sign-in (fast path);
      //    - otherwise the same header must appear twice in a row,
      //      which proves the jar stopped changing.
      //    Mid-redirect jars (accounts.google.com sets Google-scoped
      //    cookies first) never pass buildCookieHeader's domain gate.
      if (header != null) {
        if (header != baseline && _isMusicHost(url)) {
          return _LoginResult(header, YtSignInFailure.none);
        }
        if (_isAcceptableHost(url)) {
          if (header == stableCandidate) {
            return _LoginResult(header, YtSignInFailure.none);
          }
          stableCandidate = header;
        } else {
          stableCandidate = null;
        }
      } else {
        stableCandidate = null;
      }

      // 5. Passkey stall recovery (~5 consecutive hits ≈ 10 s stuck).
      final stuck = text != null && isPasskeyVerificationStall(text);
      if (closed) {
        return const _LoginResult(null, YtSignInFailure.windowClosed);
      }
      if (stuck) {
        stuckCycles++;
        if (stuckCycles >= 5 && autoReloads < 2) {
          autoReloads++;
          stuckCycles = 0;
          if (kDebugMode) {
            debugPrint(
                'YtWebLogin: passkey stall detected, reloading ($autoReloads/2)');
          }
          try {
            webview.launch(_loginUrl, triggerOnUrlRequestEvent: false);
          } catch (_) {}
          // Keep the reloaded page above the app (same foreground
          // reason as the initial launch).
          await _foreground(webview);
          // Let the reloaded page settle before judging it again.
          await Future<void>.delayed(const Duration(seconds: 8));
          continue;
        }
      } else {
        stuckCycles = 0;
      }
      await Future<void>.delayed(_pollInterval);
    }
    return const _LoginResult(null, YtSignInFailure.windowClosed);
  }

  // -- capture helpers -------------------------------------------------------

  /// Cookie families that make up a YouTube Music session.
  static const _sapisidNames = [
    '__Secure-3PAPISID',
    '__Secure-1PAPISID',
    'SAPISID',
    'APISID',
  ];
  static const _psidNames = [
    '__Secure-3PSID',
    '__Secure-1PSID',
    'SID',
  ];
  static const _freshNames = [
    '__Secure-3PSIDTS',
    '__Secure-1PSIDTS',
  ];
  static const _loginNames = ['LOGIN_INFO'];

  /// Names that are actually forwarded in the Cookie header. Google
  /// scopes `SID`/`HSID`/`SSID`/`APISID`/`SAPISID` on both
  /// `.youtube.com` and `.google.com`; keeping a curated set avoids
  /// shipping duplicate/irrelevant cookies for unrelated properties.
  static bool _keepName(String name) {
    if (name.startsWith('__Secure-') && name.contains('PSID')) return true;
    if (name.startsWith('__Secure-') && name.contains('PAPISID')) {
      return true;
    }
    const plain = {
      'SID',
      'HSID',
      'SSID',
      'APISID',
      'SAPISID',
      'LOGIN_INFO',
      'VISITOR_INFO1_LIVE',
      'VISITOR_DATA',
      '__Secure-YEC',
      '__Secure-YEN',
      'SOCS',
      'PREF',
    };
    return plain.contains(name);
  }

  /// Human-readable list of session markers missing from [names].
  /// Empty = the jar has a complete session. Used both as the capture
  /// gate and as the paste dialog's live checklist.
  static List<String> missingMarkerNames(Iterable<String> names) {
    final set = names.map(_normName).toSet();
    final out = <String>[];
    if (!_sapisidNames.any(set.contains)) {
      out.add('SAPISID or __Secure-3PAPISID');
    }
    if (!_psidNames.any(set.contains)) {
      out.add('SID or __Secure-3PSID');
    }
    if (!_loginNames.any(set.contains) && !_freshNames.any(set.contains)) {
      out.add('LOGIN_INFO or __Secure-*PSIDTS');
    }
    return out;
  }

  /// Domain precedence for duplicate cookie names. Lower wins:
  /// `youtube.com` (0) is the most specific scope for a request to
  /// music.youtube.com, then a YouTube subdomain, then `google.com`,
  /// then other Google properties. Non-Google domains are dropped.
  static int _domainRank(String domain) {
    final d = domain.trim().toLowerCase();
    final bare = d.startsWith('.') ? d.substring(1) : d;
    if (bare.isEmpty) return 4; // unknown scope: keep as last resort
    if (bare == 'youtube.com') return 0;
    if (bare.endsWith('.youtube.com')) return 1;
    if (bare == 'google.com') return 2;
    if (bare.endsWith('.google.com')) return 3;
    return -1;
  }

  /// Builds a deterministic Cookie header from a jar, or null when the
  /// jar does not yet hold a complete, YouTube-scoped session.
  ///
  /// Duplicate names are resolved by domain precedence (YouTube scope
  /// beats Google scope), which is what a browser sends for
  /// music.youtube.com — the previous last-write-wins merge could pick
  /// the `accounts.google.com` copy of `SAPISID` and produce a header
  /// YouTube treated as anonymous.
  static String? buildCookieHeader(Iterable<YtJarCookie> cookies) {
    final best = <String, ({int rank, String value})>{};
    var hasYoutubeScoped = false;
    for (final c in cookies) {
      final name = _normName(c.name);
      final value = _normValue(c.value);
      if (name.isEmpty || value.isEmpty) continue;
      final rank = _domainRank(c.domain);
      if (rank < 0) continue;
      if (rank <= 1) hasYoutubeScoped = true;
      if (!_keepName(name)) continue;
      final prev = best[name];
      if (prev == null || rank < prev.rank) {
        best[name] = (rank: rank, value: value);
      }
    }
    if (best.isEmpty) return null;
    // Do not complete prematurely while on accounts.google.com: the
    // YouTube-scoped session cookies only exist after the redirect.
    if (!hasYoutubeScoped) return null;
    if (missingMarkerNames(best.keys).isNotEmpty) return null;
    final names = best.keys.toList()..sort();
    return names.map((n) => '$n=${best[n]!.value}').join('; ');
  }

  /// Normalizes a cookie name from the system WebView jar.
  ///
  /// Windows WebView2 appends a trailing NUL (U+0000) to most cookie
  /// names (probed 2026-09: SAPISID arrives as [83,65,80,73,83,73,68,0]),
  /// which silently breaks exact-match login detection and header keys.
  /// trim() skips NUL (not whitespace), so strip it explicitly, then
  /// whitespace and trailing '=' (never legal in a cookie name).
  static String _normName(Object? raw) {
    var s = raw is String ? raw : raw.toString();
    while (s.endsWith('\x00')) {
      s = s.substring(0, s.length - 1);
    }
    s = s.trim();
    while (s.endsWith('=')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  /// Normalizes a cookie value: strip only trailing NULs. Base64 '='
  /// padding and every other character is significant and preserved.
  static String _normValue(Object? raw) {
    var s = raw is String ? raw : raw.toString();
    while (s.endsWith('\x00')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  /// Reads and normalizes the whole cookie jar. Null when the native
  /// read failed (closed window / GTK thread busy).
  ///
  /// (Untyped list: `WebviewCookie` lives in the package's
  /// `src/cookie.dart` which the barrel file doesn't export, so the
  /// type is inferred from `getAllCookies()` instead of named.)
  static Future<List<YtJarCookie>?> _readCookies(Webview webview) async {
    try {
      final raw = await webview
          .getAllCookies()
          .timeout(const Duration(seconds: 5));
      final out = <YtJarCookie>[];
      for (final c in raw) {
        out.add(YtJarCookie(
          name: _normName(c.name),
          value: _normValue(c.value),
          domain: c.domain.toString(),
        ));
      }
      if (out.isNotEmpty && kDebugMode) {
        debugPrint('YtWebLogin: jar read ${out.length} cookies');
      }
      return out;
    } catch (_) {
      return null;
    }
  }
}

/// Result of one login poll.
@immutable
class _LoginResult {
  final String? header;
  final YtSignInFailure failure;
  const _LoginResult(this.header, this.failure);
}
