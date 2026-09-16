import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/storage/prefs.dart';
import 'package:lastwave_desktop/features/lyrics/karaoke_lyrics_view.dart';
import 'package:lastwave_desktop/features/lyrics/lyrics_models.dart';
import 'package:lastwave_desktop/features/lyrics/lyrics_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Karaoke Lyrics Timing Offset & Formatting', () {
    test('formatOffsetDisplay formats zero correctly', () {
      expect(formatOffsetDisplay(0), equals('0.0s'));
    });

    test('formatOffsetDisplay formats positive offset correctly', () {
      expect(formatOffsetDisplay(500), equals('+0.5s'));
      expect(formatOffsetDisplay(1500), equals('+1.5s'));
    });

    test('formatOffsetDisplay formats negative offset correctly', () {
      expect(formatOffsetDisplay(-500), equals('-0.5s'));
      expect(formatOffsetDisplay(-2000), equals('-2.0s'));
    });

    test('effective position calculation applies offset correctly', () {
      const positionMs = 30000;
      const offsetMs = 500; // Lyrics delayed by 0.5s
      final effectivePosMs = positionMs - offsetMs;
      expect(effectivePosMs, equals(29500));
    });
  });

  group('Karaoke Syllable & Line Data Models', () {
    test('syllable timestamps and progressive progress calculation', () {
      const syl = LyricSyllable(
        timeMs: 1000,
        durationMs: 500,
        text: 'Hello',
      );

      expect(syl.timeMs, equals(1000));
      expect(syl.durationMs, equals(500));
      expect(syl.text, equals('Hello'));

      // Before syllable starts
      const posBefore = 800;
      final progressBefore = ((posBefore - syl.timeMs) / syl.durationMs).clamp(0.0, 1.0);
      expect(progressBefore, equals(0.0));

      // Halfway through syllable
      const posMid = 1250;
      final progressMid = ((posMid - syl.timeMs) / syl.durationMs).clamp(0.0, 1.0);
      expect(progressMid, equals(0.5));

      // After syllable ends
      const posAfter = 1600;
      final progressAfter = ((posAfter - syl.timeMs) / syl.durationMs).clamp(0.0, 1.0);
      expect(progressAfter, equals(1.0));
    });

    test('LyricLine correctly holds transliteration and syllables', () {
      const line = LyricLine(
        timeMs: 2000,
        durationMs: 3000,
        text: 'こんにちは',
        transliteration: 'Konnichiwa',
        syllables: [
          LyricSyllable(timeMs: 2000, durationMs: 1000, text: 'こん'),
          LyricSyllable(timeMs: 3000, durationMs: 2000, text: 'にちは'),
        ],
      );

      expect(line.hasSyllables, isTrue);
      expect(line.transliteration, equals('Konnichiwa'));
      expect(line.syllables.length, equals(2));
    });

    test('groupSyllablesIntoWords binds compound word syllables together without gaps', () {
      const syllables = [
        LyricSyllable(timeMs: 100, durationMs: 200, text: 'fan'),
        LyricSyllable(timeMs: 300, durationMs: 200, text: 'tas'),
        LyricSyllable(timeMs: 500, durationMs: 300, text: 'tic'),
        LyricSyllable(timeMs: 900, durationMs: 400, text: 'world'),
      ];
      const lineText = 'fantastic world';

      final groups = groupSyllablesIntoWords(syllables, lineText);
      expect(groups.length, equals(2));
      // First group: 'fantastic'
      expect(groups[0].syllables.length, equals(3));
      expect(groups[0].syllables.map((s) => s.text).join(''), equals('fantastic'));
      expect(groups[0].hasTrailingSpace, isTrue);
      // Second group: 'world'
      expect(groups[1].syllables.length, equals(1));
      expect(groups[1].syllables.first.text, equals('world'));
      expect(groups[1].hasTrailingSpace, isFalse);
    });

    test('groupSyllablesIntoWords preserves whitespace-delimited syllables', () {
      const syllables = [
        LyricSyllable(timeMs: 100, durationMs: 200, text: 'Hello '),
        LyricSyllable(timeMs: 300, durationMs: 200, text: 'there '),
        LyricSyllable(timeMs: 500, durationMs: 300, text: 'friend'),
      ];
      const lineText = 'Hello there friend';

      final groups = groupSyllablesIntoWords(syllables, lineText);
      expect(groups.length, equals(3));
      expect(groups[0].hasTrailingSpace, isTrue);
      expect(groups[1].hasTrailingSpace, isTrue);
      expect(groups[2].hasTrailingSpace, isFalse);
    });

    test('calculateSyllableProgress handles zero and edge duration smoothly', () {
      const zeroDurSyl = LyricSyllable(timeMs: 1000, durationMs: 0, text: 'hi');
      expect(calculateSyllableProgress(zeroDurSyl, 999), equals(0.0));
      expect(calculateSyllableProgress(zeroDurSyl, 1000), equals(0.0));
      expect(calculateSyllableProgress(zeroDurSyl, 1001), equals(1.0));

      const standardSyl = LyricSyllable(timeMs: 1000, durationMs: 1000, text: 'hello');
      expect(calculateSyllableProgress(standardSyl, 500), equals(0.0));
      expect(calculateSyllableProgress(standardSyl, 1000), equals(0.0));
      expect(calculateSyllableProgress(standardSyl, 1500), equals(0.5));
      expect(calculateSyllableProgress(standardSyl, 2000), equals(1.0));
      expect(calculateSyllableProgress(standardSyl, 2500), equals(1.0));
    });

    test('interpolateLineSyllables generates proportional word timing for line-synced lyrics', () {
      final syls = interpolateLineSyllables(
        text: 'Mama, just killed a man',
        startTimeMs: 10000,
        durationMs: 4000,
      );

      expect(syls.length, equals(5));
      expect(syls[0].text, equals('Mama, '));
      expect(syls[0].timeMs, equals(10000));
      expect(syls[0].durationMs, greaterThan(0));

      expect(syls.last.text, equals('man'));
      final totalSynthesized = syls.last.timeMs + syls.last.durationMs - 10000;
      expect(totalSynthesized, closeTo(4000, 200));
    });

    test('parseLrc computes duration and synthesizes syllables on line-synced LRC', () {
      const lrc = '''
[00:10.00] Line one
[00:14.00] Line two
[00:18.00] Line three
''';
      final lines = parseLrc(lrc);
      expect(lines.length, equals(3));
      expect(lines[0].timeMs, equals(10000));
      expect(lines[0].durationMs, equals(4000));
      expect(lines[0].hasSyllables, isTrue);
      expect(lines[0].syllables.length, equals(2));
      expect(lines[0].syllables[0].text, equals('Line '));
      expect(lines[0].syllables[1].text, equals('one'));
    });
  });

  group('Lyrics Title & Artist Sanitization', () {
    test('cleanSongTitle removes common YouTube noise words', () {
      expect(cleanSongTitle('Bohemian Rhapsody (Official Video)'), equals('Bohemian Rhapsody'));
      expect(cleanSongTitle('Stay [Official Audio]'), equals('Stay'));
      expect(cleanSongTitle('Hotel California - Remastered 2013'), equals('Hotel California'));
      expect(cleanSongTitle('Blinding Lights (Live on SNL)'), equals('Blinding Lights'));
      expect(cleanSongTitle('Ordinary Song'), equals('Ordinary Song'));
    });

    test('cleanSongArtist removes Topic and featuring suffixes', () {
      expect(cleanSongArtist('Queen - Topic'), equals('Queen'));
      expect(cleanSongArtist('The Weeknd feat. Daft Punk'), equals('The Weeknd'));
      expect(cleanSongArtist('Dua Lipa'), equals('Dua Lipa'));
    });
  });

  group('Preferences Parity Persistence', () {
    late Prefs prefs;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final sp = await SharedPreferences.getInstance();
      prefs = Prefs(sp);
    });

    test('lyrics offset per track persistence', () async {
      const trackKey = 'track_test_123';
      expect(prefs.getLyricsOffset(trackKey), equals(0));

      await prefs.setLyricsOffset(trackKey, 1000);
      expect(prefs.getLyricsOffset(trackKey), equals(1000));

      await prefs.resetLyricsOffset(trackKey);
      expect(prefs.getLyricsOffset(trackKey), equals(0));
    });

    test('lyrics transliteration toggle persistence', () async {
      expect(prefs.lyricsTransliteration, isTrue);

      await prefs.setLyricsTransliteration(false);
      expect(prefs.lyricsTransliteration, isFalse);

      await prefs.setLyricsTransliteration(true);
      expect(prefs.lyricsTransliteration, isTrue);
    });

    test('visualizer enabled persistence', () async {
      expect(prefs.visualizerEnabled, isTrue);

      await prefs.setVisualizerEnabled(false);
      expect(prefs.visualizerEnabled, isFalse);

      await prefs.setVisualizerEnabled(true);
      expect(prefs.visualizerEnabled, isTrue);
    });

    test('cd mode persistence', () async {
      expect(prefs.cdMode, isFalse);

      await prefs.setCdMode(true);
      expect(prefs.cdMode, isTrue);

      await prefs.setCdMode(false);
      expect(prefs.cdMode, isFalse);
    });
  });

  group('Lyrics Provider Racing & Candidate Ranking', () {
    test('Curated streaming source (Apple Music) supersedes crowdsourced (LRCLIB)', () {
      const lrclibRes = LyricsResult(
        lines: [LyricLine(timeMs: 1000, text: 'Oh Anthonio')],
        isSynced: true,
        source: 'lrclib',
      );
      const appleMusicRes = LyricsResult(
        lines: [
          LyricLine(timeMs: 1000, text: 'Overtime and overdue'),
          LyricLine(timeMs: 3000, text: 'Ain\'t no sleep that is old news'),
        ],
        isSynced: true,
        source: 'Apple Music',
      );

      expect(LyricsRepository.isBetterCandidate(appleMusicRes, lrclibRes), isTrue);
      expect(LyricsRepository.isBetterCandidate(lrclibRes, appleMusicRes), isFalse);
    });

    test('Richer song lyrics supersedes short sample loop', () {
      final sampleLoop = LyricsResult(
        lines: List.generate(
          12,
          (i) => LyricLine(timeMs: i * 1000, text: 'Sample line $i'),
        ),
        isSynced: true,
        source: 'source_a',
      );
      final fullSong = LyricsResult(
        lines: List.generate(
          48,
          (i) => LyricLine(timeMs: i * 1000, text: 'Actual verse $i'),
        ),
        isSynced: true,
        source: 'source_b',
      );

      expect(LyricsRepository.isBetterCandidate(fullSong, sampleLoop), isTrue);
    });

    test('True word-synced lyrics always supersedes line-synced lyrics', () {
      const lineSynced = LyricsResult(
        lines: [LyricLine(timeMs: 1000, text: 'Line')],
        isSynced: true,
        isWordSynced: false,
        source: 'source_a',
      );
      const wordSynced = LyricsResult(
        lines: [LyricLine(timeMs: 1000, text: 'Line')],
        isSynced: true,
        isWordSynced: true,
        source: 'source_b',
      );

      expect(LyricsRepository.isBetterCandidate(wordSynced, lineSynced), isTrue);
      expect(LyricsRepository.isBetterCandidate(lineSynced, wordSynced), isFalse);
    });
  });
}
