// Crash-repro: drive the exact KR$NA payload from the 2026-10-07
// fail-fast (Never Enough / KR$NA, LRCLIB id 22601628) through the full
// lyrics pipeline incl. the flutter_lyric controller across the whole
// timeline, hunting the unhandled sync throw that kills the isolate.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_lyric/flutter_lyric.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/lyrics/flutter_lyric_adapter.dart';
import 'package:lastwave_desktop/features/lyrics/lyrics_models.dart';
import 'package:lastwave_desktop/features/lyrics/lyrics_repository.dart';

void main() {
  test('KR\$NA crash payload survives the full karaoke pipeline', () {
    final raw = File('test/fixtures/krna_never_enough_lrclib.json')
        .readAsStringSync();
    final rec = jsonDecode(raw) as Map<String, dynamic>;
    final lines = parseLrc(rec['syncedLyrics'] as String);
    expect(lines.isNotEmpty, isTrue);
    final normalized = normalizeKaraokeTimings(LyricsResult(
      lines: lines,
      isSynced: true,
      isWordSynced: false,
      plainLyrics: rec['plainLyrics'] as String,
      source: 'lrclib',
    ));
    final model = convertToFlutterLyricModel(normalized, wordByWord: true);
    final controller = LyricController();
    controller.loadLyricModel(model);
    // Sweep the whole track plus edges: negatives, exact cues, far past end.
    var stamps = <int>{0, -1, -500};
    for (final line in normalized.lines) {
      stamps.add(line.timeMs);
      stamps.add(line.timeMs - 1);
      stamps.add(line.timeMs + line.durationMs);
      for (final s in line.syllables) {
        stamps.add(s.timeMs);
      }
    }
    stamps.add(173 * 1000);
    stamps.add(1 << 40);
    for (final ms in stamps) {
      controller.setProgress(
          Duration(milliseconds: ms < 0 ? 0 : ms));
    }
    // Same sweep with line display (toggle off path).
    final lineModel =
        convertToFlutterLyricModel(normalized, wordByWord: false);
    controller.loadLyricModel(lineModel);
    for (final ms in stamps) {
      controller.setProgress(
          Duration(milliseconds: ms < 0 ? 0 : ms));
    }
  });
}
