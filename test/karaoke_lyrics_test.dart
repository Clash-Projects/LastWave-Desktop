import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/storage/prefs.dart';
import 'package:lastwave_desktop/features/lyrics/desktop_lyrics_painter.dart';
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

    test('enhanced LRC keeps leading word before first timestamp tag', () {
      const lrc = '[00:10.00]When <00:10.50>the <00:11.00>night';
      final lines = parseLrc(lrc);
      expect(lines.isNotEmpty, isTrue);
      expect(lines.first.syllables.length, equals(3));
      expect(lines.first.syllables[0].text, equals('When'));
      expect(lines.first.syllables[0].timeMs, equals(10000));
      expect(lines.first.syllables[1].text, equals('the'));
      expect(lines.first.syllables[1].timeMs, equals(10500));
      expect(lines.first.syllables[2].text, equals('night'));
      expect(lines.first.syllables[2].timeMs, equals(11000));
    });

    test('TTML parses agent and preserves pre-span leading text', () {
      const ttml = '''
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
  <body>
    <div>
      <p begin="00:01.00" end="00:05.00" ttm:agent="v2">Hello <span begin="00:01.50" end="00:02.00">world</span></p>
    </div>
  </body>
</tt>
''';
      final lines = parseTtml(ttml);
      expect(lines.length, equals(1));
      expect(lines.first.agent, equals('v2'));
      expect(lines.first.text, equals('Hello world'));
      expect(lines.first.syllables.length, equals(2));
      expect(lines.first.syllables.first.text.trim(), equals('Hello'));
      expect(lines.first.syllables.first.timeMs, equals(1000));
    });

    test('assembleStanzas groups musical stanzas, duet roles, and nested background harmonies', () {
      const lines = [
        LyricLine(timeMs: 1000, durationMs: 1000, text: 'Lead line 1'),
        LyricLine(timeMs: 2200, durationMs: 800, text: '(ooh yeah)'),
        // Gap > 2500ms creates stanza break:
        LyricLine(timeMs: 6000, durationMs: 1000, text: 'Duet line 2', agent: 'v2'),
        LyricLine(timeMs: 7200, durationMs: 1000, text: 'Both: All together now'),
      ];

      final stanzas = assembleStanzas(lines);
      expect(stanzas.length, equals(2));

      // Stanza 1 has 1 group with 1 background subline
      expect(stanzas[0].groups.length, equals(1));
      expect(stanzas[0].groups[0].leadLine.text, equals('Lead line 1'));
      expect(stanzas[0].groups[0].backgroundSublines.length, equals(1));
      expect(stanzas[0].groups[0].backgroundSublines.first.text, equals('(ooh yeah)'));
      expect(stanzas[0].groups[0].role, equals(VocalRole.leadLeft));

      // Stanza 2 has 2 groups: duetRight and unisonCenter
      expect(stanzas[1].groups.length, equals(2));
      expect(stanzas[1].groups[0].leadLine.text, equals('Duet line 2'));
      expect(stanzas[1].groups[0].role, equals(VocalRole.duetRight));
      expect(stanzas[1].groups[1].leadLine.text, equals('Both: All together now'));
      expect(stanzas[1].groups[1].role, equals(VocalRole.unisonCenter));
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
      expect(cleanSongTitle('Bad Guy | Official Music Video'), equals('Bad Guy'));
      expect(cleanSongTitle('Hello / 4K Video'), equals('Hello'));
      expect(cleanSongTitle("Creepin' feat. The Weeknd"), equals("Creepin'"));
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

    test('timed cut beats complete unsynced lyrics', () {
      final complete = LyricsResult(
        lines: [
          LyricLine(timeMs: 0, text: 'full chorus ${'na ' * 80}'),
          LyricLine(timeMs: 0, text: 'full verse ${'la ' * 80}'),
        ],
        source: 'complete source',
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
        LyricsRepository.isBetterCandidate(truncated, complete),
        isTrue,
      );
      expect(
        LyricsRepository.isBetterCandidate(complete, truncated),
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
        source: 'complete source',
      );
      final line = lyricsForDisplayMode(wordSynced, wordByWord: false);
      expect(line.source, 'complete source');
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
      expect(lyricsTitlesMatch('Song (Live)', 'Song'), isFalse);
      expect(lyricsTitlesMatch('Song', 'Song (Live)'), isFalse);
      expect(lyricsTitlesMatch('All Caps', 'All Caps (feat. Doom)'), isTrue);
      expect(
        lyricsTitlesMatch('Overdue', 'Overdue (feat. Travis Scott)'),
        isTrue,
      );
    });

    test('artist must be the same act, not a cover', () {
      expect(lyricsArtistsMatch('Madvillain', 'Madvillain'), isTrue);
      expect(lyricsArtistsMatch('Madvillain', 'Madvillain & MF DOOM'), isTrue);
      expect(lyricsArtistsMatch('Drake', 'Drake Bell'), isFalse);
      expect(lyricsArtistsMatch('Pink', 'Pink Floyd'), isFalse);
      expect(lyricsArtistsMatch('Drake', 'Drake, 21 Savage'), isTrue);
      expect(lyricsArtistsMatch('Drake', 'Drake feat. 21 Savage'), isTrue);
      expect(lyricsArtistsMatch('Drake', 'Drake ft 21 Savage'), isTrue);
      expect(lyricsArtistsMatch('Drake', 'Drake with 21 Savage'), isTrue);
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
      expect(lyricsDurationPlausible(240, 205), isTrue);
      expect(lyricsDurationPlausible(240, 280), isTrue);
    });

    test('lyricsTitlesMatch matches Artist - Title against Title', () {
      expect(lyricsTitlesMatch('Shape of You', 'Ed Sheeran - Shape Of You'), isTrue);
      expect(lyricsTitlesMatch('Ed Sheeran - Shape Of You', 'Shape of You'), isTrue);
      expect(lyricsTitlesMatch('Queen - Bohemian Rhapsody', 'Bohemian Rhapsody'), isTrue);
    });
  });

  group('Karaoke wipe render states', () {
    const line = LyricLine(
      timeMs: 1000,
      durationMs: 2000,
      text: 'Hello world',
      syllables: [
        LyricSyllable(timeMs: 1000, durationMs: 1000, text: 'Hello '),
        LyricSyllable(timeMs: 2000, durationMs: 1000, text: 'world'),
      ],
    );

    Future<void> pumpLine(WidgetTester tester, ValueNotifier<int> pos) async {
      await tester.pumpWidget(
        FluentApp(
          home: Center(
            child: WaveKaraokeLyricLine(
              line: line,
              positionMs: pos.value,
              positionListenable: pos,
              isActive: true,
              isPast: false,
            ),
          ),
        ),
      );
    }

    TextStyle? effectiveStyle(WidgetTester tester, String text) {
      final paragraph = tester.renderObject<RenderParagraph>(find.text(text));
      final span = paragraph.text;
      return span is TextSpan ? span.style : null;
    }

    testWidgets('resting syllable does not inherit the active-line glow',
        (tester) async {
      final pos = ValueNotifier<int>(500);
      addTearDown(pos.dispose);
      await pumpLine(tester, pos);

      expect(find.text('Hello'), findsOneWidget);
      final style = effectiveStyle(tester, 'Hello');
      expect(style, isNotNull);
      expect(
        style!.shadows ?? const <Shadow>[],
        isEmpty,
        reason: 'Text merges the active-line glow from AnimatedDefaultTextStyle; '
            'the unsung style must pin shadows so resting pixels match the '
            'wipe TextPainter (otherwise the word darkens the frame the wipe '
            'front reaches it)',
      );
    });

    testWidgets('wipe uses the painter path and restores glow once sung',
        (tester) async {
      final pos = ValueNotifier<int>(500);
      addTearDown(pos.dispose);
      await pumpLine(tester, pos);
      expect(find.text('Hello'), findsOneWidget);

      // Mid-syllable (0 < progress < 1) must switch to the feathered painter.
      for (final t in [1100, 1400, 1800, 1999]) {
        pos.value = t;
        await tester.pump();
        expect(
          find.text('Hello'),
          findsNothing,
          reason: 'progress=$t should render through the wipe painter',
        );
      }
      expect(tester.takeException(), isNull);

      // Completed syllable returns to Text with its glow intact.
      pos.value = 2500;
      await tester.pump();
      expect(find.text('Hello'), findsOneWidget);
      final style = effectiveStyle(tester, 'Hello');
      expect(
        style?.shadows ?? const <Shadow>[],
        isNotEmpty,
        reason: 'sung glyphs keep the highlight glow',
      );
    });
  });

  group('Lyrics Credit & Artist Header Filtering', () {
    test('strips slash-separated songwriter/composer lists like Sunflower', () {
      const sunflower = LyricsResult(
        isSynced: true,
        isWordSynced: true,
        source: 'LyricsPlus (Word-Sync)',
        lines: [
          LyricLine(
            timeMs: 1000,
            durationMs: 2000,
            text:
                'Khalif Malik Ibin Shaman Brown/Louis Russel Bell/Austin Richard Post/William Walsh/Carter Lang/Carl Rosen',
          ),
          LyricLine(
            timeMs: 3500,
            durationMs: 2000,
            text: 'Ayy, ayy, ayy, ayy (ooh)',
          ),
          LyricLine(
            timeMs: 6000,
            durationMs: 2000,
            text: 'Ooh, ooh, ooh, ooh',
          ),
        ],
      );

      final cleaned = normalizeKaraokeTimings(
        sunflower,
        title: 'Sunflower (Spider-Man: Into the Spider-Verse)',
        artist: 'Post Malone',
      );
      expect(cleaned.lines.length, equals(2));
      expect(cleaned.lines.first.text, equals('Ayy, ayy, ayy, ayy (ooh)'));
    });

    test('strips CJK and English labeled credit lines and Title - Artist headers', () {
      const withCredits = LyricsResult(
        isSynced: true,
        lines: [
          LyricLine(timeMs: 0, text: 'Sunflower - Post Malone & Swae Lee'),
          LyricLine(timeMs: 1000, text: '词：Khalif Brown / Austin Post'),
          LyricLine(timeMs: 2000, text: '曲：Louis Bell / Carter Lang'),
          LyricLine(timeMs: 3000, text: 'Produced by Louis Bell & Carter Lang'),
          LyricLine(timeMs: 4000, text: 'Needless to say, I keep her in check'),
          LyricLine(timeMs: 7000, text: 'She was a bad-bad, nevertheless'),
        ],
      );

      final cleaned = normalizeKaraokeTimings(
        withCredits,
        title: 'Sunflower',
        artist: 'Post Malone & Swae Lee',
      );
      expect(cleaned.lines.map((l) => l.text).toList(), [
        'Needless to say, I keep her in check',
        'She was a bad-bad, nevertheless',
      ]);
    });

    test('preserves vocal producer tags and repeated lyric slashes', () {
      const tooManyNights = LyricsResult(
        isSynced: true,
        lines: [
          LyricLine(timeMs: 1000, text: 'Honorable C.N.O.T.E.'),
          LyricLine(timeMs: 3000, text: 'Metro!'),
          LyricLine(timeMs: 5000, text: 'Mustard on the beat, ho'),
          LyricLine(timeMs: 7000, text: 'Keep the bitch jump, uh-uh'),
          LyricLine(timeMs: 9000, text: 'Yeah/Yeah/Yeah'),
          LyricLine(timeMs: 11000, text: '24/7/365'),
        ],
      );

      final cleaned = normalizeKaraokeTimings(
        tooManyNights,
        title: 'Too Many Nights (feat. Don Toliver)',
        artist: 'Metro Boomin',
      );
      expect(cleaned.lines.length, equals(6));
      expect(cleaned.lines[0].text, equals('Honorable C.N.O.T.E.'));
      expect(cleaned.lines[1].text, equals('Metro!'));
      expect(cleaned.lines[4].text, equals('Yeah/Yeah/Yeah'));
      expect(cleaned.lines[5].text, equals('24/7/365'));
    });
  });

  group('Karaoke Lyrics Depth-of-Field Blur', () {
    testWidgets('inactive lyric line applies ImageFiltered blur while active line stays sharp', (tester) async {
      const sampleLine = LyricLine(timeMs: 1000, text: 'Diamonds on my mind');

      await tester.pumpWidget(
        FluentApp(
          theme: FluentThemeData.dark(),
          home: const ScaffoldPage(
            content: Column(
              children: [
                WaveKaraokeLyricLine(
                  key: ValueKey('active_line'),
                  line: sampleLine,
                  positionMs: 1200,
                  isActive: true,
                  isPast: false,
                  blurSigma: 3.5,
                ),
                WaveKaraokeLyricLine(
                  key: ValueKey('inactive_line'),
                  line: sampleLine,
                  positionMs: 1200,
                  isActive: false,
                  isPast: false,
                  blurSigma: 3.5,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final activeBlurFinder = find.descendant(
        of: find.byKey(const ValueKey('active_line')),
        matching: find.byType(ImageFiltered),
      );
      final inactiveBlurFinder = find.descendant(
        of: find.byKey(const ValueKey('inactive_line')),
        matching: find.byType(ImageFiltered),
      );

      expect(activeBlurFinder, findsNothing);
      expect(inactiveBlurFinder, findsOneWidget);
    });
  });

  group('Desktop Lyrics Skia GPU Canvas Engine & Layout Cache', () {
    test('ParagraphLayoutCache caches and precomputes layout metrics', () {
      final cache = ParagraphLayoutCache();
      const line = LyricLine(
        timeMs: 1000,
        durationMs: 2000,
        text: 'Save your tears for another day',
        syllables: [
          LyricSyllable(timeMs: 1000, durationMs: 400, text: 'Save '),
          LyricSyllable(timeMs: 1400, durationMs: 300, text: 'your '),
          LyricSyllable(timeMs: 1700, durationMs: 500, text: 'tears '),
          LyricSyllable(timeMs: 2200, durationMs: 300, text: 'for '),
          LyricSyllable(timeMs: 2500, durationMs: 300, text: 'another '),
          LyricSyllable(timeMs: 2800, durationMs: 200, text: 'day'),
        ],
      );

      const activeStyle = TextStyle(fontSize: 36.0, fontWeight: FontWeight.bold);
      const idleStyle = TextStyle(fontSize: 36.0, fontWeight: FontWeight.normal);

      final layout1 = cache.getOrCreate(
        line: line,
        maxWidth: 800,
        activeStyle: activeStyle,
        idleStyle: idleStyle,
      );

      expect(layout1.width, greaterThan(0));
      expect(layout1.height, greaterThan(0));
      expect(layout1.syllableOffsetsX.length, equals(7)); // 0.0 + 6 syllables
      expect(layout1.syllableOffsetsX.first, equals(0.0));
      expect(layout1.syllableOffsetsX.last, greaterThan(layout1.syllableOffsetsX.first));

      // Same object returned from cache:
      final layout2 = cache.getOrCreate(
        line: line,
        maxWidth: 800,
        activeStyle: activeStyle,
        idleStyle: idleStyle,
      );
      expect(identical(layout1, layout2), isTrue);

      cache.clear();
      final layout3 = cache.getOrCreate(
        line: line,
        maxWidth: 800,
        activeStyle: activeStyle,
        idleStyle: idleStyle,
      );
      expect(identical(layout1, layout3), isFalse);
    });

    testWidgets('DesktopStanzaWidget renders spatial duet staging and nested background vocals', (tester) async {
      final cache = ParagraphLayoutCache();
      final posNotifier = ValueNotifier<int>(1200);
      addTearDown(posNotifier.dispose);

      const stanza = LyricStanza(
        timeMs: 1000,
        durationMs: 4000,
        groups: [
          LyricLineGroup(
            leadLine: LyricLine(timeMs: 1000, durationMs: 2000, text: 'Lead line singing'),
            backgroundSublines: [
              LyricLine(timeMs: 1800, durationMs: 1000, text: '(backing harmony)'),
            ],
            role: VocalRole.leadLeft,
          ),
          LyricLineGroup(
            leadLine: LyricLine(timeMs: 3000, durationMs: 2000, text: 'Duet partner replying'),
            role: VocalRole.duetRight,
          ),
        ],
      );

      const activeStyle = TextStyle(fontSize: 36.0, fontWeight: FontWeight.bold, color: Colors.white);
      const activeUnsungStyle = TextStyle(fontSize: 36.0, fontWeight: FontWeight.bold, color: Color(0x60FFFFFF));
      const idleStyle = TextStyle(fontSize: 34.0, fontWeight: FontWeight.normal, color: Color(0x60FFFFFF));
      const backgroundStyle = TextStyle(fontSize: 36.0, fontWeight: FontWeight.normal, color: Color(0x60FFFFFF));

      await tester.pumpWidget(
        FluentApp(
          theme: FluentThemeData.dark(),
          home: ScaffoldPage(
            content: DesktopStanzaWidget(
              stanza: stanza,
              activeLineTimeMs: 1000,
              positionListenable: posNotifier,
              layoutCache: cache,
              activeStyle: activeStyle,
              activeUnsungStyle: activeUnsungStyle,
              idleStyle: idleStyle,
              backgroundStyle: backgroundStyle,
              selectMode: false,
              selectedLines: const {},
              onToggleSelect: (_) {},
              onSeekLineMs: (_) {},
              allLines: const [
                LyricLine(timeMs: 1000, durationMs: 2000, text: 'Lead line singing'),
                LyricLine(timeMs: 1800, durationMs: 1000, text: '(backing harmony)'),
                LyricLine(timeMs: 3000, durationMs: 2000, text: 'Duet partner replying'),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Active lead line renders via CustomPaint (DesktopKaraokeLinePainter)
      final painterFinder = find.byType(CustomPaint);
      expect(painterFinder, findsWidgets);

      // Backing harmony is present as subordinate text under lead line
      expect(find.text('(backing harmony)'), findsOneWidget);

      // Duet line is present as text with right alignment
      expect(find.text('Duet partner replying'), findsOneWidget);
    });
  });
}
