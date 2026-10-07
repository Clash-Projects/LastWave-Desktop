/// Fatal-error breadcrumbs: format + synchronously append Dart fatal
/// errors to the ops trail (`<temp>/lastwave/mpv-ops.log`) so the next
/// fail-fast names its line. Sync writes only — async logging cannot
/// outlive the isolate shutdown path. All best-effort, never throws.
library;

import 'dart:io';

/// One single-line, bounded breadcrumb for a fatal error.
String fatalCrumb(Object error, [StackTrace? stack]) {
  final type = error.runtimeType.toString();
  var message = '$error'.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (message.length > 500) message = '${message.substring(0, 500)}...';
  var out = 'FATAL $type: $message';
  if (stack != null) {
    final frame = stack
        .toString()
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.contains('package:lastwave'),
            orElse: () => '');
    if (frame.isNotEmpty) out += ' @ $frame';
  }
  return out;
}

/// Append [line] to the ops trail. Never throws.
void writeFatalCrumb(String line) {
  try {
    final path =
        '${Directory.systemTemp.path}${Platform.pathSeparator}lastwave${Platform.pathSeparator}mpv-ops.log';
    File(path).writeAsStringSync(
      '${DateTime.now().toIso8601String()} $line\n',
      mode: FileMode.append,
      flush: true,
    );
  } catch (_) {}
}
