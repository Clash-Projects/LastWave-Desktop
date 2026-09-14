import 'package:flutter/services.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// Desktop platform integration: native Mica/acrylic materials,
/// custom window chrome, tray, global hotkeys.
///
/// Everything is best-effort — failures are swallowed so the app
/// always starts, even on platforms missing a backend. Opaque
/// observatory surfaces are the polished fallback.
Future<void> setupWindow() async {
  await _setupAcrylic();
  try {
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: Size(1360, 860),
      minimumSize: Size(1024, 640),
      center: true,
      title: 'LastWave',
      titleBarStyle: TitleBarStyle.hidden,
      // Neutral graphite — matches WaveColors.background so first frame
      // never flashes navy in either theme.
      backgroundColor: Color(0xFF0E0E0E),
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  } catch (_) {}
  await _setupTray();
  await _setupHotkeys();
}

Future<void> _setupAcrylic() async {
  try {
    await Window.initialize();
    // Mica incorporates wallpaper + theme: the native observatory
    // base. Tinted dark; light pearl theme switches at runtime.
    await Window.setEffect(
      effect: WindowEffect.mica,
      dark: true,
    );
  } catch (_) {
    // Opaque fallback is the designed default — remain readable.
  }
}

/// Switch the native material when the pearl/midnight theme changes.
Future<void> applyWindowMaterial({required bool isLight}) async {
  try {
    await Window.setEffect(
      effect: WindowEffect.mica,
      dark: !isLight,
    );
  } catch (_) {}
}

Future<void> _setupTray() async {
  try {
    await trayManager.setIcon('assets/icons/tray.ico');
    await trayManager.setToolTip('LastWave');
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'show', label: 'Show LastWave'),
      MenuItem.separator(),
      MenuItem(key: 'toggle', label: 'Play / Pause  (Ctrl+Alt+P)'),
      MenuItem(key: 'next', label: 'Next  (Ctrl+Alt+N)'),
      MenuItem(key: 'prev', label: 'Previous  (Ctrl+Alt+B)'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: 'Quit'),
    ]));
  } catch (_) {}
}

Future<void> _setupHotkeys() async {
  // Global transport: Ctrl+Alt+P play/pause, Ctrl+Alt+N next,
  // Ctrl+Alt+B previous. Handlers are wired in the shell via
  // hotKeyManager.keyDownHandler forwarding to PlaybackService —
  // see WaveShell initState. Registration here stays best-effort so
  // a missing backend never blocks startup.
  try {
    await hotKeyManager.unregisterAll();
    final bindings = [
      HotKey(
        key: PhysicalKeyboardKey.keyP,
        modifiers: [HotKeyModifier.control, HotKeyModifier.alt],
        identifier: 'lastwave-toggle',
      ),
      HotKey(
        key: PhysicalKeyboardKey.keyN,
        modifiers: [HotKeyModifier.control, HotKeyModifier.alt],
        identifier: 'lastwave-next',
      ),
      HotKey(
        key: PhysicalKeyboardKey.keyB,
        modifiers: [HotKeyModifier.control, HotKeyModifier.alt],
        identifier: 'lastwave-prev',
      ),
    ];
    for (final binding in bindings) {
      await hotKeyManager.register(
        binding,
        // No-op here: the live shell overrides keyDownHandler with a
        // Riverpod-aware dispatcher once providers exist.
        keyDownHandler: (_) {},
      );
    }
  } catch (_) {}
}
