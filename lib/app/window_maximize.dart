import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

/// Single source of truth for the OS maximize state.
///
/// Every window control (title bar, welcome chrome, player dock) reads
/// this so the icon can show maximize vs. restore, and native events keep
/// it honest for changes the app did not initiate (double-click title bar,
/// Win+Up, snap layouts).
class WindowMaximizeController extends StateNotifier<bool> {
  WindowMaximizeController() : super(false);

  Future<void> toggle() async {
    try {
      final maximized = await windowManager.isMaximized();
      if (maximized) {
        await windowManager.unmaximize();
      } else {
        await windowManager.maximize();
      }
      if (mounted) state = !maximized;
    } catch (_) {
      // No window backend (tests, unsupported host): leave the chrome as
      // it is rather than pretending the window changed.
    }
  }

  void sync(bool value) {
    if (mounted && value != state) state = value;
  }
}

final windowMaximizedProvider =
    StateNotifierProvider<WindowMaximizeController, bool>(
  (ref) => WindowMaximizeController(),
);
