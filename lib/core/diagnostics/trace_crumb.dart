import 'dart:io';

import 'diagnostics_log.dart';

/// Crash-surviving breadcrumb sink shared by the player and the addon
/// resolver: `<temp>/lastwave/mpv-ops.log`.
///
/// The player appends one line per native op *synchronously and
/// flushed* before the call, so the last line in the file names
/// whatever killed the process — a Windows libmpv segfault prints
/// nothing to stdout. The resolver writes its latency stages into the
/// same timeline, which is the only measurement surface that survives
/// an app restart (debugPrint does not).
///
/// Every line is mirrored into [DiagnosticsLog] as well, because the temp
/// trail is truncated per player creation and temp gets cleaned: the
/// session files are what a user can still export tomorrow.
///
/// Never logs URLs, cookies, headers, or tokens — op names, stream
/// shapes, and timing numbers only.
class TraceCrumb {
  const TraceCrumb._();

  static String? _path;
  static bool _failed = false;

  /// `<temp>/lastwave` — shared with `mpv.log`.
  static String get directory =>
      '${Directory.systemTemp.path}${Platform.pathSeparator}lastwave';

  /// `<temp>/lastwave/mpv-ops.log` (directory created on first use).
  static String? get path => _path ??= _resolvePath();

  static String? _resolvePath() {
    try {
      final dir = Directory(directory);
      dir.createSync(recursive: true);
      return '${dir.path}${Platform.pathSeparator}mpv-ops.log';
    } catch (_) {
      _failed = true;
      return null;
    }
  }

  /// Append one line, best-effort. [line] carries its own prefix
  /// (`open …`, `resolve …`, `timing …`).
  ///
  /// The temp mirror and the session log are independent: a broken temp
  /// file must not cost the session trail (or the other way round).
  static void write(String line) {
    _mirror(line);
    DiagnosticsLog.raw(line);
  }

  static void _mirror(String line) {
    if (_failed) return;
    try {
      final file = path;
      if (file == null) return;
      File(file).writeAsStringSync(
        '${DateTime.now().toIso8601String()}$line\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // A broken trail must never break playback.
      _failed = true;
    }
  }

  /// Start a fresh per-session timeline. Player creation truncates the
  /// temp file so a crash report only carries the run that died; the
  /// session log keeps the whole run and only gets a divider.
  static void reset(String header) {
    _resetMirror(header);
    DiagnosticsLog.divider(header);
  }

  static void _resetMirror(String header) {
    if (_failed) return;
    try {
      final file = path;
      if (file == null) return;
      File(file).writeAsStringSync(
        '${DateTime.now().toIso8601String()}$header\n',
        flush: true,
      );
    } catch (_) {
      _failed = true;
    }
  }
}
