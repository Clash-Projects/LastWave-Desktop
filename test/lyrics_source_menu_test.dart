import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/lyrics/lyrics_providers.dart';

void main() {
  test('source strings map to provider ids', () {
    expect(lyricsSourceToProviderId('Lrc.Red (Word-Sync)'), 'lrc_red');
    expect(
        lyricsSourceToProviderId('BetterLyrics (Line-Sync)'), 'better_lyrics');
    expect(lyricsSourceToProviderId('Kugou KRC (Word-Sync)'), 'kugou');
    expect(lyricsSourceToProviderId('Video-Match (Word-Sync)'), 'simp_music');
    expect(lyricsSourceToProviderId('Catalog (Line-Sync)'), 'musixmatch');
    expect(lyricsSourceToProviderId('lrclib'), 'lrclib');
    expect(lyricsSourceToProviderId('LRCLIB (Line-Sync)'), 'lrclib');
    expect(lyricsSourceToProviderId('mystery source'), isNull);
    expect(lyricsSourceToProviderId(''), isNull);
  });

  test('picking a provider pins it and excludes the current one', () {
    // Switch Kugou → lrc.red: lrc.red pinned, Kugou excluded from fallback.
    var next = nextLyricsSelection(
      pickedId: 'lrc_red',
      currentId: 'kugou',
      currentExcludes: const {},
    );
    expect(next.override, 'lrc_red');
    expect(next.excludes, {'kugou'});

    // Re-picking the current provider changes nothing about excludes.
    next = nextLyricsSelection(
      pickedId: 'kugou',
      currentId: 'kugou',
      currentExcludes: const {'lrc_red'},
    );
    expect(next.override, 'kugou');
    expect(next.excludes, {'lrc_red'});

    // Auto clears override and exclusions for a fresh race.
    next = nextLyricsSelection(
      pickedId: 'auto',
      currentId: 'kugou',
      currentExcludes: const {'lrc_red'},
    );
    expect(next.override, isNull);
    expect(next.excludes, isEmpty);

    // Unknown current source: pin without exclusions.
    next = nextLyricsSelection(
      pickedId: 'lrc_red',
      currentId: null,
      currentExcludes: const {},
    );
    expect(next.override, 'lrc_red');
    expect(next.excludes, isEmpty);
  });

  test('retry adds current to exclusions, keeps override', () {
    expect(
      retryLyricsExcludingCurrent(
          currentId: 'kugou', excludes: const {'lrc_red'}),
      {'lrc_red', 'kugou'},
    );
    expect(
      retryLyricsExcludingCurrent(currentId: null, excludes: const {}),
      isEmpty,
    );
  });
}
