import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

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

  /// Ordered shutdown: dispose libmpv while Dart is alive (an mpv
  /// background thread outliving the isolate aborts the VM on Alt+F4),
  /// then destroy. Never traps: timeouts/errors still destroy.
  Future<void> _quitApp() async {
    if (_quitting) return;
    _quitting = true;
    try {
      await Future(() {
        try {
          ref.read(playbackServiceProvider.notifier).disposePlayer();
        } catch (_) {}
        try {
          // Best-effort: clear Discord status before the pipe dies.
          ref.read(discordPresenceProvider).shutdown();
        } catch (_) {}
      }).timeout(const Duration(seconds: 3), onTimeout: () {});
    } catch (_) {}
    try {
      await windowManager.destroy();
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
      try {
        ref.read(trayHintProvider.notifier).state = true;
      } catch (_) {}
      return;
    }
    unawaited(_quitApp());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
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
