/// Pure HTML parsing for downloads.khinsider.com (video game soundtracks).
/// KHInsider has no API, so this reads the same pages a browser shows.
/// Parsing goes by link targets and cell contents rather than fixed column
/// positions, so a reordered or extra column does not break it.
///
/// Port of LastWave-Native's KhInsiderParser.
library;

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

/// One album row from a KHInsider search or list page.
class KhAlbumSummary {
  final String id;
  final String name;
  final String? thumbnailUrl;
  final String? platform;
  final String? type;
  final String? year;
  const KhAlbumSummary({
    required this.id,
    required this.name,
    this.thumbnailUrl,
    this.platform,
    this.type,
    this.year,
  });
}

/// One track row of an album page. [pagePath] is the raw href, kept encoded
/// exactly as KHInsider writes it.
class KhTrack {
  final String pagePath;
  final String name;
  final int? number;
  final int? disc;
  final int? durationSeconds;
  const KhTrack({
    required this.pagePath,
    required this.name,
    this.number,
    this.disc,
    this.durationSeconds,
  });
}

class KhAlbum {
  final String id;
  final String name;
  final String? coverUrl;
  final List<String> platforms;
  final String? year;
  final String? publisher;
  final String? developer;
  final String? type;
  final List<String> formats;
  final List<KhTrack> tracks;
  const KhAlbum({
    required this.id,
    required this.name,
    this.coverUrl,
    this.platforms = const [],
    this.year,
    this.publisher,
    this.developer,
    this.type,
    this.formats = const [],
    this.tracks = const [],
  });

  bool get hasFlac => formats.any((f) => f.toLowerCase() == 'flac');
}

/// One page of a KHInsider album list (top lists, a platform, a year).
class KhAlbumPage {
  final List<KhAlbumSummary> albums;
  final int page;
  final bool hasNext;
  const KhAlbumPage({
    required this.albums,
    required this.page,
    required this.hasNext,
  });
}

/// A browsable KHInsider list: [path] is relative to the site, e.g. "/top40".
class KhBrowseList {
  final String id;
  final String title;
  final String path;
  final bool paged;
  const KhBrowseList(this.id, this.title, this.path, {this.paged = true});
}

/// Audio file format a user can prefer. MP3 is always present on KHInsider.
enum KhFormat {
  flac('flac'),
  mp3('mp3');

  final String extension;
  const KhFormat(this.extension);
}

class KhInsiderParser {
  KhInsiderParser._();

  static const baseUrl = 'https://downloads.khinsider.com';
  static const _albumPrefix = '/game-soundtracks/album/';
  static const _knownFormats = {
    'mp3', 'flac', 'ogg', 'm4a', 'aac', 'wav', 'opus', //
  };
  static final _duration = RegExp(r'^(\d{1,2}:)?\d{1,2}:\d{2}$');
  static final _trackNumber = RegExp(r'^(\d+)\.$');
  static final _fileLink = RegExp(
    r'^https?://[^/]+/(?:soundtracks|ost)/.+',
    caseSensitive: false,
  );

  static String searchUrl(String query) =>
      '$baseUrl/search?search=${Uri.encodeQueryComponent(query.trim())}';

  /// Popular lists, as linked from the site's menu.
  static const popularLists = [
    KhBrowseList('top40', 'Top 40', '/top40', paged: false),
    KhBrowseList(
      'top6m',
      'Top 100 · last 6 months',
      '/last-6-months-top-100',
      paged: false,
    ),
    KhBrowseList(
      'topnew',
      'Top 100 · newly added',
      '/top-100-newly-added',
      paged: false,
    ),
    KhBrowseList(
      'favorites',
      'Most favorited',
      '/most-favorites',
      paged: false,
    ),
    KhBrowseList(
      'alltime',
      'All-time top 1000',
      '/all-time-top-1000',
      paged: false,
    ),
  ];

  /// Main platforms from the site's menu (slug, label); the full list comes
  /// from /console-list.
  static const mainPlatforms = [
    ('nintendo-switch', 'Switch'),
    ('switch-2', 'Switch 2'),
    ('playstation-5', 'PS5'),
    ('playstation-4', 'PS4'),
    ('xbox-one', 'Xbox One'),
    ('windows', 'Windows'),
    ('steam', 'Steam'),
    ('nintendo-3ds', '3DS'),
    ('nintendo-ds', 'DS'),
    ('nintendo-wii-u', 'Wii U'),
    ('nintendo-wii', 'Wii'),
    ('nintendo-gamecube', 'GameCube'),
    ('nintendo-64', 'N64'),
    ('nintendo-snes', 'SNES'),
    ('nintendo-nes', 'NES'),
    ('gameboy-advance', 'GBA'),
    ('gameboy', 'Game Boy'),
    ('playstation-3', 'PS3'),
    ('playstation-2', 'PS2'),
    ('playstation', 'PS1'),
    ('playstation-portable-psp', 'PSP'),
    ('playstation-vita', 'PS Vita'),
    ('xbox-360', 'Xbox 360'),
    ('xbox', 'Xbox'),
  ];

  static KhBrowseList platformList(String slug, String label) =>
      KhBrowseList('platform:$slug', label, '/game-soundtracks/$slug');

  static KhBrowseList yearList(int year) =>
      KhBrowseList('year:$year', '$year', '/game-soundtracks/year/$year');

  static String listUrl(String path, int page) =>
      baseUrl +
      path +
      (page > 1 ? '${path.contains('?') ? '&' : '?'}page=$page' : '');

  static const _nonPlatformSlugs = {
    'album',
    'browse',
    'year',
    'publisher',
    'developer',
    'ost',
    'gamerips',
    'singles',
    'arrangements',
    'remixes',
    'compilations',
    'inspired-by',
  };

  static Document _doc(String html) => html_parser.parse(html);

  static Element _content(Document doc) =>
      doc.getElementById('pageContent') ?? doc.body ?? doc.documentElement!;

  /// Whitespace-collapsed text, like jsoup's `text()`.
  static String _text(Element e) =>
      e.text.replaceAll(RegExp(r'\s+'), ' ').trim();

  static String _abs(String href, [String base = baseUrl]) {
    if (href.isEmpty) return '';
    try {
      return Uri.parse(base).resolve(href).toString();
    } catch (_) {
      return '';
    }
  }

  static String _pathOf(String url) {
    final i = url.indexOf('khinsider.com');
    final rest = i < 0
        ? (url.startsWith('/') ? url : '')
        : url.substring(i + 13);
    final q = rest.indexOf('?');
    return q < 0 ? rest : rest.substring(0, q);
  }

  /// Every platform on /console-list, as (slug, label), in page order.
  static List<(String, String)> parsePlatforms(String html) {
    final out = <String, String>{};
    for (final a in _content(_doc(html)).querySelectorAll('a[href]')) {
      final path = _pathOf(_abs(a.attributes['href'] ?? ''));
      if (!path.startsWith('/game-soundtracks/')) continue;
      var slug = path.substring('/game-soundtracks/'.length);
      while (slug.endsWith('/')) {
        slug = slug.substring(0, slug.length - 1);
      }
      if (slug.isEmpty ||
          slug.contains('/') ||
          _nonPlatformSlugs.contains(slug)) {
        continue;
      }
      final label = _text(a);
      if (label.isNotEmpty) out.putIfAbsent(slug, () => label);
    }
    return [for (final e in out.entries) (e.key, e.value)];
  }

  /// An album list page plus whether a following page exists.
  static KhAlbumPage parseAlbumPage(String html, int page) {
    final doc = _doc(html);
    final next = 'page=${page + 1}';
    final hasNext = doc.querySelectorAll('a[href]').any((a) {
      final href = a.attributes['href'] ?? '';
      return href.contains('?$next') || href.contains('&$next');
    });
    return KhAlbumPage(albums: _parseSearch(doc), page: page, hasNext: hasNext);
  }

  static String albumUrl(String albumId) => '$baseUrl$_albumPrefix$albumId';

  static String trackPageUrl(String pagePath) =>
      pagePath.startsWith('http') ? pagePath : baseUrl + pagePath;

  /// Album id from any album or track URL/path, e.g.
  /// ".../album/minecraft/1-01.mp3" -> "minecraft".
  static String? albumIdOf(String urlOrPath) {
    final idx = urlOrPath.indexOf(_albumPrefix);
    if (idx < 0) return null;
    var id = urlOrPath.substring(idx + _albumPrefix.length);
    for (final stop in ['?', '#', '/']) {
      final i = id.indexOf(stop);
      if (i >= 0) id = id.substring(0, i);
    }
    return id.isEmpty ? null : id;
  }

  static bool isAlbumPage(String finalUrl) {
    final afterScheme = finalUrl.contains('://')
        ? finalUrl.substring(finalUrl.indexOf('://') + 3)
        : finalUrl;
    final slash = afterScheme.indexOf('/');
    final path = slash < 0 ? '/' : afterScheme.substring(slash);
    if (!path.startsWith(_albumPrefix) || albumIdOf(finalUrl) == null) {
      return false;
    }
    var rest = path.substring(_albumPrefix.length);
    while (rest.endsWith('/')) {
      rest = rest.substring(0, rest.length - 1);
    }
    return !rest.contains('/');
  }

  /// Cloudflare interstitials ("Just a moment…" JS challenge).
  static bool isCloudflareChallenge(String html) {
    final head = html.length > 6000 ? html.substring(0, 6000) : html;
    return head.contains('challenge-platform') ||
        head.contains('cf-chl') ||
        head.toLowerCase().contains('<title>just a moment');
  }

  /// Cloudflare hard block page.
  static bool isCloudflareBlock(String html) =>
      (html.length > 6000 ? html.substring(0, 6000) : html).contains(
        'Attention Required! | Cloudflare',
      );

  static List<KhAlbumSummary> parseSearch(String html) =>
      _parseSearch(_doc(html));

  static List<KhAlbumSummary> _parseSearch(Document doc) {
    final table =
        doc.querySelector('table.albumList') ??
        doc
            .querySelectorAll('table')
            .cast<Element?>()
            .firstWhere(
              (t) => t!
                  .querySelectorAll('a[href]')
                  .any((a) => albumIdOf(a.attributes['href'] ?? '') != null),
              orElse: () => null,
            );
    if (table == null) return const [];
    final rows = table.querySelectorAll('tr');
    final header = rows.cast<Element?>().firstWhere(
      (r) => r!.querySelector('th') != null,
      orElse: () => null,
    );
    final headerNames =
        header?.children.map((c) => _text(c).toLowerCase()).toList() ?? [];
    final platformCol = headerNames.indexOf('platform');
    final typeCol = headerNames.indexOf('type');
    final yearCol = headerNames.indexOf('year');
    final seen = <String, KhAlbumSummary>{};
    for (final row in rows) {
      if (identical(row, header)) continue;
      final cells = row.children.where((c) => c.localName == 'td').toList();
      if (cells.isEmpty) continue;
      final nameLink = row
          .querySelectorAll('a[href]')
          .cast<Element?>()
          .firstWhere(
            (a) =>
                albumIdOf(a!.attributes['href'] ?? '') != null &&
                _text(a).isNotEmpty,
            orElse: () => null,
          );
      if (nameLink == null) continue;
      final id = albumIdOf(nameLink.attributes['href']!)!;
      if (seen.containsKey(id)) continue;
      String? cell(int i) {
        if (i < 0 || i >= cells.length) return null;
        final t = _text(cells[i]);
        return t.isEmpty ? null : t;
      }

      final thumb = _abs(
        row.querySelector('img[src]')?.attributes['src'] ?? '',
      );
      seen[id] = KhAlbumSummary(
        id: id,
        name: _text(nameLink),
        thumbnailUrl: thumb.isEmpty ? null : thumb,
        platform: cell(platformCol),
        type: cell(typeCol),
        year: cell(yearCol),
      );
    }
    return seen.values.toList();
  }

  static KhAlbum? parseAlbum(String albumId, String html) {
    final content = _content(_doc(html));
    final table = content.querySelector('#songlist');
    if (table == null) return null;
    final h2 = content.querySelector('h2');
    final ownText = h2?.nodes
        .whereType<Text>()
        .map((t) => t.text)
        .join()
        .trim();
    final name = (ownText != null && ownText.isNotEmpty)
        ? ownText
        : (h2 != null ? _text(h2) : albumId);

    final headerRow =
        table.querySelector('#songlist_header') ??
        table
            .querySelectorAll('tr')
            .cast<Element?>()
            .firstWhere(
              (r) => r!.querySelector('th') != null,
              orElse: () => null,
            );
    final formats = <String>[];
    for (final th in headerRow?.querySelectorAll('th') ?? const <Element>[]) {
      final f = _text(th).toLowerCase();
      if (_knownFormats.contains(f) && !formats.contains(f)) formats.add(f);
    }
    if (formats.isEmpty) formats.add('mp3');

    final tracks = <KhTrack>[];
    for (final row in table.querySelectorAll('tr')) {
      if (row.querySelector('th') != null || row.id == 'songlist_footer') {
        continue;
      }
      final link = row
          .querySelectorAll('a[href]')
          .cast<Element?>()
          .firstWhere(
            (a) =>
                (a!.attributes['href'] ?? '').contains(
                  '$_albumPrefix$albumId/',
                ) &&
                _text(a).isNotEmpty,
            orElse: () => null,
          );
      if (link == null) continue;
      final cells = row.children
          .where((c) => c.localName == 'td')
          .map(_text)
          .toList();
      final numberIdx = cells.indexWhere(_trackNumber.hasMatch);
      final number = numberIdx >= 0
          ? int.tryParse(_trackNumber.firstMatch(cells[numberIdx])!.group(1)!)
          : null;
      final disc = numberIdx > 0 ? int.tryParse(cells[numberIdx - 1]) : null;
      final durationCell = cells.cast<String?>().firstWhere(
        (c) => _duration.hasMatch(c!),
        orElse: () => null,
      );
      final href = link.attributes['href']!;
      tracks.add(
        KhTrack(
          pagePath: href.startsWith('http') ? _pathOf(href) : href,
          name: _text(link),
          number: number,
          disc: disc,
          durationSeconds: durationCell == null
              ? null
              : parseDuration(durationCell),
        ),
      );
    }

    final info = content.querySelectorAll('p').cast<Element?>().firstWhere((p) {
      final t = p!.text;
      return t.contains('Platforms:') ||
          t.contains('Year:') ||
          t.contains('Number of Files:');
    }, orElse: () => null);
    final infoLines = info == null
        ? const <String>[]
        : html_parser
              .parseFragment(
                info.innerHtml.replaceAll(
                  RegExp(r'<br\s*/?>', caseSensitive: false),
                  '\n',
                ),
              )
              .text!
              .split('\n')
              .map((l) => l.replaceAll(RegExp(r'\s+'), ' ').trim())
              .toList();
    String? field(String label) {
      for (final l in infoLines) {
        if (l.startsWith('$label:')) {
          final v = l.substring(label.length + 1).trim();
          return v.isEmpty ? null : v;
        }
      }
      return null;
    }

    final platforms = <String>[];
    for (final p in (field('Platforms') ?? '').split(',')) {
      final t = p.trim();
      if (t.isNotEmpty && !platforms.contains(t)) platforms.add(t);
    }
    final cover = content
        .querySelectorAll('img[src]')
        .map((i) => _abs(i.attributes['src']!))
        .cast<String?>()
        .firstWhere(
          (u) => u!.contains('/soundtracks/$albumId/'),
          orElse: () => null,
        );

    return KhAlbum(
      id: albumId,
      name: name,
      coverUrl: cover,
      platforms: platforms,
      year: field('Year'),
      publisher: field('Published by'),
      developer: field('Developed by'),
      type: field('Album type'),
      formats: formats,
      tracks: tracks,
    );
  }

  /// All audio file links on a track page, keyed by lower-case extension,
  /// in page order.
  static Map<String, String> parseTrackFiles(
    String html, [
    String pageUrl = baseUrl,
  ]) {
    final out = <String, String>{};
    for (final a in _doc(html).querySelectorAll('a[href]')) {
      final raw = a.attributes['href'] ?? '';
      final href = _abs(raw, pageUrl).isEmpty ? raw : _abs(raw, pageUrl);
      if (!_fileLink.hasMatch(href)) continue;
      final noQuery = href.split('?').first;
      final dot = noQuery.lastIndexOf('.');
      final ext = dot < 0 ? '' : noQuery.substring(dot + 1).toLowerCase();
      if (_knownFormats.contains(ext)) out.putIfAbsent(ext, () => href);
    }
    return out;
  }

  /// The preferred format's file, falling back to MP3 and then any audio
  /// file.
  static String? pickFile(Map<String, String> files, KhFormat preferred) =>
      files[preferred.extension] ??
      files['mp3'] ??
      (files.isEmpty ? null : files.values.first);

  static int? parseDuration(String text) {
    final parts = <int>[];
    for (final p in text.trim().split(':')) {
      final v = int.tryParse(p);
      if (v == null) return null;
      parts.add(v);
    }
    return switch (parts.length) {
      2 => parts[0] * 60 + parts[1],
      3 => parts[0] * 3600 + parts[1] * 60 + parts[2],
      _ => null,
    };
  }

  // -- Playback URIs ---------------------------------------------------------
  // A queued KHInsider track carries its *track page*, not the file URL:
  // the file link is read from the page when the player opens it, so the
  // FLAC/MP3 choice applies at play time and saved playlists never go stale.

  static const _uriPrefix = 'khinsider://track?page=';

  static String playbackUri(String pagePath) =>
      _uriPrefix + Uri.encodeComponent(pagePath);

  static bool isPlaybackUri(String? uri) =>
      uri != null && uri.startsWith(_uriPrefix);

  static String? pagePathOf(String playbackUri) {
    if (!isPlaybackUri(playbackUri)) return null;
    final raw = playbackUri.substring(_uriPrefix.length).split('&').first;
    try {
      final path = Uri.decodeComponent(raw);
      return path.startsWith('/') ? path : null;
    } catch (_) {
      return null;
    }
  }
}
