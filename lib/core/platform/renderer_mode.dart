import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class RendererMode {
  RendererMode._();

  static Future<bool> isImpellerEnabled() async {
    if (Platform.isWindows) {
      try {
        final appData = Platform.environment['APPDATA'];
        if (appData != null && appData.isNotEmpty) {
          final winFile = File(p.join(appData, 'LastWave', 'renderer.flag'));
          if (await winFile.exists()) {
            final mode = (await winFile.readAsString()).trim();
            return mode == 'impeller';
          }
        }
      } catch (_) {}
    } else if (Platform.isLinux) {
      try {
        final xdg = Platform.environment['XDG_CONFIG_HOME'];
        final home = Platform.environment['HOME'];
        final basePath = (xdg != null && xdg.isNotEmpty)
            ? p.join(xdg, 'lastwave')
            : (home != null && home.isNotEmpty ? p.join(home, '.config', 'lastwave') : null);
        if (basePath != null) {
          final linuxFile = File(p.join(basePath, 'renderer.flag'));
          if (await linuxFile.exists()) {
            final mode = (await linuxFile.readAsString()).trim();
            return mode == 'impeller';
          }
        }
      } catch (_) {}
    }

    try {
      final dir = await getApplicationSupportDirectory();
      final file = File(p.join(dir.path, 'renderer.flag'));
      if (await file.exists()) {
        final mode = (await file.readAsString()).trim();
        return mode == 'impeller';
      }
    } catch (_) {}

    return false;
  }

  static Future<void> setImpellerEnabled(bool enable) async {
    final mode = enable ? 'impeller' : 'skia';
    if (Platform.isWindows) {
      try {
        final appData = Platform.environment['APPDATA'];
        if (appData != null && appData.isNotEmpty) {
          final winDir = Directory(p.join(appData, 'LastWave'));
          if (!await winDir.exists()) {
            await winDir.create(recursive: true);
          }
          final winFile = File(p.join(winDir.path, 'renderer.flag'));
          await winFile.writeAsString(mode);
        }
      } catch (_) {}
    } else if (Platform.isLinux) {
      try {
        final xdg = Platform.environment['XDG_CONFIG_HOME'];
        final home = Platform.environment['HOME'];
        final basePath = (xdg != null && xdg.isNotEmpty)
            ? p.join(xdg, 'lastwave')
            : (home != null && home.isNotEmpty ? p.join(home, '.config', 'lastwave') : null);
        if (basePath != null) {
          final dir = Directory(basePath);
          if (!await dir.exists()) await dir.create(recursive: true);
          await File(p.join(dir.path, 'renderer.flag')).writeAsString(mode);
        }
      } catch (_) {}
    }

    try {
      final dir = await getApplicationSupportDirectory();
      final file = File(p.join(dir.path, 'renderer.flag'));
      await file.writeAsString(mode);
    } catch (_) {}
  }
}
