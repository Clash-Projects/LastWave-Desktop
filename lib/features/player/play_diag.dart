import 'package:flutter/foundation.dart';

import '../../core/diagnostics/diagnostics_log.dart';

/// Playback diagnostic ring buffer: WHY a tapped song didn't play.
///
/// Resolve/match/open/skip events append one short line each —
/// unconditionally (release builds too), so a "spinner then dead"
/// report can be captured via Settings → Playback → Copy log and
/// pasted back. Never holds URLs, cookies, or headers: track
/// titles/artists, match tiers, videoIds, and stream shapes only.
/// debugPrint mirrors each line so `flutter run` shows it live.
class PlayDiag {
  PlayDiag._();

  static const int cap = 120;
  static final List<String> _lines = [];

  static void log(String line) {
    try {
      final stamp = DateTime.now().toIso8601String().substring(11, 19);
      _lines.add('[$stamp] $line');
      while (_lines.length > cap) {
        _lines.removeAt(0);
      }
    } catch (_) {}
    // Video decisions also go to the session log, which is what "Export
    // diagnostic logs" bundles; the in-memory buffer above is lost on exit.
    if (line.startsWith('video:')) {
      try {
        DiagnosticsLog.info(line);
      } catch (_) {}
    }
    try {
      debugPrint('LastWavePlay: $line');
    } catch (_) {}
  }

  static String dump() {
    try {
      return _lines.join('\n');
    } catch (_) {
      return '';
    }
  }

  static void clear() {
    try {
      _lines.clear();
    } catch (_) {}
  }
}
