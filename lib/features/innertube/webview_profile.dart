import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Absolute WebView2 user-data folder for a window slot.
///
/// `desktop_webview_window` 0.3.0 defaults `userDataFolderWindows` to
/// the RELATIVE string `webview_window_WebView2` and hands it straight
/// to `CreateCoreWebView2EnvironmentWithOptions`. When the process CWD
/// is not writable — installed builds under Program Files, some
/// launchers, macOS bundles — environment creation fails, the failure
/// is swallowed, and the window sits on `about:blank` forever (the
/// "sign-in opens blank" report). An absolute folder under application
/// support is always writable and additionally gives the window a
/// persistent cookie jar across launches.
///
/// Distinct slots (`auth`, `botguard`) must never share a folder: two
/// live WebView2 environments pointed at one user-data folder conflict.
Future<String> webviewUserDataFolder(String slot) async {
  try {
    final base = await getApplicationSupportDirectory();
    final sep = Platform.pathSeparator;
    final dir = Directory('${base.path}${sep}webview2$sep$slot');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  } catch (_) {
    return '';
  }
}
