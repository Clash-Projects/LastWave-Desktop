import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'innertube_api.dart';
import 'yt_library_providers.dart';
import 'yt_web_login.dart';

/// Silent session maintenance for the YouTube Music connection.
///
/// Google rotates the `__Secure-*PSIDTS` cookies continuously; a jar
/// captured once goes stale and every account surface starts coming
/// back empty. Re-exporting cookies by hand on every rotation is what
/// made the desktop app feel like it demands a fresh login.
///
/// [refresh] reuses the sign-in window this process already created
/// (`YtWebLogin.cachedWindow`) WITHOUT showing it: loading
/// music.youtube.com against the persisted WebView2 profile lets
/// Google re-mint the rotation cookies, and the captured header
/// replaces the stored session only after `connectAs` verifies it
/// against the server (atomic — a bad capture leaves the old session
/// untouched).
///
/// Deliberately not started at app launch: creating a WebView2
/// environment (and a GTK window on Linux) for every launch is the
/// exact cost the player's lazy bootstrap avoids. This runs only when
/// the session is already known to be broken.
///
/// After an app restart — and every update (setup installer or a new
/// portable build) is one — the stored jar is often already rotated
/// out while the persisted WebView2 profile (under application
/// support, untouched by updates) is still signed in. [autoRecover]
/// therefore creates the hidden window on demand, once per run, so the
/// user is not bounced to a fresh login after every update.
class YtSessionKeeper {
  YtSessionKeeper._();

  static bool _running = false;
  static bool _autoAttempted = false;

  static bool get isRunning => _running;

  /// Whether this run already spent its automatic recovery attempt.
  static bool get autoAttempted => _autoAttempted;

  /// One automatic, zero-UI recovery per app run. Safe to call from
  /// several places (shell info bar, settings banner): only the first
  /// call does anything.
  static Future<bool> autoRecover(WidgetRef ref) async {
    if (_autoAttempted || _running) return false;
    _autoAttempted = true;
    return refresh(ref, allowCreateWindow: true);
  }

  /// Attempts a zero-UI refresh. Returns true when the server accepted
  /// a freshly captured session and the stored jar was replaced.
  ///
  /// [allowCreateWindow] lets the refresh spin up the (hidden) sign-in
  /// window from the persisted WebView2 profile when this run has not
  /// created one yet.
  static Future<bool> refresh(
    WidgetRef ref, {
    bool allowCreateWindow = false,
  }) async {
    if (_running) return false;
    final api = ref.read(innerTubeProvider);
    final conn = api.connection;
    if (!conn.connected) return false;
    if (!allowCreateWindow && YtWebLogin.cachedWindow == null) return false;

    _running = true;
    try {
      final header = await YtWebLogin.refreshSilently(
        allowCreate: allowCreateWindow,
      );
      if (header == null || header.isEmpty) return false;
      await api.connectAs(
        cookies: header,
        profileEmail: conn.profileEmail,
        pageId: conn.activePageId,
      );
      ref.read(ytConnectionProvider.notifier).state = api.connection;
      // Keep the roster's jar in sync so switching identities later
      // reuses the fresh cookies instead of the rotated ones.
      try {
        await upsertYtCapture(ref, cookies: header, pageId: conn.activePageId);
      } catch (_) {}
      try {
        ref.invalidate(ytAccountProvider);
        ref.invalidate(ytLikedSongsProvider);
        ref.invalidate(ytHistoryProvider);
        ref.invalidate(ytAccountPlaylistsProvider);
      } catch (_) {}
      return true;
    } catch (_) {
      return false;
    } finally {
      _running = false;
    }
  }
}
