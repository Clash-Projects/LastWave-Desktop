import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';

import 'diagnostics_log.dart';
import 'trace_crumb.dart';

/// Builds the zip a user attaches when reporting a problem:
///
/// ```
/// diagnostics.txt            summary (version, output path, prefs, counts)
/// logs/session-*.log         this run + the previous runs on disk
/// crash-trail/mpv-ops.log    the flushed temp mirror (native crash tail)
/// crash-trail/mpv.log        libmpv's own log, when it wrote one
/// README.txt                 what this is
/// ```
///
/// Everything is text and passes through [redact] on the way out: no URLs
/// (they carry signed credentials), no cookies, headers or tokens. The
/// bundle never leaves the machine on its own — it is just a file the
/// user chooses to share.
class LogBundle {
  const LogBundle._();

  /// `LastWave-logs-20261023-171500.zip`.
  static String suggestedName([DateTime? now]) {
    final t = now ?? DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'LastWave-logs-${t.year}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}.zip';
  }

  /// Name -> text content. Split out from [build] so tests can assert on
  /// the bundle without unzipping.
  static Map<String, String> collect({required String report}) {
    final out = <String, String>{};
    for (final file in DiagnosticsLog.sessionFiles()) {
      out['logs/${_basename(file.path)}'] = redact(_read(file));
    }
    final trail = TraceCrumb.path;
    if (trail != null) {
      final mirror = File(trail);
      if (mirror.existsSync()) {
        out['crash-trail/mpv-ops.log'] = redact(_read(mirror));
      }
      final mpvLog = File(
          '${TraceCrumb.directory}${Platform.pathSeparator}mpv.log');
      try {
        if (mpvLog.existsSync() && mpvLog.lengthSync() > 0) {
          out['crash-trail/mpv.log'] = redact(_read(mpvLog));
        }
      } catch (_) {}
    }
    out['diagnostics.txt'] = redact(report);
    out['README.txt'] = _readme;
    return out;
  }

  /// Zip of [collect] (deflated, no directory entries needed).
  static Uint8List build({required String report}) {
    final archive = Archive();
    final files = collect(report: report);
    for (final entry in files.entries) {
      final bytes = Uint8List.fromList(utf8.encode(entry.value));
      archive.addFile(ArchiveFile.bytes(entry.key, bytes));
    }
    return ZipEncoder().encodeBytes(archive);
  }

  /// Build, then ask where to save it. Returns the saved path, or null
  /// when the user cancelled. Throws only if the picker itself fails —
  /// callers show that to the user verbatim.
  static Future<String?> export({required String report}) async {
    final zip = build(report: report);
    final uri = await FilePicker.saveFile(
      dialogTitle: 'Export diagnostic logs',
      fileName: suggestedName(),
      bytes: zip,
      mimeType: 'application/zip',
      type: FileType.custom,
      allowedExtensions: const ['zip'],
    );
    if (uri == null) return null;
    try {
      return uri.scheme == 'file' ? uri.toFilePath() : uri.toString();
    } catch (_) {
      return uri.toString();
    }
  }

  /// Belt-and-braces scrub. The writers avoid URLs and credentials on
  /// purpose, but a bundle must be safe to hand over even if one slipped
  /// through (e.g. an exception message quoting a request).
  static String redact(String text) => text
      .replaceAll(_secretPattern, r'$1$2<redacted>')
      .replaceAll(_urlPattern, '<url>');

  static final RegExp _urlPattern = RegExp(r'https?://\S+');
  // No inline `(?i)`: Dart's RegExp is ECMAScript and rejects inline flags.
  static final RegExp _secretPattern = RegExp(
    r'\b(authorization|cookie|set-cookie|sapisidhash|api[_-]?key|apikey|token|secret|password|signature|sig)\b(\s*[:=]\s*)(\S+)',
    caseSensitive: false,
  );

  /// Opens the folder containing [path] (a file) in the OS file manager.
  static Future<void> revealFile(String path) async {
    try {
      if (Platform.isWindows) {
        await Process.start('explorer', ['/select,', path]);
      } else if (Platform.isMacOS) {
        await Process.start('open', ['-R', path]);
      } else {
        await openFolder(File(path).parent.path);
      }
    } catch (_) {}
  }

  /// Opens [path] (a directory) in the OS file manager.
  static Future<void> openFolder(String path) async {
    try {
      if (Platform.isWindows) {
        await Process.start('explorer', [path]);
      } else if (Platform.isMacOS) {
        await Process.start('open', [path]);
      } else {
        await Process.start('xdg-open', [path]);
      }
    } catch (_) {}
  }

  static String _read(File file) {
    try {
      return file.readAsStringSync();
    } catch (_) {
      return '';
    }
  }

  static String _basename(String path) {
    final i = path.lastIndexOf(Platform.pathSeparator);
    return i < 0 ? path : path.substring(i + 1);
  }

  static const String _readme = '''
LastWave Desktop diagnostics bundle
===================================

diagnostics.txt            App/build/platform summary, audio output path,
                           quality prefs, library counts, queue at export.
logs/                      One file per app run (newest first). Each line is
                           timestamped. `timing ...` lines split a cold open
                           into resolve / assembly / first-audio; `resolve
                           stage=...` lines explain lossless matching.
crash-trail/mpv-ops.log    The flushed temp trail: its last line names the
                           native call in progress if the app died.
crash-trail/mpv.log        libmpv's own log, when it wrote one.

Every text file has been scrubbed: URLs (they carry signed credentials),
cookies, authorization headers and tokens are replaced with <url> and
<redacted>. Track titles and artist names are left in — they are what makes
a "wrong song" report actionable.

Nothing here was uploaded by the app. You are looking at a file created only
because someone clicked "Export diagnostic logs".
''';
}
