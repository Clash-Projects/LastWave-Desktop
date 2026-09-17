import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/app_database.dart';
import '../../features/innertube/innertube_api.dart';
import '../../features/search/shared_providers.dart';

class OfficialArtworkResult {
  final String artworkUrl;
  final String albumTitle;
  final String artist;
  final String title;

  const OfficialArtworkResult({
    required this.artworkUrl,
    this.albumTitle = '',
    this.artist = '',
    this.title = '',
  });
}

/// Scored album candidate from any catalog pass.
typedef _AlbumHit = ({int score, Map<String, dynamic> item});

/// Resolves official studio album artwork and album metadata from high-authority
/// music catalog CDNs (iTunes / Apple Music store catalog).
///
/// Bypasses YouTube 16:9 video frame stills and provides pristine square
/// 1400×1400 studio album covers for commercial music.
class OfficialArtworkService {
  static final OfficialArtworkService instance = OfficialArtworkService();

  final Dio _dio;
  AppDatabase? _db;
  final Map<String, OfficialArtworkResult> _cache = {};
  final Map<String, Future<OfficialArtworkResult?>> _inFlight = {};

  // Concurrency gate: a 30-row list view can trigger a burst of store
  // lookups at once; cap parallel network resolutions and queue the rest
  // so we never hammer the iTunes/Deezer search APIs. Artist lookups are
  // marked priority — artist circles otherwise wait behind dozens of
  // track lookups and visibly show album covers in the meantime.
  static const _maxParallel = 3;
  int _activeRequests = 0;
  final List<void Function()> _requestQueue = [];

  // Apple Search 403s after a burst. Two strikes → skip iTunes for a
  // while and use Deezer instead (and stop the console flood).
  int _itunes403Streak = 0;
  int _itunesSkipUntilMs = 0;
  bool get _itunesOpen =>
      DateTime.now().millisecondsSinceEpoch >= _itunesSkipUntilMs;

  final List<void Function()> _listeners = [];

  void addListener(void Function() listener) => _listeners.add(listener);
  void removeListener(void Function() listener) =>
      _listeners.remove(listener);
  void _notify() {
    for (final l in List<void Function()>.of(_listeners)) {
      l();
    }
  }

  String _trackCacheKey(String artist, String title) =>
      't4|${normalizeForSearch(artist)}|${normalizeForSearch(title)}';

  String _albumCacheKey(String artist, String album) =>
      'album2|${normalizeForSearch(artist)}|${normalizeForSearch(album)}';

  /// Seed the cache with a known-good studio cover (Qobuz/lossless
  /// playback) so Home tiles can reuse it without another store lookup.
  void rememberTrack({
    required String title,
    required String artist,
    required String artworkUrl,
    String album = '',
  }) {
    if (!isOfficialArtwork(artworkUrl)) return;
    if (normalizeForSearch(title).isEmpty) return;
    final key = _trackCacheKey(artist, title);
    final result = OfficialArtworkResult(
      artworkUrl: artworkUrl,
      albumTitle: album,
      artist: artist,
      title: title,
    );
    final changed = _cache[key]?.artworkUrl != artworkUrl;
    _cache[key] = result;
    _db?.saveArtworkEntry(
        cacheKey: key, url: artworkUrl, provider: 'remember');
    if (changed) _notify();
  }

  OfficialArtworkResult? peekTrack({
    required String title,
    required String artist,
  }) {
    if (normalizeForSearch(title).isEmpty) return null;
    return _cache[_trackCacheKey(artist, title)];
  }

  Future<T> _throttle<T>(Future<T> Function() task, {bool priority = false}) {
    final completer = Completer<T>();
    void run() {
      _activeRequests++;
      task().then(completer.complete).catchError(completer.completeError)
          .whenComplete(() {
        _activeRequests--;
        if (_requestQueue.isNotEmpty) {
          _requestQueue.removeAt(0)();
        }
      });
    }

    if (_activeRequests < _maxParallel) {
      run();
    } else if (priority) {
      _requestQueue.insert(0, run);
    } else {
      _requestQueue.add(run);
    }
    return completer.future;
  }

  OfficialArtworkService([Dio? dio, AppDatabase? db, InnerTubeMusicApi? tube])
      : _dio = dio ?? _createArtworkDio(),
        _db = db;

  /// Dedicated client: no debug 403 logger, 4xx does not throw, browser
  /// UA without the LastWave token (Apple Search 403s that).
  static Dio _createArtworkDio() {
    return Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 8),
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36',
          'Accept': '*/*',
          'Accept-Language': 'en-US,en;q=0.9',
        },
        validateStatus: (code) => code != null && code < 500,
      ),
    );
  }

  void init({AppDatabase? db, InnerTubeMusicApi? tube}) {
    if (db != null) _db = db;
  }

  static const _officialCdns = [
    'mzstatic.com',
    'apple.com',
    'qobuz.com',
    'scdn.co',
    'spotifycdn.com',
    'deezer.com',
    'dzcdn.net',
  ];

  static const _youtubeCdns = [
    'ytimg.com',
    'googleusercontent.com',
    'ggpht.com',
  ];

  /// Checks whether a URL is already an official studio release image
  /// (as opposed to a YouTube video frame thumbnail or placeholder).
  static bool isOfficialArtwork(String url) {
    if (url.isEmpty) return false;
    try {
      final host = Uri.parse(url).host.toLowerCase();
      if (_youtubeCdns.any((d) => host == d || host.endsWith('.$d'))) {
        return false;
      }
      return _officialCdns.any((d) => host == d || host.endsWith('.$d'));
    } catch (_) {
      return false;
    }
  }

  /// True only for a Deezer *artist* press photo — not an album cover
  /// that happens to live on an official CDN (iTunes mzstatic, Qobuz,
  /// Spotify, Deezer `/images/cover/`). Artist circles must never treat
  /// a studio album sleeve as "already official".
  static bool isOfficialArtistPhoto(String url) {
    if (url.isEmpty) return false;
    try {
      final uri = Uri.parse(url);
      final host = uri.host.toLowerCase();
      final path = uri.path.toLowerCase();
      final deezer = host == 'deezer.com' ||
          host.endsWith('.deezer.com') ||
          host == 'dzcdn.net' ||
          host.endsWith('.dzcdn.net');
      if (!deezer) return false;
      return path.contains('/images/artist/') ||
          path.contains('/artist/');
    } catch (_) {
      return false;
    }
  }

  /// First billed artist in a credit string.
  ///
  /// "Drake, Future & Metro Boomin" → "Drake"
  /// "Tyler, The Creator" stays intact (comma + "the").
  static String primaryArtistName(String artist) {
    var s = artist.trim();
    if (s.isEmpty) return s;
    s = s
        .split(RegExp(
          r'\s+[(\[]?(?:feat\.?|ft\.?|featuring)\b',
          caseSensitive: false,
        ))
        .first
        .trim();
    if (RegExp(r',\s*(the|and)\b', caseSensitive: false).hasMatch(s) &&
        !s.contains(' & ')) {
      return s;
    }
    final cut = s.split(RegExp(r'\s*[,&]\s*')).first.trim();
    return cut.isNotEmpty ? cut : s;
  }

  /// Individual credits from a collab string, for artist shelves.
  static Iterable<String> splitArtistCredits(String artist) sync* {
    final s = artist.trim();
    if (s.isEmpty) return;
    final lower = s.toLowerCase();
    if (lower == 'unknown artist' || lower == 'various artists') {
      return;
    }
    if (RegExp(r',\s*(the|and)\b', caseSensitive: false).hasMatch(s) &&
        !s.contains(' & ')) {
      yield s;
      return;
    }
    if (RegExp(r'[,&]').hasMatch(s)) {
      for (final part in s.split(RegExp(r'\s*[,&]\s*'))) {
        final p = part.trim();
        if (p.isNotEmpty && p.toLowerCase() != 'the') yield p;
      }
      return;
    }
    yield s;
  }

  /// Clean title for store matching (strip video noise, feat. clauses, etc.).
  static String normalizeForSearch(String text) {
    var s = text.toLowerCase();
    // Apostrophes are REMOVED (not spaced): "can't" → "cant". Spacing
    // them out ("can t") makes iTunes tokenize "t" as a separate word
    // and return completely unrelated results.
    s = s.replaceAll(RegExp(r"['’ʼ`´]"), '');
    s = s.replaceAll(
        RegExp(
            r'\s*-\s*(?:official|video|audio|remaster|remastered|lyrics?).*$',
            caseSensitive: false),
        '');
    s = s.replaceAll(
        RegExp(
            r'\s*\([^)]*(?:feat|ft\.?|featuring|official|video|audio|remaster|visualizer|lyrics?)[^)]*\)',
            caseSensitive: false),
        '');
    s = s.replaceAll(
        RegExp(
            r'\s*\[[^\]]*(?:feat|ft\.?|featuring|official|video|audio|remaster|visualizer|lyrics?)[^\]]*\]',
            caseSensitive: false),
        '');
    s = s.replaceAll(RegExp(r'^\s*[\w&.\- ]+\s*-\s+'), '');
    s = s.replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ');
    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// Catalog billing aliases — iTunes often files a Madvillain track
  /// under "MF DOOM" (or the reverse). Token overlap is empty in those
  /// cases, so without this the exact title still fails the score bar
  /// and a YouTube still gets cached instead of the studio cover.
  static const _artistAliasGroups = <Set<String>>[
    {'madvillain', 'mf doom', 'mfdoom', 'doom', 'metal fingers'},
    {'jay z', 'jayz', 'jigga', 'shawn carter'},
    {'kanye west', 'ye', 'yeezy'},
    {'the weeknd', 'weeknd'},
  ];

  static bool _artistsAliased(String a, String b) {
    if (a.isEmpty || b.isEmpty) return false;
    if (a == b) return true;
    for (final g in _artistAliasGroups) {
      if (g.contains(a) && g.contains(b)) return true;
    }
    return false;
  }

  /// Shared memory-cache + SQLite-cache + in-flight-dedup + throttled
  /// execution wrapper for every resolver below.
  Future<OfficialArtworkResult?> _cached(
    String cacheKey,
    String provider,
    Future<OfficialArtworkResult?> Function() resolve, {
    bool priority = false,
  }) async {
    if (_cache.containsKey(cacheKey)) {
      return _cache[cacheKey];
    }

    if (_db != null) {
      final dbEntry = _db!.loadArtworkEntry(cacheKey);
      if (dbEntry != null &&
          dbEntry['url'] != null &&
          dbEntry['url']!.isNotEmpty) {
        final url = dbEntry['url']!;
        // Old rows could store a YouTube video still as "official"
        // (InnerTube fallback). Those must not win over a real store
        // cover — ignore and re-resolve.
        if (isOfficialArtwork(url)) {
          final cached = OfficialArtworkResult(artworkUrl: url);
          _cache[cacheKey] = cached;
          return cached;
        }
      }
    }

    if (_inFlight.containsKey(cacheKey)) {
      return _inFlight[cacheKey];
    }

    final future = _throttle(resolve, priority: priority);
    _inFlight[cacheKey] = future;

    try {
      final result = await future;
      if (result != null) {
        if (!isOfficialArtwork(result.artworkUrl)) {
          return null;
        }
        _cache[cacheKey] = result;
        if (_cache.length > 500) {
          _cache.remove(_cache.keys.first);
        }
        if (_db != null && result.artworkUrl.isNotEmpty) {
          _db!.saveArtworkEntry(
            cacheKey: cacheKey,
            url: result.artworkUrl,
            provider: provider,
          );
        }
        _notify();
      }
      return result;
    } finally {
      _inFlight.remove(cacheKey);
    }
  }

  /// Resolve official album artwork and studio metadata for a track.
  Future<OfficialArtworkResult?> resolveOfficialArtwork({
    required String title,
    required String artist,
    String album = '',
  }) async {
    final cleanTitle = normalizeForSearch(title);
    final cleanArtist = normalizeForSearch(artist);
    if (cleanTitle.isEmpty) return null;

    // Cache keys are versioned: t1–t3 could store a different song's
    // sleeve (substring hits like Cider→Cinderella or Piranha→Pt. 2).
    // Those rows are abandoned rather than trusted.
    return _cached(
      _trackCacheKey(artist, title),
      'catalog',
      () => _doResolve(cleanTitle, cleanArtist, title, artist, album),
    );
  }

  /// Resolve the official cover for an ALBUM (not a track) via the
  /// iTunes album catalog — exact collection match beats track guessing.
  Future<OfficialArtworkResult?> resolveAlbumArtwork({
    required String album,
    required String artist,
  }) async {
    final cleanAlbum = normalizeForSearch(album);
    final cleanArtist = normalizeForSearch(artist);
    if (cleanAlbum.isEmpty) return null;

    return _cached(
      _albumCacheKey(artist, album),
      'catalog',
      () => _doResolveAlbum(cleanAlbum, cleanArtist, album, artist),
    );
  }

  /// Resolve an official ARTIST photo via the Deezer catalog — label-
  /// supplied press shots up to 1000×1000, no auth required. (iTunes has
  /// no artist images; Last.fm artist photos are crowd-sourced and often
  /// wrong, which is exactly what this replaces.)
  Future<OfficialArtworkResult?> resolveArtistArtwork(String artist) async {
    final primary = primaryArtistName(artist);
    final clean = normalizeForSearch(primary);
    if (clean.isEmpty) return null;

    // Key versioned: v1 entries could hold impostor acts picked before
    // the nb_fan (most-followed) selection existed; v2 used the raw
    // collab string ("drake future metro…") as the cache key.
    return _cached(
      'artist3|$clean',
      'deezer',
      () => _doResolveArtist(clean, primary),
      priority: true,
    );
  }

  /// Shared iTunes Search API round; returns the raw result list.
  /// 403/429 do not throw (validateStatus). After a couple of blocks
  /// we skip iTunes for 15 minutes so Home doesn't hammer Apple.
  Future<List<Map<String, dynamic>>> _itunesSearch(
    String term,
    String entity,
    String limit,
  ) async {
    if (!_itunesOpen) return const [];
    try {
      final res = await _dio.get<dynamic>(
        'https://itunes.apple.com/search',
        queryParameters: {
          'term': term,
          'entity': entity,
          'limit': limit,
          'media': 'music',
          'country': 'us',
        },
        options: Options(responseType: ResponseType.plain),
      );
      final code = res.statusCode ?? 0;
      if (code == 403 || code == 429) {
        _itunes403Streak++;
        if (_itunes403Streak >= 2) {
          _itunesSkipUntilMs = DateTime.now().millisecondsSinceEpoch +
              const Duration(minutes: 15).inMilliseconds;
        }
        return const [];
      }
      if (code != 200) return const [];
      _itunes403Streak = 0;
      dynamic rawData = res.data;
      if (rawData is String && rawData.isNotEmpty) {
        try {
          rawData = jsonDecode(rawData);
        } catch (_) {}
      }
      final data = rawData is Map ? rawData : null;
      if (data != null && data['results'] is List) {
        return (data['results'] as List)
            .whereType<Map<String, dynamic>>()
            .toList();
      }
    } catch (_) {}
    return const [];
  }

  Future<List<Map<String, dynamic>>> _deezerTrackHits(String query) async {
    if (query.trim().isEmpty) return const [];
    try {
      final res = await _dio.get<dynamic>(
        'https://api.deezer.com/search',
        queryParameters: {'q': query.trim(), 'limit': '15'},
      );
      if (res.statusCode != 200) return const [];
      dynamic rawData = res.data;
      if (rawData is String && rawData.isNotEmpty) {
        try {
          rawData = jsonDecode(rawData);
        } catch (_) {}
      }
      final data = rawData is Map ? rawData : null;
      final items = data != null && data['data'] is List
          ? (data['data'] as List).whereType<Map<String, dynamic>>()
          : const <Map<String, dynamic>>[];
      // Shape as iTunes-like maps so _findBestMatch can score them.
      return items.map((item) {
        final artist = item['artist'];
        final album = item['album'];
        final cover = album is Map
            ? (album['cover_xl'] ?? album['cover_big'] ?? album['cover'])
                ?.toString() ??
                ''
            : '';
        return <String, dynamic>{
          'trackName': item['title']?.toString() ?? '',
          'artistName': artist is Map ? artist['name']?.toString() ?? '' : '',
          'collectionName':
              album is Map ? album['title']?.toString() ?? '' : '',
          'artworkUrl100': cover,
          'releaseDate': album is Map
              ? album['release_date']?.toString() ?? ''
              : '',
        };
      }).toList();
    } catch (_) {
      return const [];
    }
  }

  /// Album-catalog scoring: exact collection name > substring; artist
  /// equality bonus; karaoke/tribute/instrumental penalties.
  _AlbumHit? _matchAlbum(
    List<Map<String, dynamic>> items,
    String cleanAlbum,
    String cleanArtist,
  ) {
    Map<String, dynamic>? best;
    var bestScore = -999;
    for (final item in items) {
      final collection =
          normalizeForSearch(item['collectionName']?.toString() ?? '');
      final artistName =
          normalizeForSearch(item['artistName']?.toString() ?? '');
      if (collection.isEmpty) continue;
      final titleScore = artworkTitleScore(collection, cleanAlbum);
      if (titleScore < 90) continue;
      var score = titleScore;
      if (cleanArtist.isNotEmpty) {
        final artistScore = artworkArtistScore(artistName, cleanArtist);
        if (artistScore < 80) continue;
        score += artistScore;
      }
      if (artistName.contains('karaoke') ||
          artistName.contains('tribute') ||
          artistName.contains('cover band') ||
          collection.contains('instrumental') ||
          collection.contains('karaoke')) {
        score -= 80;
      }
      if (score > bestScore) {
        bestScore = score;
        best = item;
      }
    }
    if (best == null || bestScore < 60) return null;
    return (score: bestScore, item: best);
  }

  /// Album resolution via its TRACKS: iTunes song search matches across
  /// collection names, and every track payload carries its album cover.
  /// Finds albums the album-entity ranking buries (even IGOR isn't in
  /// Tyler's top album hits) or that are missing from album search
  /// entirely (Madvillainy). Artist support is mandatory here.
  _AlbumHit? _matchAlbumViaSongs(
    List<Map<String, dynamic>> items,
    String cleanAlbum,
    String cleanArtist,
  ) {
    Map<String, dynamic>? best;
    var bestScore = -999;
    for (final item in items) {
      final collection =
          normalizeForSearch(item['collectionName']?.toString() ?? '');
      final artistName =
          normalizeForSearch(item['artistName']?.toString() ?? '');
      if (collection.isEmpty) continue;
      final titleScore = artworkTitleScore(collection, cleanAlbum);
      if (titleScore < 90) continue;
      final artistScore = artworkArtistScore(artistName, cleanArtist);
      if (artistScore < 80) continue;
      var score = titleScore + artistScore;
      final trackName =
          normalizeForSearch(item['trackName']?.toString() ?? '');
      final noise = '$trackName $collection';
      if (noise.contains('instrumental') ||
          noise.contains('karaoke') ||
          noise.contains('tribute')) {
        score -= 80;
      }
      if (score > bestScore) {
        bestScore = score;
        best = item;
      }
    }
    if (best == null || bestScore < 150) return null;
    return (score: bestScore, item: best);
  }

  OfficialArtworkResult? _albumResultFrom(
    Map<String, dynamic> item,
    String rawAlbum,
    String rawArtist,
  ) {
    final rawArt = item['artworkUrl100']?.toString() ?? '';
    if (rawArt.isEmpty) return null;
    return OfficialArtworkResult(
      artworkUrl:
          rawArt.replaceAll(RegExp(r'\d+x\d+bb'), '1400x1400bb'),
      albumTitle: item['collectionName']?.toString() ?? rawAlbum,
      artist: item['artistName']?.toString() ?? rawArtist,
    );
  }

  Future<OfficialArtworkResult?> _doResolveAlbum(
    String cleanAlbum,
    String cleanArtist,
    String rawAlbum,
    String rawArtist,
  ) async {
    // Gather candidates from every catalog pass, then take the GLOBAL
    // best — an early substring hit (a fan EP like "Whole Lotta Red V1")
    // must never beat an exact-album hit from the song pass.
    final hits = <_AlbumHit>[];

    // Pass 1 & 2: album catalog — "artist album", then bare album title.
    for (final term in {
      if (cleanArtist.isNotEmpty) '$cleanArtist $cleanAlbum',
      cleanAlbum,
    }) {
      final hit = _matchAlbum(
          await _itunesSearch(term, 'album', '25'), cleanAlbum, cleanArtist);
      if (hit != null) hits.add(hit);
    }

    // Pass 3: via the album's tracks (song search matches collection
    // names; each track payload carries the album cover).
    if (cleanArtist.isNotEmpty) {
      final hit = _matchAlbumViaSongs(
        await _itunesSearch('$cleanArtist $cleanAlbum', 'song', '25'),
        cleanAlbum,
        cleanArtist,
      );
      if (hit != null) hits.add(hit);
    }

    if (hits.isNotEmpty) {
      hits.sort((a, b) => b.score.compareTo(a.score));
      final result = _albumResultFrom(hits.first.item, rawAlbum, rawArtist);
      if (result != null) return result;
    }

    // Deezer album catalog when iTunes is 403'd or empty.
    try {
      final q = cleanArtist.isNotEmpty
          ? '$cleanArtist $cleanAlbum'
          : cleanAlbum;
      final res = await _dio.get<dynamic>(
        'https://api.deezer.com/search/album',
        queryParameters: {'q': q, 'limit': '10'},
      );
      if (res.statusCode == 200) {
        dynamic rawData = res.data;
        if (rawData is String && rawData.isNotEmpty) {
          try {
            rawData = jsonDecode(rawData);
          } catch (_) {}
        }
        final data = rawData is Map ? rawData : null;
        final items = data != null && data['data'] is List
            ? (data['data'] as List).whereType<Map<String, dynamic>>()
            : const <Map<String, dynamic>>[];
        final mapped = items
            .map((item) {
              final artist = item['artist'];
              return <String, dynamic>{
                'collectionName': item['title']?.toString() ?? '',
                'artistName':
                    artist is Map ? artist['name']?.toString() ?? '' : '',
                'artworkUrl100': (item['cover_xl'] ??
                        item['cover_big'] ??
                        item['cover'])
                    ?.toString() ??
                    '',
              };
            })
            .toList();
        final hit = _matchAlbum(mapped, cleanAlbum, cleanArtist);
        if (hit != null) {
          final result =
              _albumResultFrom(hit.item, rawAlbum, rawArtist);
          if (result != null) return result;
        }
      }
    } catch (_) {}

    return null;
  }

  Future<OfficialArtworkResult?> _doResolveArtist(
    String clean,
    String raw,
  ) async {
    try {
      final res = await _dio.get<dynamic>(
        'https://api.deezer.com/search/artist',
        queryParameters: {'q': clean, 'limit': '10'},
      );
      dynamic rawData = res.data;
      if (rawData is String && rawData.isNotEmpty) {
        try {
          rawData = jsonDecode(rawData);
        } catch (_) {}
      }
      final data = rawData is Map ? rawData : null;
      final items = data != null && data['data'] is List
          ? (data['data'] as List)
              .whereType<Map<String, dynamic>>()
              .toList()
          : <Map<String, dynamic>>[];
      if (items.isNotEmpty) {
        // Deezer ranks keyword-spam and tribute acts above real artists
        // (searching "drake" returns three fake "Drake" acts with a few
        // hundred fans above the real one with millions). Among exact
        // name matches, the REAL artist is virtually always the most
        // followed — pick by nb_fan, falling back to the overall most
        // popular result when no name matches exactly.
        Map<String, dynamic>? best;
        var bestFans = -1;
        Map<String, dynamic>? mostPopular;
        var mostFans = -1;
        for (final item in items) {
          final fans = (item['nb_fan'] as num?)?.toInt() ?? 0;
          if (fans > mostFans) {
            mostFans = fans;
            mostPopular = item;
          }
          final name = normalizeForSearch(item['name']?.toString() ?? '');
          if (name.isEmpty) continue;
          if (name == clean && fans > bestFans) {
            bestFans = fans;
            best = item;
          }
        }
        // Contains match as fallback: "madvillain" vs a longer billing,
        // or a slightly punctuated catalog name. Prefer the most-followed
        // contains-match only when no exact name hit exists.
        if (best == null) {
          var containFans = -1;
          for (final item in items) {
            final fans = (item['nb_fan'] as num?)?.toInt() ?? 0;
            final name =
                normalizeForSearch(item['name']?.toString() ?? '');
            if (name.isEmpty) continue;
            if (name.length >= 4 &&
                clean.length >= 4 &&
                (name.contains(clean) || clean.contains(name)) &&
                fans > containFans) {
              containFans = fans;
              best = item;
            }
          }
        }
        best ??= mostPopular ?? items.first;
        final pic = [
          best['picture_xl'],
          best['picture_big'],
          best['picture_medium'],
        ].map((e) => e?.toString() ?? '').firstWhere(
              (e) => e.isNotEmpty,
              orElse: () => '',
            );
        if (pic.isNotEmpty) {
          return OfficialArtworkResult(
            artworkUrl: pic,
            artist: best['name']?.toString() ?? raw,
          );
        }
      }
    } catch (_) {}
    return null;
  }

  Future<OfficialArtworkResult?> _doResolve(
    String cleanTitle,
    String cleanArtist,
    String rawTitle,
    String rawArtist,
    String rawAlbum,
  ) async {
    // Query iTunes and Deezer together, then pick the GLOBAL best.
    // Returning from the first iTunes substring hit used to skip the
    // real sleeve sitting in Deezer (Piranha vs Piranha Pt. 2).
    final catalogs = await Future.wait([
      if (cleanArtist.isNotEmpty)
        _itunesSearch('$cleanArtist $cleanTitle', 'song', '25'),
      _itunesSearch(cleanTitle, 'song', '25'),
      if (rawArtist.isNotEmpty) _deezerTrackHits('$rawArtist $rawTitle'),
      _deezerTrackHits(rawTitle),
    ]);
    final match = _findBestMatch(
      catalogs.expand((e) => e).toList(),
      cleanTitle,
      cleanArtist,
    );
    if (match != null) {
      final rawArt = match['artworkUrl100']?.toString() ??
          match['artworkUrl60']?.toString() ??
          '';
      if (rawArt.isNotEmpty) {
        final highResArt = rawArt.contains('mzstatic.com') ||
                rawArt.contains('apple.com')
            ? rawArt.replaceAll(RegExp(r'\d+x\d+bb'), '1400x1400bb')
            : rawArt;
        return OfficialArtworkResult(
          artworkUrl: highResArt,
          albumTitle: match['collectionName']?.toString() ?? rawAlbum,
          artist: match['artistName']?.toString() ?? rawArtist,
          title: match['trackName']?.toString() ?? rawTitle,
        );
      }
    }

    // Fallback: album-catalog search when the album title is known.
    if (rawAlbum.isNotEmpty && cleanArtist.isNotEmpty) {
      final albumMatch = await _doResolveAlbum(
        normalizeForSearch(rawAlbum),
        cleanArtist,
        rawAlbum,
        rawArtist,
      );
      if (albumMatch != null) {
        return OfficialArtworkResult(
          artworkUrl: albumMatch.artworkUrl,
          albumTitle: albumMatch.albumTitle,
          artist: albumMatch.artist,
          title: rawTitle,
        );
      }
    }

    // Do NOT fall back to YouTube Music artwork here. InnerTube thumbs
    // are video stills (the "All Caps" mixer frame) and used to get
    // cached as "official", which then blocked the real studio cover
    // on Home while Now Playing showed the lossless album sleeve.
    return null;
  }

  static const _artistStopwords = {
    'the', 'a', 'an', 'and', 'of', 'feat', 'ft', 'with', 'x',
  };

  static Set<String> _nameTokens(String s) => s
      .split(' ')
      .where((t) => t.length > 1 && !_artistStopwords.contains(t))
      .toSet();

  /// Title score for store artwork. No substring contains — that is
  /// how "Cider" stole Cinderella and "Piranha" stole Piranha Pt. 2.
  static int artworkTitleScore(String candidate, String target) {
    final a = normalizeForSearch(candidate);
    final b = normalizeForSearch(target);
    if (a.isEmpty || b.isEmpty) return 0;
    if (a == b) return 100;
    if (_isNearTypo(a, b)) return 90;
    final ta = _nameTokens(a);
    final tb = _nameTokens(b);
    if (ta.isEmpty || tb.isEmpty) return 0;
    final common = ta.intersection(tb).length;
    if (common == 0) return 0;
    final dice = (200 * common) ~/ (ta.length + tb.length);
    return dice >= 92 ? 90 : 0;
  }

  /// Artist score for store artwork. Token equality / subset only —
  /// string contains would accept "zane" inside "zany inzane".
  static int artworkArtistScore(String candidate, String target) {
    final a = normalizeForSearch(candidate);
    final b = normalizeForSearch(target);
    if (a.isEmpty || b.isEmpty) return 0;
    if (a == b || _artistsAliased(a, b)) return 100;
    final ta = _nameTokens(a);
    final tb = _nameTokens(b);
    if (ta.isEmpty || tb.isEmpty) return 0;
    if (ta.containsAll(tb) || tb.containsAll(ta)) {
      final shorter = ta.length <= tb.length ? ta : tb;
      if (shorter.length >= 2 || shorter.every((t) => t.length >= 3)) {
        return 80;
      }
    }
    return 0;
  }

  /// One-edit / adjacent-transposition typo for titles long enough
  /// that "Cider"/"Coder" will not collide.
  static bool _isNearTypo(String a, String b) {
    if (a.length < 6 || b.length < 6) return false;
    final la = a.length;
    final lb = b.length;
    if ((la - lb).abs() > 1) return false;
    if (la == lb) {
      var diffs = 0;
      var first = -1;
      for (var i = 0; i < la; i++) {
        if (a[i] == b[i]) continue;
        diffs++;
        if (diffs == 1) {
          first = i;
        } else if (diffs == 2 &&
            first == i - 1 &&
            a[first] == b[i] &&
            a[i] == b[first]) {
          return true;
        } else {
          return false;
        }
      }
      return diffs <= 1;
    }
    final longer = la > lb ? a : b;
    final shorter = la > lb ? b : a;
    var i = 0;
    var j = 0;
    var skipped = 0;
    while (i < longer.length && j < shorter.length) {
      if (longer[i] == shorter[j]) {
        i++;
        j++;
      } else {
        skipped++;
        if (skipped > 1) return false;
        i++;
      }
    }
    return true;
  }

  /// Public scorer used by tests and [_findBestMatch].
  static Map<String, dynamic>? pickBestTrackArtwork(
    List<Map<String, dynamic>> items, {
    required String title,
    required String artist,
  }) =>
      _findBestMatch(
        items,
        normalizeForSearch(title),
        normalizeForSearch(artist),
      );

  static Map<String, dynamic>? _findBestMatch(
    List<Map<String, dynamic>> items,
    String targetTitle,
    String targetArtist,
  ) {
    if (items.isEmpty || targetTitle.isEmpty || targetArtist.isEmpty) {
      return null;
    }

    final accepted = <(int, DateTime?, Map<String, dynamic>)>[];

    for (final item in items) {
      final rawArtistName = item['artistName']?.toString() ?? '';
      final trackName = item['trackName']?.toString() ?? '';
      final collection =
          normalizeForSearch(item['collectionName']?.toString() ?? '');
      final collectionArtist =
          normalizeForSearch(item['collectionArtistName']?.toString() ?? '');
      final titleScore = artworkTitleScore(trackName, targetTitle);
      if (titleScore < 90) continue;
      final artistScore = artworkArtistScore(rawArtistName, targetArtist);
      if (artistScore < 80) continue;

      var score = titleScore + artistScore;

      final noise = '${normalizeForSearch(trackName)} $collection';
      if (!targetTitle.contains('instrumental') &&
          (noise.contains('instrumental') ||
              noise.contains('karaoke') ||
              noise.contains('tribute') ||
              noise.contains('cover version') ||
              noise.contains('made famous'))) {
        score -= 80;
      }

      final looksLikeCompilation = collectionArtist == 'various artists' ||
          collection.contains('greatest hits') ||
          collection.contains('best of') ||
          collection.contains('essential') ||
          collection.contains('anthology') ||
          collection.contains('various');
      if (looksLikeCompilation) score -= 60;

      if (collection.endsWith(' single')) score -= 15;

      if (score >= 170) {
        DateTime? released;
        try {
          released = DateTime.parse(item['releaseDate']?.toString() ?? '');
        } catch (_) {}
        accepted.add((score, released, item));
      }
    }

    if (accepted.isEmpty) return null;
    // Highest score wins; ties broken by earliest release (the original
    // studio album predates compilations, remasters and reissues).
    accepted.sort((a, b) {
      final s = b.$1.compareTo(a.$1);
      if (s != 0) return s;
      final ad = a.$2, bd = b.$2;
      if (ad != null && bd != null) return ad.compareTo(bd);
      if (ad != null) return -1;
      if (bd != null) return 1;
      return 0;
    });
    return accepted.first.$3;
  }
}

final officialArtworkServiceProvider =
    Provider<OfficialArtworkService>((ref) {
  final db = ref.watch(databaseProvider);
  final tube = ref.watch(innerTubeProvider);
  final service = OfficialArtworkService.instance;
  service.init(db: db, tube: tube);
  return service;
});
