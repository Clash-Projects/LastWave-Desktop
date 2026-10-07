/// External playlist link support: detect the provider behind a pasted
/// string and pull out its playlist id. Public links only — no account,
/// no API keys, no OAuth anywhere in this feature.
///
/// Ported from LastWave-Native `data/playlist/ExternalPlaylistModels.kt`.
/// YouTube shapes mirror `InnertubeApi.extractPlaylistId` semantics
/// (`list=` param, `playlist/` path, else trimmed raw).
library;

/// Supported external playlist providers for the paste-a-link importer.
enum PlaylistLinkSource {
  youtube('YouTube'),
  spotify('Spotify'),
  appleMusic('Apple Music');

  final String label;
  const PlaylistLinkSource(this.label);
}

final _spotifyIdRegex = RegExp(
    r'spotify\.com/(?:[a-z]{2,4}(?:-[a-z]{2})?/)?playlist/([A-Za-z0-9]+)');
final _spotifyUriRegex = RegExp(r'spotify:playlist:([A-Za-z0-9]+)');
final _appleIdRegex = RegExp(
    r'music\.apple\.com/[a-z]{2}(?:-[a-z]{2})?/playlist/(?:[^/]+/)?(pl\.[A-Za-z0-9]+)');

/// Best-effort provider detection from a pasted string.
PlaylistLinkSource? detectPlaylistLink(String raw) {
  final value = raw.trim().toLowerCase();
  if (value.isEmpty) return null;
  if (value.contains('spotify.com') ||
      value.contains('spotify.link') ||
      value.startsWith('spotify:')) {
    return PlaylistLinkSource.spotify;
  }
  if (value.contains('music.apple.com')) {
    return PlaylistLinkSource.appleMusic;
  }
  if (value.contains('list=') ||
      value.contains('playlist/') ||
      value.contains('youtu.be') ||
      value.contains('youtube.com') ||
      value.contains('music.youtube.com')) {
    return PlaylistLinkSource.youtube;
  }
  return null;
}

/// Provider-specific playlist id, or null when the string is not a
/// playlist link for [source].
String? extractPlaylistId(String raw, PlaylistLinkSource source) {
  final value = raw.trim();
  if (value.isEmpty) return null;
  switch (source) {
    case PlaylistLinkSource.spotify:
      return _spotifyIdRegex.firstMatch(value)?.group(1) ??
          _spotifyUriRegex.firstMatch(value)?.group(1);
    case PlaylistLinkSource.appleMusic:
      return _appleIdRegex.firstMatch(value)?.group(1);
    case PlaylistLinkSource.youtube:
      if (value.contains('list=')) {
        return value
            .split('list=')
            .sublist(1)
            .join('list=')
            .split('&')
            .first
            .split('#')
            .first
            .ifNonEmpty;
      }
      if (value.contains('playlist/')) {
        return value
            .split('playlist/')
            .sublist(1)
            .join('playlist/')
            .split('?')
            .first
            .split('/')
            .first
            .ifNonEmpty;
      }
      return value.ifNonEmpty;
  }
}

extension on String {
  String? get ifNonEmpty => trim().isEmpty ? null : trim();
}
