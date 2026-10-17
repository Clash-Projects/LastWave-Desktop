import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/lyrics/lyrics_models.dart';

LyricLine _line(int endMs, {int start = 0}) => LyricLine(
      timeMs: start,
      durationMs: endMs - start,
      text: 'x',
      syllables: [LyricSyllable(timeMs: start, durationMs: 10, text: 'x')],
    );

void main() {
  test('sameVersion rejects live/remix, accepts remaster', () {
    expect(lyricsSameVersion('Song', 'Song (Live)'), isFalse);
    expect(lyricsSameVersion('Song (Live)', 'Song'), isFalse);
    expect(lyricsSameVersion('Song (Remix)', 'Song'), isFalse);
    expect(lyricsSameVersion('Song - Acoustic', 'Song'), isFalse);
    expect(lyricsSameVersion('Song (Remastered)', 'Song'), isTrue);
    expect(lyricsSameVersion('Song (Live)', 'Song (Live)'), isTrue);
  });

  test('strict title match rejects substring theft', () {
    expect(lyricsTitlesMatchStrict('Love Me Like You Do', 'Love'), isFalse);
    expect(lyricsTitlesMatchStrict('Love', 'Love Me Like You Do'), isFalse);
    expect(
        lyricsTitlesMatchStrict('Shape of You', 'Ed Sheeran - Shape Of You'),
        isTrue);
    expect(lyricsTitlesMatchStrict('Shape of You', 'Shape of You'), isTrue);
  });

  test('strict artist match rejects short-name theft', () {
    expect(lyricsArtistsMatchStrict('Annie', 'Ann'), isFalse);
    expect(lyricsArtistsMatchStrict('Ann', 'Annie'), isFalse);
    expect(lyricsArtistsMatchStrict('MF DOOM', 'Madvillain & MF DOOM'), isTrue);
    expect(lyricsArtistsMatchStrict('Ed Sheeran', 'Ed Sheeran'), isTrue);
    expect(lyricsArtistsMatchStrict('KR\$NA', 'Krsna'), isTrue);
    expect(lyricsArtistsMatchStrict('Ke\$ha', 'Kesha'), isTrue);
    expect(lyricsArtistsMatchStrict('A\$AP Rocky', 'ASAP Rocky'), isTrue);
  });

  test('forSearch keeps version markers, drops credits', () {
    expect(
      lyricsForSearchTitle('Song (Live) [Official Video] (feat. X)'),
      'Song (Live)',
    );
    expect(lyricsForSearchArtist('Artist - Topic'), 'Artist');
  });

  test('decodeEntities handles numeric and named refs', () {
    expect(lyricsDecodeEntities('&#x41;&amp;'), 'A&');
    expect(lyricsDecodeEntities('a&nbsp;b&#39;c'), 'a b\'c');
    expect(lyricsDecodeEntities('plain'), 'plain');
  });

  test('parseLrc extracts inline word stamps as syllables', () {
    final lines = parseLrc('[00:01.00]Hel<00:01.20>lo\n[00:05.00]Next\n');
    expect(lines.length, 2);
    // Native parity: the author text wins when longer; only stamped
    // runs become syllables.
    expect(lines.first.text, 'Hello');
    expect(lines.first.syllables.length, 1);
    expect(lines.first.syllables[0].text, 'lo');
    expect(lines.first.syllables[0].timeMs, 1200);
    expect(lines.first.text.contains('<'), isFalse);
  });

  test('parseEnhancedLrc empty for plain LRC', () {
    expect(parseEnhancedLrc('[00:01.00]Hello\n[00:05.00]World\n'), isEmpty);
    expect(
      parseEnhancedLrc('[00:01.00]Hel<00:01.20>lo\n[00:05.00]World\n').isNotEmpty,
      isTrue,
    );
  });

  test('plausibleDuration rejects wrong-cut timelines', () {
    // 4-minute track, timeline ends 300s past the end.
    final long = [_line(540000, start: 530000), _line(1000), _line(2000)];
    expect(lyricsPlausibleDuration(long, 240), isFalse);
    // Fitting timeline passes.
    final ok = [_line(1000), _line(200000), _line(235000, start: 230000)];
    expect(lyricsPlausibleDuration(ok, 240), isTrue);
    // Unknown duration always passes.
    expect(lyricsPlausibleDuration(long, null), isTrue);
  });

  test('calculateSyllableProgress handles continuous vsync interpolation', () {
    const syl = LyricSyllable(timeMs: 1000, durationMs: 200, text: 'test');
    expect(calculateSyllableProgress(syl, 999), 0.0);
    expect(calculateSyllableProgress(syl, 1000), 0.0);
    // 144Hz step: ~7ms increments
    expect(calculateSyllableProgress(syl, 1050), closeTo(0.25, 0.001));
    expect(calculateSyllableProgress(syl, 1100), closeTo(0.50, 0.001));
    expect(calculateSyllableProgress(syl, 1150), closeTo(0.75, 0.001));
    expect(calculateSyllableProgress(syl, 1200), 1.0);
    expect(calculateSyllableProgress(syl, 1207), 1.0);
  });

  test('activeLyricLineIndex resolves line index correctly across micro-ticks', () {
    final lines = [
      const LyricLine(timeMs: 0, durationMs: 1000, text: 'line 1'),
      const LyricLine(timeMs: 1000, durationMs: 1500, text: 'line 2'),
      const LyricLine(timeMs: 2500, durationMs: 1000, text: 'line 3'),
    ];
    expect(activeLyricLineIndex(lines, 0), 0);
    expect(activeLyricLineIndex(lines, 500), 0);
    expect(activeLyricLineIndex(lines, 1000), 1);
    expect(activeLyricLineIndex(lines, 2499), 1);
    expect(activeLyricLineIndex(lines, 2500), 2);
  });
}

