import 'podcast_models.dart';

/// Parsers for WEB_REMIX podcast browse and search payloads.
///
/// Port of LastWave Native `PodcastParser`. Episode order is YouTube's.
class PodcastParser {
  static const episodeSearchFilter =
      'EgWKAQJIAWoSEBEQAxAQEAUQChAOEAkQBBAV';

  static List<PodcastShelf> parseHome(Object? root) {
    final carousels = <Map<String, dynamic>>[];
    _collect(root, 'musicCarouselShelfRenderer', carousels);
    final shelves = <PodcastShelf>[];
    for (final carousel in carousels) {
      final title = _shelfTitle(carousel);
      if (title == null || title.isEmpty) continue;
      final showRenderers = <Map<String, dynamic>>[];
      _collect(carousel, 'musicTwoRowItemRenderer', showRenderers);
      final shows = showRenderers
          .map(parseShowCard)
          .whereType<PodcastShow>()
          .fold<List<PodcastShow>>([], (list, show) {
        if (list.every((s) => s.showId != show.showId)) list.add(show);
        return list;
      });
      final episodes = _parseEpisodeRenderers(carousel);
      if (shows.isEmpty && episodes.isEmpty) continue;
      shelves.add(PodcastShelf(
        title: title,
        shows: shows,
        episodes: episodes,
      ));
    }
    if (shelves.isNotEmpty) return shelves;

    final fallbackShows = <Map<String, dynamic>>[];
    _collect(root, 'musicTwoRowItemRenderer', fallbackShows);
    final parsed = fallbackShows
        .map(parseShowCard)
        .whereType<PodcastShow>()
        .fold<List<PodcastShow>>([], (list, show) {
      if (list.every((s) => s.showId != show.showId)) list.add(show);
      return list;
    });
    if (parsed.isNotEmpty) {
      return [PodcastShelf(title: 'Podcasts', shows: parsed)];
    }
    final episodes = _parseEpisodeRenderers(root);
    if (episodes.isEmpty) return const [];
    return [PodcastShelf(title: 'Podcasts', episodes: episodes)];
  }

  static PodcastShowPage parseShow(
    Object? root,
    String showId, {
    String fallbackTitle = '',
  }) {
    final headers = <Map<String, dynamic>>[];
    _collect(root, 'musicResponsiveHeaderRenderer', headers);
    if (headers.isEmpty) {
      _collect(root, 'musicDetailHeaderRenderer', headers);
    }
    if (headers.isEmpty) {
      _collect(root, 'musicImmersiveHeaderRenderer', headers);
    }
    final header = headers.isEmpty ? null : headers.first;
    final title = (header == null ? '' : (_titleText(header) ?? '')).trim();
    final resolvedTitle = title.isNotEmpty
        ? title
        : (fallbackTitle.isNotEmpty ? fallbackTitle : 'Podcast');
    final episodes = _parseEpisodeRenderers(root)
        .map((episode) => episode.copyWith(
              showId: episode.showId.isEmpty ? showId : episode.showId,
              showTitle:
                  episode.showTitle.isEmpty ? resolvedTitle : episode.showTitle,
            ))
        .toList();
    return PodcastShowPage(
      show: PodcastShow(
        showId: showId,
        title: resolvedTitle,
        publisher: header == null
            ? ''
            : (_textOf(header['subtitle']) ?? ''),
        description: header == null
            ? ''
            : (_textOf(header['description']) ??
                _textOf(header['descriptionText']) ??
                ''),
        artworkUrl: header == null ? '' : (_artworkUrl(header) ?? ''),
      ),
      episodes: episodes,
      continuation: _episodeContinuation(root),
    );
  }

  static PodcastEpisodePage parseEpisodeContinuation(
    Object? root, {
    String? showId,
    String? showTitle,
  }) {
    return PodcastEpisodePage(
      episodes: _parseEpisodeRenderers(root)
          .map((episode) => episode.copyWith(
                showId: episode.showId.isEmpty ? showId : episode.showId,
                showTitle:
                    episode.showTitle.isEmpty ? showTitle : episode.showTitle,
              ))
          .toList(),
      continuation: _episodeContinuation(root),
    );
  }

  static List<PodcastEpisode> parseEpisodeSearch(
    Object? root, {
    bool requirePodcastMarker = false,
  }) {
    final renderers = <Map<String, dynamic>>[];
    _collect(root, 'musicResponsiveListItemRenderer', renderers);
    final out = <PodcastEpisode>[];
    final seen = <String>{};
    for (final renderer in renderers) {
      if (!_isEpisodeSearchRow(renderer, requirePodcastMarker)) continue;
      final episode = _parseResponsiveEpisode(renderer);
      if (episode == null || !seen.add(episode.videoId)) continue;
      out.add(episode);
    }
    return out;
  }

  /// Search `params` on the Episodes chip, used to retry a filtered query.
  static String? episodeSearchParams(Object? root) {
    final chips = <Map<String, dynamic>>[];
    _collect(root, 'chipCloudChipRenderer', chips);
    for (final chip in chips) {
      final label = (_textOf(chip['text']) ?? '').toLowerCase();
      if (!label.contains('episode')) continue;
      final params = _findString(chip, 'params');
      if (params != null && params.isNotEmpty) return params;
    }
    return null;
  }

  static PodcastShow? parseShowCard(Map<String, dynamic> renderer) {
    final showId = _firstWhere(
      _browseIds(renderer),
      (id) => id.startsWith('MPSPPL') || id.startsWith('MPED'),
    );
    if (showId == null) return null;
    final title = (_titleText(renderer) ?? '').trim();
    if (title.isEmpty) return null;
    return PodcastShow(
      showId: showId,
      title: title,
      publisher: _textOf(renderer['subtitle']) ?? '',
      artworkUrl: _artworkUrl(renderer) ?? '',
    );
  }

  static List<PodcastEpisode> _parseEpisodeRenderers(Object? root) {
    final multi = <Map<String, dynamic>>[];
    _collect(root, 'musicMultiRowListItemRenderer', multi);
    final episodes = <PodcastEpisode>[];
    final seen = <String>{};
    for (final renderer in multi) {
      final episode = _parseMultiRowEpisode(renderer);
      if (episode == null || !seen.add(episode.videoId)) continue;
      episodes.add(episode);
    }
    if (episodes.isEmpty) {
      final responsive = <Map<String, dynamic>>[];
      _collect(root, 'musicResponsiveListItemRenderer', responsive);
      for (final renderer in responsive) {
        if (!_isEpisodeSearchRow(renderer, false)) continue;
        final episode = _parseResponsiveEpisode(renderer);
        if (episode == null || !seen.add(episode.videoId)) continue;
        episodes.add(episode);
      }
    }
    return episodes.where((e) => e.videoId.isNotEmpty).toList();
  }

  static PodcastEpisode? _parseMultiRowEpisode(Map<String, dynamic> renderer) {
    final videoId = _episodeVideoId(renderer);
    final title = (_titleText(renderer) ?? '').trim();
    if (videoId == null || title.isEmpty) return null;
    final runs = renderer['subtitle'];
    final subtitle = _textOf(runs) ?? '';
    final meta = _episodeMeta(subtitle);
    final showId = _firstWhere(
      _browseIds(renderer),
      (id) => id.startsWith('MPSPPL'),
    );
    return PodcastEpisode(
      videoId: videoId,
      title: title,
      showId: showId ?? '',
      showTitle: meta.$2 ?? '',
      description: _textOf(renderer['description']) ?? '',
      artworkUrl: _artworkUrl(renderer) ?? '',
      durationMs: _durationMs(renderer) ?? 0,
      publishedLabel: meta.$1 ?? '',
    );
  }

  static PodcastEpisode? _parseResponsiveEpisode(
      Map<String, dynamic> renderer) {
    final videoId = _episodeVideoId(renderer);
    if (videoId == null) return null;
    final columns = renderer['flexColumns'];
    final title = (_columnText(columns, 0) ?? '').trim();
    if (title.isEmpty) return null;
    final meta = _episodeMeta(_columnText(columns, 1) ?? '');
    final showId = _firstWhere(
      _browseIds(renderer),
      (id) => id.startsWith('MPSPPL'),
    );
    return PodcastEpisode(
      videoId: videoId,
      title: title,
      showId: showId ?? '',
      showTitle: meta.$2 ?? '',
      artworkUrl: _artworkUrl(renderer) ?? '',
      durationMs: _durationMs(renderer) ?? 0,
      publishedLabel: meta.$1 ?? '',
    );
  }

  static bool _isEpisodeSearchRow(
    Map<String, dynamic> renderer,
    bool requirePodcastMarker,
  ) {
    if (_hasPodcastMarker(renderer)) return true;
    if (requirePodcastMarker) return false;
    final pageType = _findString(renderer, 'pageType');
    return pageType == null ||
        !pageType.toUpperCase().contains('PODCAST');
  }

  static bool _hasPodcastMarker(Map<String, dynamic> renderer) {
    final pageType = _findString(renderer, 'pageType');
    if (pageType != null && pageType.toUpperCase().contains('PODCAST')) {
      return true;
    }
    final videoType = _findString(renderer, 'videoType');
    if (videoType != null && videoType.toUpperCase().contains('PODCAST')) {
      return true;
    }
    if (_browseIds(renderer).any(
        (id) => id.startsWith('MPED') || id.startsWith('MPSPPL'))) {
      return true;
    }
    final subtitle = _columnText(renderer['flexColumns'], 1);
    if (subtitle != null && subtitle.toLowerCase().contains('podcast')) {
      return true;
    }
    return renderer.toString().toUpperCase().contains('PODCAST_EPISODE');
  }

  static String? _episodeVideoId(Map<String, dynamic> renderer) {
    String? from(Object? node) {
      if (node is! Map) return null;
      final watch = node['watchEndpoint'];
      if (watch is Map && watch['videoId'] is String) {
        final id = watch['videoId'] as String;
        if (id.isNotEmpty) return id;
      }
      return null;
    }

    final direct = from(renderer['onTap']) ??
        from(renderer['navigationEndpoint']) ??
        (renderer['playlistItemData'] is Map
            ? (renderer['playlistItemData'] as Map)['videoId']?.toString()
            : null) ??
        from(renderer['doubleTapCommand']);
    if (direct != null && direct.isNotEmpty) return direct;
    final columns = renderer['flexColumns'];
    if (columns is List) {
      for (final column in columns) {
        if (column is! Map) continue;
        final flex = column['musicResponsiveListItemFlexColumnRenderer'];
        if (flex is! Map) continue;
        final runs = (flex['text'] is Map)
            ? (flex['text'] as Map)['runs']
            : null;
        if (runs is! List) continue;
        for (final run in runs) {
          if (run is! Map) continue;
          final id = from(run['navigationEndpoint']);
          if (id != null && id.isNotEmpty) return id;
        }
      }
    }
    final found = _findString(renderer, 'videoId');
    if (found != null && found.length == 11) return found;
    return null;
  }

  static int? _durationMs(Map<String, dynamic> renderer) {
    final progress = renderer['playbackProgress'];
    if (progress is Map) {
      final inner = progress['musicPlaybackProgressRenderer'];
      if (inner is Map) {
        final clock = _parseClock(_textOf(inner['durationText']));
        if (clock != null) return clock;
      }
    }
    final length = _parseClock(_textOf(renderer['lengthText']));
    if (length != null) return length;
    final fixed = renderer['fixedColumns'];
    if (fixed is List) {
      for (final column in fixed) {
        if (column is! Map) continue;
        final inner = column['musicResponsiveListItemFixedColumnRenderer'];
        if (inner is! Map) continue;
        final text = inner['text'];
        if (text is Map && text['runs'] is List) {
          for (final run in text['runs'] as List) {
            final clock = _parseClock(_textOf(run));
            if (clock != null) return clock;
          }
        }
      }
    }
    return null;
  }

  static (String?, String?) _episodeMeta(String subtitle) {
    final segments = subtitle
        .split(RegExp('[•·]'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (segments.isEmpty) return (null, null);
    String? published;
    for (final segment in segments) {
      if (_isDateLabel(segment)) {
        published = segment;
        break;
      }
    }
    published ??= _firstWhere(segments, (s) => !_isStatSegment(s));
    String? show;
    for (final segment in segments.reversed) {
      if (segment == published) continue;
      if (_isStatSegment(segment) || _isDateLabel(segment)) continue;
      show = segment;
      break;
    }
    return (published, show);
  }

  static final _month = RegExp(
    r'\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)\b',
    caseSensitive: false,
  );
  static final _day = RegExp(r'\d{1,2}[/.]\d{1,2}[/.]\d{2,4}');
  static final _hours = RegExp(
    r'(\d+)\s*(?:h|hr|hrs|hour|hours)\s*(?:(\d+)\s*(?:m|min|mins|minute|minutes))?',
    caseSensitive: false,
  );
  static final _minutes = RegExp(
    r'(\d+)\s*(?:m|min|mins|minute|minutes)',
    caseSensitive: false,
  );

  static bool _isDateLabel(String value) =>
      value.toLowerCase().contains('ago') ||
      _month.hasMatch(value) ||
      _day.hasMatch(value);

  static bool _isStatSegment(String value) {
    final lower = value.toLowerCase();
    return lower.contains('view') ||
        lower.contains('play') ||
        lower.contains('listen') ||
        lower.contains('episode') ||
        lower.contains('min') ||
        lower.contains('hr') ||
        lower.contains('season') ||
        lower.contains('podcast');
  }

  static int? _parseClock(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final cleaned = value.trim();
    final colon = cleaned.split(':');
    if (colon.length >= 2 &&
        colon.length <= 3 &&
        colon.every((p) => int.tryParse(p.trim()) != null)) {
      var seconds = 0;
      for (final part in colon) {
        seconds = seconds * 60 + int.parse(part.trim());
      }
      if (seconds > 0) return seconds * 1000;
    }
    final hours = _hours.firstMatch(cleaned);
    if (hours != null && hours.start == 0 && hours.end == cleaned.length) {
      final h = int.tryParse(hours.group(1) ?? '') ?? 0;
      final m = int.tryParse(hours.group(2) ?? '') ?? 0;
      final total = h * 3600 + m * 60;
      if (total > 0) return total * 1000;
    }
    final minutes = _minutes.firstMatch(cleaned);
    if (minutes != null &&
        minutes.start == 0 &&
        minutes.end == cleaned.length) {
      final m = int.tryParse(minutes.group(1) ?? '') ?? 0;
      if (m > 0) return m * 60000;
    }
    return null;
  }

  static String? _episodeContinuation(Object? root) {
    final shelves = <Map<String, dynamic>>[];
    _collect(root, 'musicShelfRenderer', shelves);
    for (final shelf in shelves) {
      final multi = <Map<String, dynamic>>[];
      _collect(shelf, 'musicMultiRowListItemRenderer', multi);
      if (multi.isEmpty) continue;
      final token = _continuationIn(shelf);
      if (token != null) return token;
    }
    return _continuationIn(root);
  }

  static String? _continuationIn(Object? element) {
    final commands = <Map<String, dynamic>>[];
    _collect(element, 'continuationCommand', commands);
    for (final command in commands) {
      final token = command['token']?.toString();
      if (token != null && token.isNotEmpty) return token;
    }
    final legacy = <Map<String, dynamic>>[];
    _collect(element, 'nextContinuationData', legacy);
    for (final item in legacy) {
      final token = item['continuation']?.toString();
      if (token != null && token.isNotEmpty) return token;
    }
    return null;
  }

  static String? _columnText(Object? columns, int index) {
    if (columns is! List || index < 0 || index >= columns.length) {
      return null;
    }
    final column = columns[index];
    if (column is! Map) return null;
    final flex = column['musicResponsiveListItemFlexColumnRenderer'];
    if (flex is! Map) return null;
    return _textOf(flex['text']);
  }

  static String? _shelfTitle(Map<String, dynamic> element) {
    final direct = _textOf(element['title']);
    if (direct != null && direct.isNotEmpty) return direct;
    final header = element['header'];
    if (header is! Map) return null;
    for (final key in const [
      'musicCarouselShelfBasicHeaderRenderer',
      'musicShelfHeaderRenderer',
      'musicCardShelfHeaderBasicRenderer',
      'musicHeaderRenderer',
    ]) {
      final node = header[key];
      if (node is Map) {
        final text = _textOf(node['title']);
        if (text != null && text.isNotEmpty) return text;
      }
    }
    return null;
  }

  static String? _titleText(Map<String, dynamic> element) =>
      _textOf(element['title']) ?? _textOf(element['name']);

  static String? _textOf(Object? element) {
    if (element == null) return null;
    if (element is String) {
      return element.trim().isEmpty ? null : element;
    }
    if (element is! Map) return null;
    final runs = element['runs'];
    if (runs is List) {
      final text = runs.map((run) {
        if (run is Map) return run['text']?.toString() ?? '';
        if (run is String) return run;
        return '';
      }).join();
      if (text.trim().isNotEmpty) return text;
    }
    final simple = element['simpleText']?.toString();
    if (simple != null && simple.trim().isNotEmpty) return simple;
    return null;
  }

  static String? _artworkUrl(Object? element) {
    final arrays = <List<dynamic>>[];
    void walk(Object? node) {
      if (node is Map) {
        final thumbs = node['thumbnails'];
        if (thumbs is List && thumbs.isNotEmpty) arrays.add(thumbs);
        for (final child in node.values) {
          walk(child);
        }
      } else if (node is List) {
        for (final child in node) {
          walk(child);
        }
      }
    }

    walk(element);
    if (arrays.isEmpty) return null;
    final best = arrays.first;
    String? url;
    for (final item in best.reversed) {
      if (item is Map && item['url'] != null) {
        url = item['url'].toString();
        if (url.isNotEmpty) break;
      }
    }
    if (url == null || url.isEmpty) return null;
    final absolute = url.startsWith('//') ? 'https:$url' : url;
    if ((absolute.contains('googleusercontent.com') ||
            absolute.contains('ggpht.com')) &&
        absolute.contains('=')) {
      return '${absolute.substring(0, absolute.lastIndexOf('='))}=w512-h512-l90-rj';
    }
    return absolute;
  }

  static String? _firstWhere(
    Iterable<String> values,
    bool Function(String value) test,
  ) {
    for (final value in values) {
      if (test(value)) return value;
    }
    return null;
  }

  static List<String> _browseIds(Object? element) {
    final ids = <String>[];
    void walk(Object? node) {
      if (node is Map) {
        final id = node['browseId'];
        if (id is String && id.isNotEmpty) ids.add(id);
        for (final child in node.values) {
          walk(child);
        }
      } else if (node is List) {
        for (final child in node) {
          walk(child);
        }
      }
    }

    walk(element);
    return ids;
  }

  static String? _findString(Object? element, String key) {
    if (element is Map) {
      final direct = element[key];
      if (direct is String && direct.isNotEmpty) return direct;
      for (final child in element.values) {
        final found = _findString(child, key);
        if (found != null) return found;
      }
    } else if (element is List) {
      for (final child in element) {
        final found = _findString(child, key);
        if (found != null) return found;
      }
    }
    return null;
  }

  static void _collect(
    Object? element,
    String key,
    List<Map<String, dynamic>> out,
  ) {
    if (element is Map<String, dynamic>) {
      element.forEach((name, child) {
        if (name == key && child is Map<String, dynamic>) out.add(child);
        _collect(child, key, out);
      });
    } else if (element is Map) {
      element.forEach((name, child) {
        if (name == key && child is Map) {
          out.add(Map<String, dynamic>.from(child));
        }
        _collect(child, key, out);
      });
    } else if (element is List) {
      for (final child in element) {
        _collect(child, key, out);
      }
    }
  }
}
