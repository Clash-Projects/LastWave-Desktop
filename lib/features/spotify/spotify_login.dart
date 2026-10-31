import 'dart:io';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'spotify_session.dart';

/// Opens Spotify in the same desktop WebView YouTube login uses and
/// returns the `sp_dc` cookie when the jar contains one.
///
/// Returns null when the WebView is missing, the window closes first,
/// or three minutes pass. The settings page still offers paste.
Future<String?> spotifyBrowserLogin() async {
  try {
    if (!await WebviewWindow.isWebviewAvailable()) return null;
  } catch (_) {
    return null;
  }
  final support = await getApplicationSupportDirectory();
  final folder = p.join(support.path, 'webview_spotify');
  await Directory(folder).create(recursive: true);
  final window = await WebviewWindow.create(
    configuration: CreateConfiguration(
      title: 'LastWave · Spotify',
      titleBarHeight: 40,
      windowWidth: 980,
      windowHeight: 760,
      userDataFolderWindows: folder,
    ),
  );
  var closed = false;
  window.onClose.then((_) => closed = true);
  window.launch('https://open.spotify.com/', triggerOnUrlRequestEvent: false);
  final deadline = DateTime.now().add(const Duration(minutes: 3));
  while (!closed && DateTime.now().isBefore(deadline)) {
    final value = await _readSpDc(window);
    if (value != null && value.isNotEmpty) {
      try {
        window.close();
      } catch (_) {}
      return cleanSpDc(value);
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  return null;
}

Future<String?> _readSpDc(Webview window) async {
  try {
    final raw = await window
        .getAllCookies()
        .timeout(const Duration(seconds: 5));
    for (final cookie in raw) {
      if (_normName(cookie.name) != 'sp_dc') continue;
      final value = _normValue(cookie.value);
      if (value.isNotEmpty) return value;
    }
  } catch (_) {}
  return null;
}

String _normName(Object? raw) {
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

String _normValue(Object? raw) {
  var s = raw is String ? raw : raw.toString();
  while (s.endsWith('\x00')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}
