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

    test('parseLrc does not stretch a short line past the next timestamp', () {
      const lrc = '''
[00:10.00] Fast
[00:10.40] Next
''';
      final lines = parseLrc(lrc);
      expect(lines[0].durationMs, equals(400));
    });
  });

  group('Karaoke timing normalization', () {
    test('fills missing word durations until the next word', () {
      const result = LyricsResult(
        isSynced: true,
        isWordSynced: true,
        lines: [
          LyricLine(
            timeMs: 1000,
            durationMs: 0,
            text: 'hello world',
            syllables: [
              LyricSyllable(timeMs: 1000, durationMs: 0, text: 'hello '),
              LyricSyllable(timeMs: 1400, durationMs: 50, text: 'world'),
            ],
          ),
          LyricLine(
            timeMs: 3000,
            durationMs: 800,
            text: 'next',
            syllables: [
              LyricSyllable(timeMs: 3000, durationMs: 100, text: 'next'),
            ],
          ),
        ],
      );
      final n = normalizeKaraokeTimings(result);
      expect(n.lines[0].durationMs, equals(2000));
      expect(n.lines[0].syllables[0].durationMs, equals(400));
      expect(n.lines[0].syllables[1].durationMs, equals(1600));
      expect(n.lines[1].syllables[0].durationMs, equals(100));
    });

    test('scales second-based cues so a short song is not already finished', () {
      const result = LyricsResult(
        isSynced: true,
        lines: [
          LyricLine(timeMs: 8, text: 'One'),
          LyricLine(timeMs: 22, text: 'Two'),
          LyricLine(timeMs: 41, text: 'Three'),
          LyricLine(timeMs: 67, text: 'Four'),
          LyricLine(timeMs: 154, text: 'Last'),
        ],
      );
      final n = normalizeKaraokeTimings(result);
      expect(n.lines.first.timeMs, equals(8000));
      expect(n.lines.last.timeMs, equals(154000));
      expect(activeLyricLineIndex(n.lines, 0), equals(-1));
      expect(activeLyricLineIndex(n.lines, 9000), equals(0));
      expect(lyricFollowAlignment(0, compact: false), equals(0));
      expect(lyricFollowAlignment(3, compact: false), equals(0.34));
    });

    test('leaves millisecond cues unchanged', () {
      const result = LyricsResult(
        isSynced: true,
        lines: [
          LyricLine(timeMs: 8000, text: 'One'),
          LyricLine(timeMs: 22000, text: 'Two'),
          LyricLine(timeMs: 41000, text: 'Three'),
        ],
      );
      final n = normalizeKaraokeTimings(result);
      expect(n.lines.first.timeMs, equals(8000));
      expect(n.lines.last.timeMs, equals(41000));
    });

    test('does not treat the first line as active before it starts', () {
      const lines = [
        LyricLine(timeMs: 12000, text: 'Intro wait'),
        LyricLine(timeMs: 18000, text: 'Verse'),
      ];
      expect(activeLyricLineIndex(lines, 0), equals(-1));
      expect(activeLyricLineIndex(lines, 11999), equals(-1));
      expect(activeLyricLineIndex(lines, 12000), equals(0));
    });

    test('untimed transcripts stay on the opening line, not the last', () {
      final lines = [
        for (var i = 0; i < 46; i++)
          LyricLine(timeMs: 0, text: 'Line $i'),
      ];
      expect(lyricsAreUntimed(lines), isTrue);
      expect(activeLyricLineIndex(lines, 0), equals(-1));
      expect(activeLyricLineIndex(lines, 120000), equals(-1));
      expect(lyricFollowAlignment(0, compact: false), equals(0));
    });

    test('opening duplicate timestamps do not skip to the last copy', () {
      const lines = [
        LyricLine(timeMs: 0, text: 'Title'),
        LyricLine(timeMs: 0, text: 'Title 2'),
        LyricLine(timeMs: 12000, text: 'Verse'),
      ];
      expect(lyricsAreUntimed(lines), isFalse);
      expect(activeLyricLineIndex(lines, 0), equals(0));
      expect(activeLyricLineIndex(lines, 5000), equals(0));
      expect(activeLyricLineIndex(lines, 12000), equals(2));
    });

    test('parseLyricTimestampMs maps fractional seconds to milliseconds', () {
      expect(parseLyricTimestampMs(12.45), equals(12450));
      expect(parseLyricTimestampMs(1409), equals(1409));
      expect(parseLyricTimestampMs(0), equals(0));
      expect(parseLyricTimestampMs(null), equals(0));
    });

    test('keeps sung word duration instead of stretching to the next word', () {
      const result = LyricsResult(
        isSynced: true,
        isWordSynced: true,
        lines: [
          LyricLine(
            timeMs: 1000,
            durationMs: 2000,
            text: 'hello world',
            syllables: [
              LyricSyllable(timeMs: 1000, durationMs: 250, text: 'hello '),
              LyricSyllable(timeMs: 1800, durationMs: 300, text: 'world'),
            ],
          ),
        ],
      );
      final n = normalizeKaraokeTimings(result);
      expect(n.lines[0].syllables[0].durationMs, equals(250));
      expect(n.lines[0].syllables[1].durationMs, equals(300));
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

    test('Overdue verses beat the Anthonio sample loop', () {
      final sample = LyricsResult(
        lines: [
          for (var i = 0; i < 24; i++)
            LyricLine(
              timeMs: i * 1000,
              text: i % 3 == 0
                  ? 'Oh, Anthonio'
                  : i % 3 == 1
                      ? 'My Anthonio'
                      : 'Do you ever...',
            ),
        ],
        isSynced: true,
        source: 'lrclib',
      );
      const verses = LyricsResult(
        lines: [
          LyricLine(timeMs: 0, text: '(Woo)'),
          LyricLine(timeMs: 1000, text: 'Overtime and overdue (Due)'),
          LyricLine(timeMs: 2000, text: "Ain't no sleep, that is old news"),
          LyricLine(timeMs: 3000, text: "Been outside, that's with the crew"),
          LyricLine(timeMs: 4000, text: 'Made my night up on the move'),
          LyricLine(timeMs: 5000, text: 'In the morning get the news'),
          LyricLine(timeMs: 6000, text: 'She come, I heard the zoom'),
          LyricLine(timeMs: 7000, text: 'I step outside, I need my piece'),
          LyricLine(timeMs: 8000, text: 'Take one down to hit my peak'),
          LyricLine(timeMs: 9000, text: 'I feel I overuse myself'),
          LyricLine(timeMs: 10000, text: 'I overuse myself'),
          LyricLine(timeMs: 11000, text: 'I feel, I mean I overdid myself'),
        ],
        isSynced: true,
        source: 'lrclib',
      );

      expect(lyricsLooksLikeThinLoop(sample), isTrue);
      expect(lyricsLooksLikeThinLoop(verses), isFalse);
      expect(lyricsMentionsTitle('Overdue', verses), isTrue);
      expect(lyricsMentionsTitle('Overdue', sample), isFalse);
      expect(
        LyricsRepository.isBetterCandidate(
          verses,
          sample,
          queryTitle: 'Overdue',
        ),
        isTrue,
      );
      expect(
        LyricsRepository.isBetterCandidate(
          sample,
          verses,
          queryTitle: 'Overdue',
        ),
        isFalse,
      );
    });

    test('complete unsynced Apple lyrics beat a shorter timed cut', () {
      final complete = LyricsResult(
        lines: [
          LyricLine(timeMs: 0, text: 'full chorus ${'na ' * 80}'),
          LyricLine(timeMs: 0, text: 'full verse ${'la ' * 80}'),
        ],
        source: 'Apple Music',
      );
      final truncated = LyricsResult(
        lines: [
          for (var i = 0; i < 12; i++)
            LyricLine(timeMs: i * 1000, text: 'short unique line $i'),
        ],
        isSynced: true,
        source: 'lrclib',
      );
      expect(lyricsBodyLength(complete), greaterThan(lyricsBodyLength(truncated)));
      expect(
        LyricsRepository.isBetterCandidate(complete, truncated),
        isTrue,
      );
      expect(
        LyricsRepository.isBetterCandidate(truncated, complete),
        isFalse,
      );
    });

    test('packed couplets split once and keep both sung phrases', () {
      const packed =
          'numbe ras balanna mamat adin passe na adareta vada rasayi vaha kaduru';
      final parts = expandPackedLyricLine(packed);
      expect(parts.length, 2);
      expect(parts.first.toLowerCase(), contains('numbe ras'));
      expect(parts.last.toLowerCase(), contains('adareta'));
      expect(expandPackedLyricLine(parts.first).length, 1);
    });

    test('word-by-word off keeps Lyrically text as line-synced', () {
      const wordSynced = LyricsResult(
        lines: [
          LyricLine(
            timeMs: 1000,
            durationMs: 800,
            text: 'Overtime and overdue',
            syllables: [
              LyricSyllable(timeMs: 1000, durationMs: 400, text: 'Overtime '),
              LyricSyllable(timeMs: 1400, durationMs: 400, text: 'and overdue'),
            ],
          ),
        ],
        isSynced: true,
        isWordSynced: true,
        source: 'Apple Music',
      );
      final line = lyricsForDisplayMode(wordSynced, wordByWord: false);
      expect(line.source, 'Apple Music');
      expect(line.isSynced, isTrue);
      expect(line.isWordSynced, isFalse);
      expect(line.lines.single.text, 'Overtime and overdue');
      expect(line.lines.single.hasSyllables, isFalse);
      expect(
        lyricsForDisplayMode(wordSynced, wordByWord: true).isWordSynced,
        isTrue,
      );
    });

    test('placeholder Instrumental lyrics lose to real text', () {
      const placeholder = LyricsResult(
        lines: [
          LyricLine(timeMs: 0, text: 'Instrumental'),
          LyricLine(timeMs: 1000, text: '♪'),
        ],
        isSynced: true,
        source: 'lrclib',
      );
      const real = LyricsResult(
        lines: [LyricLine(timeMs: 0, text: 'Overtime and overdue')],
        isSynced: true,
        source: 'lrclib',
      );
      expect(lyricsLooksLikePlaceholder(placeholder), isTrue);
      expect(
        LyricsRepository.isBetterCandidate(real, placeholder),
        isTrue,
      );
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

  group('Lyrics identity matching', () {
    test('All Caps matches itself, not other Madvillain tracks', () {
      expect(lyricsTitlesMatch('All Caps', 'All Caps'), isTrue);
      expect(lyricsTitlesMatch('All Caps', 'ALL CAPS'), isTrue);
      expect(lyricsTitlesMatch('All Caps', 'Scene Three'), isFalse);
      expect(lyricsTitlesMatch('All Caps', 'Never Go Pop'), isFalse);
      expect(lyricsTitlesMatch('All Caps', 'Caps'), isFalse);
      expect(lyricsTitlesMatch('All Caps', 'All'), isFalse);
    });

    test('parenthetical cuts do not steal the main track', () {
      expect(lyricsTitlesMatch('Song (Interlude)', 'Song'), isFalse);
      expect(lyricsTitlesMatch('Song', 'Song (Album Version)'), isTrue);
      expect(lyricsTitlesMatch('All Caps', 'All Caps (feat. Doom)'), isTrue);
      expect(
        lyricsTitlesMatch('Overdue', 'Overdue (feat. Travis Scott)'),
        isTrue,
      );
    });

    test('artist must be the same act, not a cover', () {
      expect(lyricsArtistsMatch('Madvillain', 'Madvillain'), isTrue);
      expect(lyricsArtistsMatch('Madvillain', 'Madvillain & MF DOOM'), isTrue);
      expect(lyricsArtistsMatch('Madvillain', 'Abstract Orchestra'), isFalse);
      expect(lyricsArtistsMatch('Madvillain', 'SERAPHINE NOIR'), isFalse);
    });

    test('instrumental albums are treated as alternate recordings', () {
      expect(
        lyricsIsAlternateRecording('All Caps',
            album: 'Madvillainy Instrumentals'),
        isTrue,
      );
      expect(
        lyricsIsAlternateRecording('All Caps (Instrumental)', album: 'EP'),
        isTrue,
      );
      expect(
        lyricsIsAlternateRecording('All Caps', album: 'Madvillainy'),
        isFalse,
      );
    });

    test('duration rejects a 4-minute listing for a 2-minute track', () {
      expect(lyricsDurationPlausible(132, 138), isTrue);
      expect(lyricsDurationPlausible(132, 257), isFalse);
      expect(lyricsDurationPlausible(null, 257), isTrue);
    });
  });
}
