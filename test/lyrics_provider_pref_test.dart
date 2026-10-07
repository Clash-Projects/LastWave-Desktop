import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/lyrics/lyrics_providers.dart';

void main() {
  test('provider ids round-trip, unknown falls back to auto', () {
    expect(LyricsProviderId.fromId('kugou'), LyricsProviderId.kugou);
    expect(LyricsProviderId.fromId('lrc_red'), LyricsProviderId.lrcRed);
    expect(
        LyricsProviderId.fromId('apple_music'), LyricsProviderId.appleMusic);
    expect(LyricsProviderId.fromId('bogus'), LyricsProviderId.auto);
    expect(LyricsProviderId.fromId(null), LyricsProviderId.auto);
    for (final p in LyricsProviderId.values) {
      expect(LyricsProviderId.fromId(p.id), p);
    }
  });

  test('only lrclib is a non-word provider; auto is not', () {
    for (final p in LyricsProviderId.values) {
      if (p == LyricsProviderId.lrclib || p == LyricsProviderId.auto) {
        expect(p.isWordProvider, isFalse);
      } else {
        expect(p.isWordProvider, isTrue);
      }
    }
  });

  test('every provider has title and subtitle copy', () {
    for (final p in LyricsProviderId.values) {
      expect(p.title.isNotEmpty, isTrue);
      expect(p.subtitle.isNotEmpty, isTrue);
    }
    expect(LyricsProviderId.auto.id, 'auto');
  });
}
