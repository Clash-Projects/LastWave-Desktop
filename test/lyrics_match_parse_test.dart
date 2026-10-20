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
    expect(activeLyricLineIndex(lines, 9999), 2);
    expect(activeLyricLineIndex(lines, -100), -1);

    final introLines = [
      const LyricLine(timeMs: 0, durationMs: 500, text: 'intro 1'),
      const LyricLine(timeMs: 0, durationMs: 500, text: 'intro 2'),
      const LyricLine(timeMs: 3000, durationMs: 1000, text: 'verse 1'),
    ];
    expect(activeLyricLineIndex(introLines, 0), 0);
    expect(activeLyricLineIndex(introLines, 1500), 0);
    expect(activeLyricLineIndex(introLines, 3000), 2);
  });

  test('parseLrc parses mm:ss:xx 3-part timestamps without hour misinterpretation', () {
    final lines = parseLrc('[01:23:45]Hello world\n');
    expect(lines.length, 1);
    expect(lines.first.timeMs, 83450); // 1m 23s 450ms, NOT 1h 23m 45s (5025000ms)
    expect(lines.first.text, 'Hello world');
  });

  test('parseTtml parses start, startTime, from, to, and suffixed times', () {
    const xml = '''
<tt>
  <body>
    <div>
      <p begin="00:01:23.450s" end="00:01:25s">Line 1</p>
      <p start="00:01:25.500" endTime="00:01:27.000">Line 2</p>
      <p from="88.0s" to="90.0s">Line 3</p>
    </div>
  </body>
</tt>
''';
    final lines = parseTtml(xml);
    expect(lines.length, 3);
    expect(lines[0].timeMs, 83450);
    expect(lines[1].timeMs, 85500);
    expect(lines[2].timeMs, 88000);
  });

  group('Lyrics Accent and Diacritic Matching', () {
    test('titles match across accents and diacritics', () {
      expect(lyricsTitlesMatchStrict('Beyoncé', 'Beyonce'), isTrue);
      expect(lyricsTitlesMatchStrict('Señorita', 'Senorita'), isTrue);
      expect(lyricsTitlesMatchStrict('Dépêche Mode', 'Depeche Mode'), isTrue);
      expect(lyricsTitlesMatchStrict('Café', 'Cafe'), isTrue);
    });

    test('artists match across accents and diacritics', () {
      expect(lyricsArtistsMatchStrict('Beyoncé', 'Beyonce'), isTrue);
      expect(lyricsArtistsMatchStrict('Björk', 'Bjork'), isTrue);
      expect(lyricsArtistsMatchStrict('Mötley Crüe', 'Motley Crue'), isTrue);
      expect(lyricsArtistsMatchStrict('Sigur Rós', 'Sigur Ros'), isTrue);
    });
  });

  group('Lyrics Multi-Artist Billing & Punctuation', () {
    test('artists match across conjunctions, commas, &, and x', () {
      expect(lyricsArtistsMatchStrict('Calvin Harris, Dua Lipa', 'Calvin Harris & Dua Lipa'), isTrue);
      expect(lyricsArtistsMatchStrict('Marshmello x Khalid', 'Marshmello & Khalid'), isTrue);
      expect(lyricsArtistsMatchStrict('Post Malone ft. Swae Lee', 'Post Malone, Swae Lee'), isTrue);
      expect(lyricsArtistsMatchStrict('Drake', 'Drake, 21 Savage'), isTrue);
      expect(lyricsArtistsMatchStrict('Taylor Swift', 'Taylor Swift feat. Bon Iver'), isTrue);
    });

    test('titles match across apostrophe and quote variations', () {
      expect(lyricsTitlesMatchStrict("Don't Stop Believin'", 'Dont Stop Believin'), isTrue);
      expect(lyricsTitlesMatchStrict("Rock 'N' Roll", 'Rock N Roll'), isTrue);
      expect(lyricsTitlesMatchStrict("Ain't No Mountain", 'Aint No Mountain'), isTrue);
    });

    test('rejects similarly named songs to prevent false positives', () {
      expect(lyricsTitlesMatchStrict('Let It Be', 'Let It Go'), isFalse);
      expect(lyricsTitlesMatchStrict('Bad Guy', 'Bad Girl'), isFalse);
    });

    test('rejects remix without brackets against original studio track', () {
      expect(lyricsSameVersion('Despacito', 'Despacito Remix'), isFalse);
      expect(lyricsSameVersion('Song', 'Song - VIP Mix'), isFalse);
      expect(lyricsSameVersion('Song', 'Song (Acoustic Version)'), isFalse);
    });
  });
}

