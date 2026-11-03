import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/lyrics/lyrics_models.dart';

/// Reference implementation for [activeLyricLineIndex]: a plain linear
/// scan with the same documented contract (-1 before the first cue or for
/// untimed transcripts; a shared opening timestamp stays on line 0 until
/// the next distinct cue; otherwise the last line whose cue has passed).
int _linearActiveIndex(List<LyricLine> lines, int positionMs) {
  if (lines.isEmpty) return -1;
  if (positionMs < lines.first.timeMs) return -1;
  if (lines.length >= 2 && lines.first.timeMs == lines.last.timeMs) {
    return -1;
  }
  if (lines.length > 1 && lines[0].timeMs == lines[1].timeMs) {
    for (var i = 2; i < lines.length; i++) {
      if (lines[i].timeMs != lines[0].timeMs) {
        if (positionMs < lines[i].timeMs) return 0;
        break;
      }
    }
  }
  var result = 0;
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].timeMs <= positionMs) result = i;
  }
  return result;
}

List<LyricLine> _lines(List<int> times) => [
      for (var i = 0; i < times.length; i++)
        LyricLine(timeMs: times[i], durationMs: 1500, text: 'line $i'),
    ];

void main() {
  group('activeLyricLineIndex (karaoke lookup)', () {
    final lines = _lines([1000, 4000, 7000, 10000]);

    test('is -1 before the first cue and on an empty list', () {
      expect(activeLyricLineIndex(const [], 5000), -1);
      expect(activeLyricLineIndex(lines, 0), -1);
      expect(activeLyricLineIndex(lines, 999), -1);
    });

    test('switches exactly on the cue timestamp (no off-by-one)', () {
      expect(activeLyricLineIndex(lines, 1000), 0);
      expect(activeLyricLineIndex(lines, 3999), 0);
      expect(activeLyricLineIndex(lines, 4000), 1);
      expect(activeLyricLineIndex(lines, 6999), 1);
      expect(activeLyricLineIndex(lines, 7000), 2);
    });

    test('stays on the last line after the final cue', () {
      expect(activeLyricLineIndex(lines, 10000), 3);
      expect(activeLyricLineIndex(lines, 999999), 3);
    });

    test('seek backwards resolves the earlier line directly', () {
      // Lookup is stateless: a seek from line 3 to 4.5s lands on line 1.
      expect(activeLyricLineIndex(lines, 10500), 3);
      expect(activeLyricLineIndex(lines, 4500), 1);
    });

    test('untimed transcripts never report an active line', () {
      final untimed = _lines([0, 0, 0, 0]);
      expect(activeLyricLineIndex(untimed, 0), -1);
      expect(activeLyricLineIndex(untimed, 60000), -1);
    });

    test('a shared opening timestamp stays on line 0 until the next cue', () {
      final shared = _lines([2000, 2000, 2000, 6000, 9000]);
      expect(activeLyricLineIndex(shared, 2000), 0);
      expect(activeLyricLineIndex(shared, 5999), 0);
      expect(activeLyricLineIndex(shared, 6000), 3);
    });

    test('binary search matches a linear scan on random timelines', () {
      final rnd = math.Random(42);
      for (var trial = 0; trial < 200; trial++) {
        final n = 1 + rnd.nextInt(80);
        var t = rnd.nextInt(3000);
        final times = <int>[];
        for (var i = 0; i < n; i++) {
          // Include repeats (gap 0) to exercise duplicate cues.
          t += rnd.nextInt(4) == 0 ? 0 : rnd.nextInt(5000);
          times.add(t);
        }
        final ls = _lines(times);
        for (var probe = 0; probe < 50; probe++) {
          final pos = rnd.nextInt(t + 10000) - 2000;
          expect(
            activeLyricLineIndex(ls, pos),
            _linearActiveIndex(ls, pos),
            reason: 'times=$times pos=$pos',
          );
        }
      }
    });
  });

  group('calculateSyllableProgress', () {
    const syl = LyricSyllable(timeMs: 1000, durationMs: 400, text: 'la');

    test('is clamped to [0, 1] and linear inside the syllable', () {
      expect(calculateSyllableProgress(syl, 0), 0.0);
      expect(calculateSyllableProgress(syl, 1000), 0.0);
      expect(calculateSyllableProgress(syl, 1100), closeTo(0.25, 1e-9));
      expect(calculateSyllableProgress(syl, 1400), 1.0);
      expect(calculateSyllableProgress(syl, 99999), 1.0);
    });

    test('a zero-length syllable cannot divide by zero', () {
      const instant = LyricSyllable(timeMs: 500, durationMs: 0, text: 'x');
      expect(calculateSyllableProgress(instant, 499), 0.0);
      expect(calculateSyllableProgress(instant, 501), 1.0);
    });
  });

  group('stripLyricCreditLines (memoized by the karaoke view)', () {
    test('returns the identical object when nothing is stripped', () {
      // The karaoke view memoizes on the provider result's identity; this
      // pins the property its "no reset on unrelated rebuild" relies on.
      final result = LyricsResult(
        lines: _lines([1000, 4000, 7000]),
        isSynced: true,
      );
      expect(
        identical(
          stripLyricCreditLines(result, title: 'Song', artist: 'Band'),
          result,
        ),
        isTrue,
      );
    });

    test('is deterministic: two passes over the same input agree', () {
      final result = LyricsResult(
        lines: [
          const LyricLine(timeMs: 0, text: 'Written by: Someone'),
          const LyricLine(timeMs: 1000, text: 'First sung line'),
          const LyricLine(timeMs: 4000, text: 'Second sung line'),
        ],
        isSynced: true,
      );
      final a = stripLyricCreditLines(result, title: 'Song', artist: 'Band');
      final b = stripLyricCreditLines(result, title: 'Song', artist: 'Band');
      expect(
        a.lines.map((l) => l.text).toList(),
        b.lines.map((l) => l.text).toList(),
      );
      expect(a.lines.any((l) => l.text.startsWith('Written by')), isFalse);
    });
  });
}
