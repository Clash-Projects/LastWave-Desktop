/// External playlist link support: detect the provider behind a pasted
/// string and pull out its playlist id. Public links only - no account,
/// no API keys, no OAuth anywhere in this feature.
///
/// Ported from LastWave-Native `data/playlist/ExternalPlaylistModels.kt`.
/// YouTube shapes mirror `InnertubeApi.extractPlaylistId` semantics
/// (`list=` param, `playlist/` path, else trimmed raw).
library;

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

/// Supported external playlist providers for the paste-a-link importer.
enum PlaylistLinkSource {
  youtube('YouTube'),
  spotify('Spotify');

  final String label;
  const PlaylistLinkSource(this.label);
}

final _spotifyIdRegex = RegExp(
    r'spotify\.com/(?:[a-z]{2,4}(?:-[a-z]{2})?/)?playlist/([A-Za-z0-9]+)');
final _spotifyUriRegex = RegExp(r'spotify:playlist:([A-Za-z0-9]+)');

/// Best-effort provider detection from a pasted string.
PlaylistLinkSource? detectPlaylistLink(String raw) {
  final value = raw.trim().toLowerCase();
  if (value.isEmpty) return null;
  if (value.contains('spotify.com') ||
      value.contains('spotify.link') ||
      value.startsWith('spotify:')) {
    return PlaylistLinkSource.spotify;
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

/// One row read off a provider page, before it is matched.
class PlaylistLinkRow {
  final String title;
  final String artist;
  const PlaylistLinkRow({required this.title, this.artist = ''});
}

/// A parsed provider playlist - the preview payload shown before importing.
class PlaylistLinkPage {
  final PlaylistLinkSource source;
  final String title;
  final List<PlaylistLinkRow> rows;
  const PlaylistLinkPage({
    required this.source,
    required this.title,
    this.rows = const [],
  });
}

final _nextDataRegex = RegExp(
  '<script[^>]*\\bid=["\']__NEXT_DATA__["\'][^>]*>(.*?)</script>',
  dotAll: true,
);
const _spotifyTrackUri = 'spotify:track:';
const _spotifyPlaylistUri = 'spotify:playlist:';

/// Spotify embed parser: `__NEXT_DATA__` JSON in, rows out. Pure, never
/// throws - unreadable input yields empty rows.
PlaylistLinkPage parseSpotifyEmbed(String html,
    [String fallbackTitle = 'Spotify Playlist']) {
  try {
    final payload = _nextDataRegex.firstMatch(html)?.group(1);
    if (payload == null || payload.trim().isEmpty) {
      return PlaylistLinkPage(
          source: PlaylistLinkSource.spotify, title: fallbackTitle);
    }
    final root = jsonDecode(_unescapeEmbedHtml(payload));
    String? title;
    final rows = <PlaylistLinkRow>[];
    final seenUris = <String>{};
    void visit(dynamic element) {
      // Index-driven queue: document order in O(n) (a removeAt(0)
      // queue would be quadratic on large hydration blobs).
      final pending = [element];
      var head = 0;
      while (head < pending.length) {
        final current = pending[head++];
        if (current is Map) {
          final uri = current['uri'];
          final name = current['title'];
          if (uri is String && name is String) {
            if (uri.startsWith(_spotifyPlaylistUri)) {
              title ??= _cleanSpotify(name).ifNonEmpty;
            } else if (uri.startsWith(_spotifyTrackUri)) {
              final trackTitle = _cleanSpotify(name);
              if (trackTitle.isNotEmpty && seenUris.add(uri)) {
                rows.add(PlaylistLinkRow(
                  title: trackTitle,
                  artist: _cleanSpotify(
                      current['subtitle']?.toString() ?? ''),
                ));
              }
            }
          }
          pending.addAll(current.values);
        } else if (current is List) {
          pending.addAll(current);
        }
      }
    }

    visit(root);
    final resolvedTitle = title?.isNotEmpty == true ? title! : fallbackTitle;
    return PlaylistLinkPage(
      source: PlaylistLinkSource.spotify,
      title: resolvedTitle,
      rows: rows,
    );
  } catch (_) {
    return PlaylistLinkPage(
        source: PlaylistLinkSource.spotify, title: fallbackTitle);
  }
}

/// Collapses non-breaking spaces (Spotify pads artist lists with them).
String _cleanSpotify(String raw) =>
    raw.replaceAll('\u00a0', ' ').trim();

/// The embed JSON is HTML-escaped inside the script tag (`&amp;` last).
String _unescapeEmbedHtml(String value) => value
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&apos;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&');

// -- Fetchers ----------------------------------------------------------------
// Keyless page downloads. Bad links fail fast with FormatException (no
// HTTP); transport failures propagate for the dialog to report.

const _spotifyEmbedBase = 'https://open.spotify.com/embed/playlist/';
const _desktopWindowsUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
const _fetchTimeout = Duration(seconds: 20);

/// Downloads a public Spotify playlist page and parses its track list.
/// `spotify.link` short URLs are followed to their canonical playlist
/// (Dio follows the HTTP redirect; the id is re-read from the final URI).
Future<PlaylistLinkPage> fetchSpotifyPlaylist(
    Dio dio, String urlOrId) async {
  if (_isMixId(urlOrId)) {
    throw FormatException(
        'Mixes and radio cannot be imported. Paste a playlist link instead.');
  }
  var id =
      extractPlaylistId(urlOrId, PlaylistLinkSource.spotify);
  if (id == null &&
      urlOrId.trim().toLowerCase().contains('spotify.link')) {
    id = await _expandShortLink(dio, urlOrId.trim());
  }
  if (id == null || id.isEmpty) {
    throw FormatException(
        'That does not look like a Spotify playlist link.');
  }
  try {
    final res = await dio
        .get<String>(
          '$_spotifyEmbedBase$id',
          options: Options(
            responseType: ResponseType.plain,
            headers: {
              'User-Agent': _desktopWindowsUa,
              'Accept': 'text/html',
            },
          ),
        )
        .timeout(_fetchTimeout);
    final body = res.data ?? '';
    if (res.statusCode != 200 || body.trim().isEmpty) {
      throw StateError(
          'Spotify playlist page returned HTTP ${res.statusCode}.');
    }
    return parseSpotifyEmbed(body);
  } on DioException {
    throw StateError(
        'Could not load that Spotify playlist. Check the link is public and try again.');
  } on TimeoutException {
    throw StateError(
        'Could not load that Spotify playlist. Check the link is public and try again.');
  }
}

/// Follows a short link to its canonical playlist id (null when the
/// target is not a playlist link).
Future<String?> _expandShortLink(Dio dio, String raw) async {
  var target = raw.trim();
  if (!target.toLowerCase().startsWith('http')) {
    target = 'https://$target';
  }
  try {
    final res = await dio
        .get<String>(
          target,
          options: Options(
            responseType: ResponseType.plain,
            headers: {'User-Agent': _desktopWindowsUa},
          ),
        )
        .timeout(_fetchTimeout);
    return extractPlaylistId(
        '${res.realUri}', PlaylistLinkSource.spotify);
  } catch (_) {
    return null;
  }
}

/// Mix/radio ids are never browsable playlists (explicit guard so a
/// regex change elsewhere cannot silently start importing mixes).
bool _isMixId(String raw) =>
    raw.trim().toUpperCase().startsWith('RD');
