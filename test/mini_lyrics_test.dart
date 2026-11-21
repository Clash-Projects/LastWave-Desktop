import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/lyrics/lyrics_models.dart';
import 'package:lastwave_desktop/ui/mini_player/mini_player.dart';

void main() {
  const lines = [
    LyricLine(timeMs: 1000, text: 'one'),
    LyricLine(timeMs: 4000, text: 'two'),
    LyricLine(timeMs: 9000, text: 'three'),
  ];

  test('the line playing is the last one that has started', () {
    expect(miniLyricIndex(lines, 0), -1);
    expect(miniLyricIndex(lines, 1000), 0);
    expect(miniLyricIndex(lines, 8999), 1);
    expect(miniLyricIndex(lines, 60000), 2);
  });

  test('only synced lyrics widen the lyrics miniplayer', () {
    expect(
      miniHasSyncedLyrics(const LyricsResult(lines: lines, isSynced: true)),
      isTrue,
    );
    expect(
      miniHasSyncedLyrics(
          const LyricsResult(lines: [], plainLyrics: 'words', isSynced: false)),
      isFalse,
    );
    expect(miniHasSyncedLyrics(null), isFalse);
    expect(miniPlayerBounds('lyrics', lyricsWide: true).size.width,
        greaterThan(miniPlayerBounds('lyrics').size.width));
    expect(miniPlayerBounds('lyrics').size, miniPlayerBounds('ambient').size);
  });

  test('formatMiniLyric formats commas and periods cleanly', () {
    expect(formatMiniLyric('hello , world .'), 'hello, world.');
    expect(formatMiniLyric('hello,world'), 'hello, world');
    expect(formatMiniLyric('गाड़ी खड़ी पहाड़ी में तेरी कैसेट हो'),
        'गाड़ी खड़ी पहाड़ी में तेरी कैसेट हो');
  });
}
