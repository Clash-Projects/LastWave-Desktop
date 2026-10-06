import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../core/artwork/animated_artwork_session.dart';
import '../core/storage/prefs.dart';
import '../features/player/playback_service.dart';
import '../features/presence/discord_presence_service.dart';
import '../ui/components/infobar_host.dart';

/// App-scoped window + tray lifecycle owner.
///
/// Mounted above the router (see [LastWaveApp]) so the handlers exist on
/// EVERY route — including `/welcome`, which renders outside [WaveShell].
/// Previously these listeners lived in the shell, so with
/// `setPreventClose(true)` active the welcome-page × button was swallowed
/// with zero handlers and tray menu clicks hit zero listeners.
///
/// Single owner by design: exactly one `windowManager`/`trayManager`
/// listener pair must exist — grep before adding another.
class WindowLifecycle extends ConsumerStatefulWidget {
  final Widget child;
  const WindowLifecycle({super.key, required this.child});

  @override
  ConsumerState<WindowLifecycle> createState() => _WindowLifecycleState();
}

class _WindowLifecycleState extends ConsumerState<WindowLifecycle>
    with TrayListener, WindowListener {
  bool _quitting = false;

  @override
  void initState() {
    super.initState();
    try {
      trayManager.addListener(this);
    } catch (_) {}
    try {
      windowManager.addListener(this);
    } catch (_) {}
  }

  /// Ordered shutdown: await libmpv stop/dispose while Dart is alive
  /// (texture callbacks after view teardown = the release-only
  /// `flutter_windows+1e220` access violation on close), then release
  /// the prevent-close hook and close once via WM_CLOSE. Never calls
  /// `destroy()` (abrupt DestroyWindow re-enters the WndProc with a
  /// half-torn-down view controller). Never traps: timeouts still close.
  Future<void> _quitApp() async {
    if (_quitting) return;
    _quitting = true;
    try {
      await Future(() async {
        try {
          await ref
              .read(playbackServiceProvider.notifier)
              .disposePlayer();
        } catch (_) {}
        try {
          // Best-effort: clear Discord status before the pipe dies.
          await ref.read(discordPresenceProvider).shutdown();
        } catch (_) {}
      }).timeout(const Duration(seconds: 4), onTimeout: () {});
    } catch (_) {}
    try {
      windowManager.removeListener(this);
    } catch (_) {}
    try {
      // Let the native WM_CLOSE path run exactly once. Calling close()
      // with prevent-close still armed would re-fire onWindowClose.
      await windowManager.setPreventClose(false);
    } catch (_) {}
    try {
      await windowManager.close();
    } catch (_) {}
  }

  @override
  void onWindowClose() {
    // Close button / Alt+F4: hide to tray when preferred, otherwise
    // quit through the ordered path (raw destroy crashes — see above).
    final toTray = () {
      try {
        return ref.read(prefsProvider).closeToTray;
      } catch (_) {
        return true;
      }
    }();
    if (toTray && !_quitting) {
      windowManager.hide().catchError((_) {});
      _setWindowVisible(false);
      try {
        ref.read(trayHintProvider.notifier).state = true;
      } catch (_) {}
      return;
    }
    unawaited(_quitApp());
  }

  // Visibility (NOT focus) drives backgrounding: side-by-side work with
  // another app focused keeps everything live — only truly invisible
  // states (minimized, tray-hidden) sleep tickers and decode. Focus
  // events are deliberately ignored here.
  void _setWindowVisible(bool visible) {
    try {
      ref.read(windowVisibleProvider.notifier).state = visible;
    } catch (_) {}
    try {
      ref.read(animatedArtworkSessionProvider).setBackgrounded(!visible);
    } catch (_) {}
  }

  @override
  void onWindowMinimize() => _setWindowVisible(false);

  @override
  void onWindowRestore() => _setWindowVisible(true);

  @override
  void onWindowMaximize() => _setWindowVisible(true);

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        _setWindowVisible(true);
        windowManager.show().then((_) => windowManager.focus()).catchError((_) {});
      case 'toggle':
        ref.read(playbackServiceProvider.notifier).toggle();
      case 'next':
        ref.read(playbackServiceProvider.notifier).next();
      case 'prev':
        ref.read(playbackServiceProvider.notifier).previous();
      case 'quit':
        unawaited(_quitApp());
    }
  }

  @override
  void onTrayIconMouseDown() {
    _setWindowVisible(true);
    windowManager.show().then((_) => windowManager.focus()).catchError((_) {});
  }

  @override
  void onTrayIconRightMouseDown() {
    // bringAppToFront is the SetForegroundWindow call TrackPopupMenu needs
    // so outside clicks dismiss the menu (upstream default leaves it stuck).
    // ignore: deprecated_member_use
    trayManager.popUpContextMenu(bringAppToFront: true).catchError((_) {});
  }

  @override
  void dispose() {
    try {
      trayManager.removeListener(this);
    } catch (_) {}
    try {
      windowManager.removeListener(this);
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// True while the OS window content is visible on screen. Karaoke tickers
/// mute while minimized/tray-hidden via framework TickerMode (auto-resumes
/// on restore, clock resyncs from the 10Hz snapshot), stopping the 30Hz
/// clock and the lyric package's display-rate repaint storm. Merely
/// unfocused (side-by-side with another app) stays live — focus events
/// never touch this. Playback state always keeps flowing. Defaults true
/// (window.dart shows at launch).
final windowVisibleProvider = StateProvider<bool>((ref) => true);
