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

/// Runs [body] and converts a synchronous throw into a crumb instead
/// of an isolate-killing unhandled error. Use in timer callbacks,
/// stream listeners, and post-frame callbacks on the hot playback
/// path, where today any throw aborts the whole process (fail-fast).
/// Returns the body value, or null when it threw.
T? runGuarded<T>(
  String scope,
  T Function() body, {
  void Function(String line)? onError,
}) {
  try {
    return body();
  } catch (error, stack) {
    final line = 'GUARD $scope: ${fatalCrumb(error, stack)}';
    if (onError != null) {
      try {
        onError(line);
      } catch (_) {}
    } else {
      writeFatalCrumb(line);
    }
    return null;
  }
}

/// Async twin of [runGuarded] for listener bodies that await.
Future<T?> runGuardedAsync<T>(
  String scope,
  Future<T> Function() body, {
  void Function(String line)? onError,
}) async {
  try {
    return await body();
  } catch (error, stack) {
    final line = 'GUARD $scope: ${fatalCrumb(error, stack)}';
    if (onError != null) {
      try {
        onError(line);
      } catch (_) {}
    } else {
      writeFatalCrumb(line);
    }
    return null;
  }
}
