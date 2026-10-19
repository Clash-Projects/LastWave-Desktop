import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/lyrics/lyrics_providers.dart';

void main() {
  test('exactly 17 providers are registered', () {
    expect(LyricsProviderId.values.length, 17);
  });

  test('provider ids round-trip, unknown falls back to auto', () {
    expect(LyricsProviderId.fromId('lastwave'), LyricsProviderId.lastwave);
    expect(LyricsProviderId.fromId('kugou'), LyricsProviderId.kugou);
    expect(LyricsProviderId.fromId('lrc_red'), LyricsProviderId.lrcRed);
    expect(
        LyricsProviderId.fromId('apple_music'), LyricsProviderId.appleMusic);
    expect(LyricsProviderId.fromId('better_lyrics_portato'),
        LyricsProviderId.betterLyricsPortato);
    expect(LyricsProviderId.fromId('bini_lyrics'), LyricsProviderId.biniLyrics);
    expect(LyricsProviderId.fromId('lyrics_plus'), LyricsProviderId.lyricsPlus);
    expect(LyricsProviderId.fromId('unison'), LyricsProviderId.unison);
    expect(LyricsProviderId.fromId('youtube_captions'),
        LyricsProviderId.youtubeCaptions);
    expect(LyricsProviderId.fromId('youtube_music'),
        LyricsProviderId.youtubeMusic);
    expect(LyricsProviderId.fromId('megalobiz'), LyricsProviderId.megalobiz);
    expect(LyricsProviderId.fromId('genius'), LyricsProviderId.genius);
    expect(LyricsProviderId.fromId('bogus'), LyricsProviderId.auto);
    expect(LyricsProviderId.fromId(null), LyricsProviderId.auto);
    for (final p in LyricsProviderId.values) {
      expect(LyricsProviderId.fromId(p.id), p);
    }
  });

  test('non-word providers match Android specification', () {
    const nonWord = {
      LyricsProviderId.auto,
      LyricsProviderId.lrclib,
      LyricsProviderId.musixmatch,
      LyricsProviderId.megalobiz,
      LyricsProviderId.genius,
      LyricsProviderId.youtubeMusic,
      LyricsProviderId.youtubeCaptions,
    };
    for (final p in LyricsProviderId.values) {
      if (nonWord.contains(p)) {
        expect(p.isWordProvider, isFalse,
            reason: '${p.id} should not be a word provider');
      } else {
        expect(p.isWordProvider, isTrue,
            reason: '${p.id} should be a word provider');
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

  test('lyricsSourceToProviderId maps all source variants', () {
    expect(lyricsSourceToProviderId('LastWave Karaoke'), 'lastwave');
    expect(lyricsSourceToProviderId('lrc.red (Syllable)'), 'lrc_red');
    expect(lyricsSourceToProviderId('Apple Music'), 'apple_music');
    expect(lyricsSourceToProviderId('BetterLyrics'), 'better_lyrics');
    expect(lyricsSourceToProviderId('QQ Karaoke (Portato)'),
        'better_lyrics_portato');
    expect(lyricsSourceToProviderId('Kugou'), 'kugou');
    expect(lyricsSourceToProviderId('Syllable-Sync (Bini)'), 'bini_lyrics');
    expect(lyricsSourceToProviderId('Video-Match (Word-Sync)'), 'simp_music');
    expect(lyricsSourceToProviderId('Catalog (Musixmatch)'), 'musixmatch');
    expect(lyricsSourceToProviderId('lrclib (synced)'), 'lrclib');
    expect(lyricsSourceToProviderId('LyricsPlus (Syllable)'), 'lyrics_plus');
    expect(lyricsSourceToProviderId('Unison (Word-Sync)'), 'unison');
    expect(lyricsSourceToProviderId('YouTube Captions'), 'youtube_captions');
    expect(lyricsSourceToProviderId('YouTube Music'), 'youtube_music');
    expect(lyricsSourceToProviderId('Megalobiz (LRC)'), 'megalobiz');
    expect(lyricsSourceToProviderId('Genius (Plain)'), 'genius');
    expect(lyricsSourceToProviderId('Unknown source'), isNull);
  });
}
