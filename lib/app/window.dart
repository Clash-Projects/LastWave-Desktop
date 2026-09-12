import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// Desktop platform integration: window chrome, tray, global hotkeys.
///
/// Everything is best-effort — failures are swallowed so the app
/// always starts, even on platforms missing a backend.
Future<void> setupWindow() async {
  try {
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: Size(1360, 860),
      minimumSize: Size(1024, 640),
      center: true,
      title: 'LastWave',
      titleBarStyle: TitleBarStyle.hidden,
      backgroundColor: Color(0xFF0B0D12),
    );
    await windowManager.waitUntilReadyToShow(
        options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  } catch (_) {}
  await _setupTray();
  await _setupHotkeys();
}

Future<void> _setupTray() async {
  try {
    // Icon asset is optional: drop `assets/icons/tray.ico`
    // (Windows) / `tray.png` (Linux) / `trayTemplate.png` (macOS)
    // into the project and register `assets/icons/` in pubspec
    // to enable the tray icon.
    await trayManager.setIcon('assets/icons/tray.ico');
    await trayManager.setToolTip('LastWave');
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'show', label: 'Show LastWave'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: 'Quit'),
    ]));
  } catch (_) {
    // Tray unavailable without an icon asset — not fatal.
  }
}

Future<void> _setupHotkeys() async {
  try {
    await hotKeyManager.unregisterAll();
    // Global fallbacks (media keys stay with the OS/mixer).
    final bindings = [
      HotKey(
        key: PhysicalKeyboardKey.keyP,
        modifiers: [
          HotKeyModifier.control,
          HotKeyModifier.alt
        ],
        identifier: 'lastwave-toggle',
      ),
      HotKey(
        key: PhysicalKeyboardKey.keyN,
        modifiers: [
          HotKeyModifier.control,
          HotKeyModifier.alt
        ],
        identifier: 'lastwave-next',
      ),
      HotKey(
        key: PhysicalKeyboardKey.keyB,
        modifiers: [
          HotKeyModifier.control,
          HotKeyModifier.alt
        ],
        identifier: 'lastwave-prev',
      ),
    ];
    for (final binding in bindings) {
      await hotKeyManager.register(
        binding,
        keyDownHandler: (_) {},
      );
    }
  } catch (_) {}
}
