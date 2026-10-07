/// External playlist link support: detect the provider behind a pasted
/// string and pull out its playlist id. Public links only - no account,
/// no API keys, no OAuth anywhere in this feature.
///
/// Ported from LastWave-Native `data/playlist/ExternalPlaylistModels.kt`.
/// YouTube shapes mirror `InnertubeApi.extractPlaylistId` semantics
/// (`list=` param, `playlist/` path, else trimmed raw).
library;

import 'dart:convert';

import 'package:dio/dio.dart';

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

// -- Apple Music ------------------------------------------------------------
// Tier 1 (`serialized-server-data`, carries artists), then tier 2
// (`schema:music-playlist` ld+json, names only) as a fallback.

final _serverDataRegex = RegExp(
  '<script[^>]*\\bid\\s*=\\s*["\']?serialized-server-data["\']?[^>]*>(.*?)</script>',
  dotAll: true,
  caseSensitive: false,
);
final _schemaRegex = RegExp(
  '<script[^>]*\\bid\\s*=\\s*["\']?schema:music-playlist["\']?[^>]*>(.*?)</script>',
  dotAll: true,
  caseSensitive: false,
);
final _titleTagRegex = RegExp(
  '<title[^>]*>(.*?)</title>',
  dotAll: true,
  caseSensitive: false,
);
final _bidiRegex = RegExp(
    '[\u200E\u200F\u202A-\u202E\u2066-\u2069\uFEFF]');
final _appleSuffixRegex = RegExp(
  '\\s*[-\u2013\u2014]\\s*(?:Playlist\\s*[-\u2013\u2014]\\s*)?Apple\\s*Music\\s*\$',
  caseSensitive: false,
);
const _appleDefaultTitle = 'Apple Music Playlist';
const _maxJsonDepth = 256;

/// Apple page parser: tier 1 rows, else tier 2. Pure, never throws.
PlaylistLinkPage parseApplePage(String html) {
  try {
    return PlaylistLinkPage(
      source: PlaylistLinkSource.appleMusic,
      title: _parseAppleTitle(html),
      rows: _parseAppleRows(html),
    );
  } catch (_) {
    return PlaylistLinkPage(
      source: PlaylistLinkSource.appleMusic,
      title: _appleDefaultTitle,
    );
  }
}

List<PlaylistLinkRow> _parseAppleRows(String html) {
  final serverRows = _parseAppleServerRows(html);
  if (serverRows.isNotEmpty) return serverRows;
  return _parseAppleLdRows(html);
}

List<PlaylistLinkRow> _parseAppleServerRows(String html) {
  final content = _scriptContent(_serverDataRegex, html);
  if (content == null) return const [];
  dynamic root;
  try {
    root = jsonDecode(content);
  } catch (_) {
    return const [];
  }
  final rows = <PlaylistLinkRow>[];
  final seen = <String>{};
  void collect(dynamic element, int depth) {
    if (depth > _maxJsonDepth) return;
    if (element is Map) {
      final title = element['title'];
      final artist = element['artistName'];
      if (title is String &&
          artist is String &&
          title.trim().isNotEmpty) {
        final row = PlaylistLinkRow(
            title: title.trim(), artist: artist.trim());
        if (seen.add('${row.title.toLowerCase()}|${row.artist.toLowerCase()}')) {
          rows.add(row);
        }
      }
      for (final value in element.values) {
        collect(value, depth + 1);
      }
    } else if (element is List) {
      for (final value in element) {
        collect(value, depth + 1);
      }
    }
  }

  collect(root, 0);
  return rows;
}

List<PlaylistLinkRow> _parseAppleLdRows(String html) {
  final content = _scriptContent(_schemaRegex, html);
  if (content == null) return const [];
  dynamic root;
  try {
    root = jsonDecode(content);
  } catch (_) {
    return const [];
  }
  final tracks = _findArray(root, 'track', 0);
  if (tracks == null) return const [];
  final rows = <PlaylistLinkRow>[];
  final seen = <String>{};
  for (final entry in tracks) {
    final title = entry is Map ? entry['name']?.toString().trim() ?? '' : '';
    if (title.isEmpty) continue;
    if (seen.add(title.toLowerCase())) {
      rows.add(PlaylistLinkRow(title: title));
    }
  }
  return rows;
}

String _parseAppleTitle(String html) {
  final schemaContent = _scriptContent(_schemaRegex, html);
  if (schemaContent != null) {
    try {
      final name = _findName(jsonDecode(schemaContent));
      final cleaned =
          name != null ? _cleanAppleTitle(name) : '';
      if (cleaned.isNotEmpty) return cleaned;
    } catch (_) {}
  }
  final tag = _titleTagRegex.firstMatch(html)?.group(1);
  if (tag != null) {
    final cleaned = _cleanAppleTitle(_decodeAppleEntities(tag));
    if (cleaned.isNotEmpty) return cleaned;
  }
  return _appleDefaultTitle;
}

String? _findName(dynamic element) {
  if (element is Map) {
    final name = element['name'];
    if (name is String) return name;
    for (final value in element.values) {
      final found = _findName(value);
      if (found != null) return found;
    }
    return null;
  }
  if (element is List) {
    for (final item in element) {
      final found = _findName(item);
      if (found != null) return found;
    }
  }
  return null;
}

List<dynamic>? _findArray(dynamic element, String key, int depth) {
  if (depth > _maxJsonDepth) return null;
  if (element is Map) {
    final direct = element[key];
    if (direct is List) return direct;
    for (final value in element.values) {
      final found = _findArray(value, key, depth + 1);
      if (found != null) return found;
    }
    return null;
  }
  if (element is List) {
    for (final item in element) {
      final found = _findArray(item, key, depth + 1);
      if (found != null) return found;
    }
  }
  return null;
}

String? _scriptContent(RegExp pattern, String html) {
  final content = pattern.firstMatch(html)?.group(1)?.trim();
  return content == null || content.isEmpty ? null : content;
}

String _decodeAppleEntities(String value) => value
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&apos;', "'")
    .replaceAll('&nbsp;', ' ');

String _cleanAppleTitle(String value) {
  final noBidi = value.replaceAll(_bidiRegex, '');
  final collapsed = noBidi.replaceAll(RegExp(r'\s+'), ' ').trim();
  final noSuffix = collapsed.replaceAll(_appleSuffixRegex, '').trim();
  return noSuffix.isEmpty ? _appleDefaultTitle : noSuffix;
}

// -- Fetchers ----------------------------------------------------------------
// Keyless page downloads. Bad links fail fast with FormatException (no
// HTTP); transport failures propagate for the dialog to report.

const _spotifyEmbedBase = 'https://open.spotify.com/embed/playlist/';
const _appleFallbackBase = 'https://music.apple.com/us/playlist/';
const _desktopWindowsUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
const _desktopMacUa =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
const _fetchTimeout = Duration(seconds: 20);

/// Downloads a public Spotify playlist page and parses its track list.
Future<PlaylistLinkPage> fetchSpotifyPlaylist(
    Dio dio, String urlOrId) async {
  final id =
      extractPlaylistId(urlOrId, PlaylistLinkSource.spotify);
  if (id == null || id.isEmpty) {
    throw FormatException(
        'That does not look like a Spotify playlist link.');
  }
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
}

/// Downloads a public Apple Music playlist page and parses it.
/// Accepts a full URL, a scheme-less host path, an id-bearing path, or
/// a bare `pl.<id>` (fetched from the `us` storefront by id redirect).
Future<PlaylistLinkPage> fetchApplePlaylist(
    Dio dio, String urlOrId) async {
  final input = urlOrId.trim();
  final isUrl = input.toLowerCase().startsWith('http://') ||
      input.toLowerCase().startsWith('https://');
  final raw = !isUrl && input.toLowerCase().contains('music.apple.com')
      ? 'https://$input'
      : input;
  final id =
      extractPlaylistId(raw, PlaylistLinkSource.appleMusic);
  final bareId =
      input.toLowerCase().startsWith('pl.') ? input : null;
  final String target;
  if (isUrl) {
    target = input;
  } else if (id != null) {
    target = '$_appleFallbackBase$id';
  } else if (bareId != null) {
    target = '$_appleFallbackBase$bareId';
  } else {
    throw FormatException(
        'That does not look like an Apple Music playlist link.');
  }
  String? body;
  try {
    final res = await dio
        .get<String>(
          target,
          options: Options(
            responseType: ResponseType.plain,
            headers: {
              'User-Agent': _desktopMacUa,
              'Accept':
                  'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
              'Accept-Language': 'en-US,en;q=0.9',
            },
          ),
        )
        .timeout(_fetchTimeout);
    if (res.statusCode != null &&
        res.statusCode! >= 200 &&
        res.statusCode! < 300) {
      body = res.data;
    }
  } catch (_) {
    body = null;
  }
  if (body == null || body.trim().isEmpty) {
    throw StateError(
        'Could not load that Apple Music playlist. Check the link and try again.');
  }
  return parseApplePage(body);
}



