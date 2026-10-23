import 'dart:io';

import '../app_info.dart';

/// Persistent diagnostics trail: one file per app run under
/// `<appSupport>/logs/`, mirrored into `%TEMP%/lastwave/mpv-ops.log` by
/// [TraceCrumb].
///
/// Why two sinks: the temp mirror is written *synchronously and flushed*
/// before every native op, so a libmpv segfault leaves the last line
/// behind (a release build prints nothing to stdout). But %TEMP% is
/// cleaned by the OS and the mirror is truncated on every player
/// creation, so it is worthless once the user restarts the app to report
/// the problem. This sink keeps the history instead: the last
/// [maxFiles] runs, capped at [maxBytesPerFile] each, under the same
/// app-support root as the library database.
///
/// Levels: [info] is always on (open / resolve / device / error lines,
/// shape and timing only). [verbose] carries per-request detail (stream
/// clients, audio probes) and follows the "Verbose logging" setting.
///
/// Never write URLs, cookies, headers or tokens here — `LogBundle`
/// redacts anyway, but the file on disk must already be safe to share.
class DiagnosticsLog {
  DiagnosticsLog._();

  /// Runs kept on disk (this one included).
  static const int maxFiles = 5;

  /// Cap per file; the trail rotates into a new file when it is reached.
  static const int maxBytesPerFile = 2 << 20;

  static const String _prefix = 'session-';

  static Directory? _dir;
  static File? _file;
  static int _bytes = 0;
  static int _rotation = 0;
  static bool _failed = false;
  static String _bootStamp = '';

  /// Per-request detail. Flipped by the settings toggle (and read from
  /// prefs at boot); off by default so a normal run stays a few lines per
  /// track.
  static bool verbose = false;

  /// False when the previous run's file does not end with its clean-exit
  /// marker — i.e. that run crashed or was killed. Reported in the export.
  static bool previousExitClean = true;

  static Directory? get directory => _dir;
  static File? get file => _file;

  /// Point the sink at [dir] (app support `logs/`) and open this run's
  /// file. Call once from `main`; lines written before it are dropped.
  ///
  /// Everything here is best-effort: a read-only or missing directory
  /// must never take the app down, it only means no export later.
  static void init(Directory dir, {bool verbose = false}) {
    DiagnosticsLog.verbose = verbose;
    _failed = false;
    try {
      dir.createSync(recursive: true);
      _dir = dir;
      _bootStamp = _stamp(DateTime.now());
      _prune(keep: maxFiles - 1);
      previousExitClean = _previousExitClean();
      _open(rotation: 0);
      info('session start version=$appVersion '
          'mode=${_mode()} '
          'os=${Platform.operatingSystem} '
          'previous_exit=${previousExitClean ? 'clean' : 'unclean'}');
      info('runtime dart=${Platform.version.split(' ').first} '
          'locale=${Platform.localeName} '
          'logs=${dir.path}');
    } catch (_) {
      _failed = true;
    }
  }

  /// Always recorded.
  static void info(String line) => _write(line);

  /// Only when [verbose] is on.
  static void detail(String line) {
    if (!verbose) return;
    _write(line);
  }

  /// Raw line (already carries its own prefix, e.g. a crumb). Recorded
  /// whether or not [verbose] is on — callers decide the level.
  static void raw(String line) => _write(line);

  /// Section divider (`--- player created ---`), mirrors the temp trail.
  static void divider(String header) => _write(header);

  /// Marks this run as having shut down on purpose, so the next start
  /// does not report it as a crash.
  static void markCleanExit() {
    if (_failed) return;
    try {
      final f = _file;
      if (f == null) return;
      f.writeAsStringSync(
        '${DateTime.now().toIso8601String()}session end clean\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      _failed = true;
    }
  }

  /// Every file of this run (usually one; rotation adds more), newest
  /// first. Ordered by boot stamp then rotation index: a rotated file
  /// shares the stamp (`session-…-r1.log`) but is written after the one
  /// it follows, and their mtimes can land in the same millisecond.
  static List<File> sessionFiles() => _sortedFiles();

  // -- internals ----------------------------------------------------------

  static List<File> _sortedFiles() {
    final dir = _dir;
    if (dir == null) return const [];
    try {
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => _basename(f.path).startsWith(_prefix))
          .toList();
      files.sort((a, b) {
        // Boot stamp first (a run's files cluster together, newest run
        // first), then the rotation index — mtimes are not reliable enough
        // to order a file rotation that happens microseconds apart.
        final byStamp = _baseStamp(b).compareTo(_baseStamp(a));
        if (byStamp != 0) return byStamp;
        return _rotationOf(b).compareTo(_rotationOf(a));
      });
      return files;
    } catch (_) {
      return const [];
    }
  }

  /// `session-20261023-170024-r1.log` → `session-20261023-170024`.
  static String _baseStamp(File file) {
    var name = _basename(file.path);
    if (name.endsWith('.log')) name = name.substring(0, name.length - 4);
    final marker = name.lastIndexOf('-r');
    if (marker >= 0 && int.tryParse(name.substring(marker + 2)) != null) {
      name = name.substring(0, marker);
    }
    return name;
  }

  static int _rotationOf(File file) {
    final name = _basename(file.path);
    if (!name.endsWith('.log')) return 0;
    final marker = name.lastIndexOf('-r');
    if (marker < 0) return 0;
    return int.tryParse(name.substring(marker + 2, name.length - 4)) ?? 0;
  }

  static void _write(String line) {
    if (_failed) return;
    try {
      final f = _file;
      if (f == null) return;
      final text = '${DateTime.now().toIso8601String()}$line\n';
      // No per-line flush: the temp mirror already pays that cost for
      // crash safety, and this copy only has to survive a graceful exit.
      f.writeAsStringSync(text, mode: FileMode.append);
      _bytes += text.length;
      if (_bytes >= maxBytesPerFile) _open(rotation: _rotation + 1);
    } catch (_) {
      _failed = true;
    }
  }

  static void _open({required int rotation}) {
    final dir = _dir;
    if (dir == null) return;
    _rotation = rotation;
    final suffix = rotation == 0 ? '' : '-r$rotation';
    _file = File('${dir.path}${Platform.pathSeparator}'
        '$_prefix$_bootStamp$suffix.log');
    _bytes = _file!.existsSync() ? _file!.lengthSync() : 0;
  }

  /// Keep the newest [keep] files, drop the rest (oldest first).
  static void _prune({required int keep}) {
    final files = _sortedFiles();
    for (var i = keep; i < files.length; i++) {
      try {
        files[i].deleteSync();
      } catch (_) {}
    }
  }

  /// True when the newest existing session file ends with the clean-exit
  /// marker. A missing marker means that run died (or was force-killed),
  /// which is exactly what makes the *next* report useful.
  static bool _previousExitClean() {
    final files = sessionFiles();
    if (files.isEmpty) return true;
    final newest = files.first;
    try {
      final len = newest.lengthSync();
      final start = len > 4096 ? len - 4096 : 0;
      final raf = newest.openSync();
      try {
        raf.setPositionSync(start);
        final tail = String.fromCharCodes(raf.readSync(len - start));
        final lines =
            tail.split('\n').where((l) => l.trim().isNotEmpty).toList();
        if (lines.isEmpty) return true;
        return lines.last.contains('session end clean');
      } finally {
        raf.closeSync();
      }
    } catch (_) {
      return true;
    }
  }

  static String _basename(String path) {
    final i = path.lastIndexOf(Platform.pathSeparator);
    return i < 0 ? path : path.substring(i + 1);
  }

  static String _stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

  static String _mode() =>
      const bool.fromEnvironment('dart.vm.product') ? 'release' : 'debug';
}
