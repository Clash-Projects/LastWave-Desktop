/// mpv on-disk paths. Split out of `playback_service.dart` so the pure
/// parts stay unit-testable without the generated secrets import chain.
library;

import 'dart:io';

/// Demuxer on-disk cache dir (mpv `cache-dir`). mpv's default location
/// fails to create on this setup (`Failed to create file cache` on
/// every open), so the app pins an explicit dir it creates itself.
String mpvCacheDirPath() =>
    '${Directory.systemTemp.path}${Platform.pathSeparator}lastwave${Platform.pathSeparator}mpv-cache';

/// Best-effort recursive mkdir. Never throws; empty path is a no-op.
Future<void> ensureDirExists(String path) async {
  if (path.trim().isEmpty) return;
  try {
    await Directory(path).create(recursive: true);
  } catch (_) {}
}
