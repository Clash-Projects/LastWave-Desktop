/// Lyrics provider registry + fetchers ported from LastWave-native
/// `data/lyrics/*.kt`.
///
/// [LyricsProviderId.lrcRed] takes the first-party slot: lrc.red serves
/// the Bini-compatible search API (`/api/v1`) and word-sync TTML
/// documents (`/s/{ISRC}.ttml`) — verified live 2026-10-06
/// (`lyrics-api.binimum.org` 307-redirects to `lrc.red/api/v1`).
enum LyricsProviderId {
  auto(
    'auto',
    'Auto',
    'Fastest word-sync wins, LRCLIB fallback',
  ),
  lrcRed(
    'lrc_red',
    'Lrc.Red',
    'Recording-matched word-sync first',
  ),
  appleMusic(
    'apple_music',
    'Apple Music',
    'Syllable-synced Apple Music lyrics first',
  ),
  betterLyrics(
    'better_lyrics',
    'BetterLyrics',
    'Word-synced lyrics first',
  ),
  kugou(
    'kugou',
    'Kugou',
    'KRC word-synced lyrics first',
  ),
  simpMusic(
    'simp_music',
    'Video-Match',
    'Matched on the playing video first',
  ),
  musixmatch(
    'musixmatch',
    'Catalog',
    'Largest catalogue line-sync first',
  ),
  lrclib(
    'lrclib',
    'LRCLIB',
    'Line-synced community lyrics first',
  );

  final String id;
  final String title;
  final String subtitle;

  const LyricsProviderId(this.id, this.title, this.subtitle);

  /// True for providers that can return syllable/word timing and take
  /// part in the word-sync race with a preferred head start.
  bool get isWordProvider =>
      this != auto &&
      this != lrclib;

  static LyricsProviderId fromId(String? id) =>
      values.firstWhere(
        (p) => p.id == id,
        orElse: () => auto,
      );
}
