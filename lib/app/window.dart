import 'dart:io';

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
    // Route every close request (× button, Alt+F4) through Dart
    // instead of raw GTK destroy: the shell decides hide-to-tray vs
    // ordered quit. Without this, Alt+F4 tears the engine down while
    // libmpv's thread is still calling into Dart (startup crash).
    await windowManager.setPreventClose(true);
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
    String iconPath = Platform.isWindows 
      ? 'assets/icons/tray_icon.ico' 
      : 'assets/icons/tray_icon.png';

    await trayManager.setIcon(iconPath);
    if (!Platform.isLinux) {
      await trayManager.setToolTip('LastWave');
    }
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'show', label: 'Show LastWave'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: 'Quit'),
    ]));
  } catch (_) {}
}
