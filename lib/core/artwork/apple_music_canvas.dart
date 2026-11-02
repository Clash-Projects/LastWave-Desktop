import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import 'animated_artwork_service.dart';

/// Apple Music's motion artwork — animated sleeves exposed on the catalog API
/// as `editorialVideo`.
///
/// Scrapes an anonymous guest JWT from Apple Music Web Player bundles, queries
/// the AMP catalog search with `extend=editorialVideo`, ranks and validates
/// results against artist/title/album, and returns square/portrait HLS video
/// streams.
class AppleMusicCanvas {
  AppleMusicCanvas._();

  static const String _amp = 'https://amp-api.music.apple.com/v1/catalog';
  static const String _webPlayer = 'https://music.apple.com/us/browse';
  static const int _minScore = 12;
  static const int _tokenRetryMs = 30 * 60 * 1000;

  static const List<String> _editionWords = [
    'deluxe',
    'expanded',
    'remastered',
    'remix',
    'version',
    'edit',
    'mix',
    'bonus',
  ];

  static const List<String> _compilationMarkers = [
    'playlist',
    'set list',
    'essentials',
    'dj mix',
    'mixed',
    'apple music',
    "today's hits",
    'session',
  ];

  static String? _cachedToken;
  static int _tokenExpiresAtMs = 0;
  static int _retryTokenAfterMs = 0;
  static final Set<String> _rejected = <String>{};
  static Future<String?>? _tokenInFlight;

  static String get storefront {
    try {
      final parts = Platform.localeName.split(RegExp(r'[-_.]'));
      if (parts.length >= 2) {
        final country = parts[1].trim().toLowerCase();
        if (country.length == 2 && RegExp(r'^[a-z]{2}$').hasMatch(country)) {
          return country;
        }
      }
    } catch (_) {}
    return 'us';
  }

  /// Clears cached JWT state (used by unit tests).
  static void resetForTesting() {
    _cachedToken = null;
    _tokenExpiresAtMs = 0;
    _retryTokenAfterMs = 0;
    _rejected.clear();
    _tokenInFlight = null;
  }

  static Future<AnimatedArtwork?> search(
    Dio dio, {
    required String title,
    required String artist,
    String? album,
  }) async {
    final bearer = await _token(dio);
    if (bearer == null || bearer.isEmpty) return null;

    final primaryArtist = primaryCanvasArtist(artist);
    final queryArtist = primaryArtist.isNotEmpty ? primaryArtist : artist;
    final termBuf = StringBuffer();
    if (!title.toLowerCase().contains(queryArtist.toLowerCase())) {
      termBuf
        ..write(queryArtist)
        ..write(' ');
    }
    termBuf.write(title);
    if (album != null &&
        album.trim().isNotEmpty &&
        !title.toLowerCase().contains(album.toLowerCase())) {
      termBuf
        ..write(' ')
        ..write(album);
    }

    final root = await _getJson(
      dio,
      '$_amp/$storefront/search',
      bearer: bearer,
      queryParameters: {
        'term': termBuf.toString(),
        'types': 'songs',
        'limit': '10',
        'extend': 'editorialVideo',
        'include': 'albums',
      },
    );
    if (root == null) return null;

    final results = root['results'];
    final songs = results is Map ? results['songs'] : null;
    final hits = songs is Map ? songs['data'] : null;
    if (hits is! List) return null;

    final ranked = <({int score, Map<String, dynamic> song})>[];
    for (final hit in hits) {
      if (hit is! Map) continue;
      final song = Map<String, dynamic>.from(hit);
      final s = _score(song, title, artist, album);
      if (s != null) {
        ranked.add((score: s, song: song));
      }
    }
    ranked.sort((a, b) => b.score.compareTo(a.score));

    for (final entry in ranked) {
      if (entry.score < _minScore) break;
      final song = entry.song;
      final attributes = song['attributes'];
      if (attributes is! Map) continue;

      final songName = attributes['name']?.toString();
      final songArtist = attributes['artistName']?.toString();
      final albumName = attributes['albumName']?.toString();

      final video = attributes['editorialVideo'];
      if (video is Map) {
        final urls = _motionUrls(video);
        if (urls != null) {
          return AnimatedArtwork(
            url: urls.primary,
            fallbackUrl: urls.alternate,
            urlTall: urls.tall ?? '',
            title: songName,
            artist: songArtist,
            album: albumName,
            source: CanvasSource.apple,
          );
        }
      }

      final id = _albumId(song);
      if (id == null) continue;
      final fromAlbum = await _fetchAlbum(
        dio,
        albumId: id,
        bearer: bearer,
        songTitle: songName,
        songArtist: songArtist,
      );
      if (fromAlbum != null) return fromAlbum;
    }
    return null;
  }

  static Future<AnimatedArtwork?> searchAlbum(
    Dio dio, {
    required String album,
    required String artist,
  }) async {
    final bearer = await _token(dio);
    if (bearer == null || bearer.isEmpty) return null;

    final primaryArtist = primaryCanvasArtist(artist);
    final queryArtist = primaryArtist.isNotEmpty ? primaryArtist : artist;
    final term = album.toLowerCase().contains(queryArtist.toLowerCase())
        ? album
        : '$queryArtist $album';

    final root = await _getJson(
      dio,
      '$_amp/$storefront/search',
      bearer: bearer,
      queryParameters: {
        'term': term,
        'types': 'albums',
        'limit': '10',
        'extend': 'editorialVideo',
      },
    );
    if (root == null) return null;

    final results = root['results'];
    final albums = results is Map ? results['albums'] : null;
    final hits = albums is Map ? albums['data'] : null;
    if (hits is! List) return null;

    final ranked = <({int score, Map<String, dynamic> record})>[];
    for (final hit in hits) {
      if (hit is! Map) continue;
      final record = Map<String, dynamic>.from(hit);
      final s = _score(record, album, artist, album, albumIsSelf: true);
      if (s != null) {
        ranked.add((score: s, record: record));
      }
    }
    ranked.sort((a, b) => b.score.compareTo(a.score));

    for (final entry in ranked) {
      if (entry.score < _minScore) break;
      final attributes = entry.record['attributes'];
      if (attributes is! Map) continue;
      final name = attributes['name']?.toString();
      if (name != null && _isCompilation(name)) continue;
      final video = attributes['editorialVideo'];
      if (video is! Map) continue;
      final urls = _motionUrls(video);
      if (urls == null) continue;

      return AnimatedArtwork(
        url: urls.primary,
        fallbackUrl: urls.alternate,
        urlTall: urls.tall ?? '',
        title: null,
        artist: attributes['artistName']?.toString(),
        album: name,
        source: CanvasSource.apple,
      );
    }
    return null;
  }

  static int? _score(
    Map<String, dynamic> song,
    String title,
    String artist,
    String? album, {
    bool albumIsSelf = false,
  }) {
    final attributes = song['attributes'];
    if (attributes is! Map) return null;
    final hitName = attributes['name']?.toString() ?? '';
    final hitArtist = attributes['artistName']?.toString() ?? '';
    final hitAlbum = albumIsSelf
        ? hitName
        : (attributes['albumName']?.toString() ?? '');

    if (_isCompilation(hitName) || _isCompilation(hitAlbum)) return null;

    if (!canvasArtistsMatch(
      artist,
      hitArtist,
      wantTitle: title,
      gotTitle: hitName,
    )) {
      return null;
    }

    var score = 10;

    final wantTitle = normalizeCanvasMatch(title);
    final hitTitle = normalizeCanvasMatch(hitName);
    if (hitTitle == wantTitle) {
      score += 15;
    } else if (canvasTitlesMatch(title, hitName)) {
      score += 7;
    } else {
      score -= 10;
    }

    if (album != null && album.trim().isNotEmpty && hitAlbum.trim().isNotEmpty) {
      final wantAlbum = normalizeCanvasMatch(album);
      final gotAlbum = normalizeCanvasMatch(hitAlbum);
      if (gotAlbum == wantAlbum) {
        score += 20;
      } else if (canvasTitlesMatch(album, hitAlbum)) {
        score += 10;
      }
    }

    final lowerTitle = title.toLowerCase();
    final lowerHit = hitName.toLowerCase();
    for (final word in _editionWords) {
      final inWanted = lowerTitle.contains(word);
      final inHit = lowerHit.contains(word);
      if (inWanted && inHit) {
        score += 5;
      } else if (inHit) {
        score -= 3;
      }
    }

    return score;
  }

  static bool _isCompilation(String name) {
    final lower = name.toLowerCase();
    return _compilationMarkers.any(lower.contains);
  }

  static String? _albumId(Map<String, dynamic> song) {
    final relationships = song['relationships'];
    final albums = relationships is Map ? relationships['albums'] : null;
    final data = albums is Map ? albums['data'] : null;
    if (data is List && data.isNotEmpty) {
      final first = data.first;
      final id = first is Map ? first['id']?.toString() : null;
      if (id != null && id.isNotEmpty && !id.startsWith('pl.')) {
        return id;
      }
    }

    final attributes = song['attributes'];
    final url = attributes is Map ? attributes['url']?.toString() : null;
    if (url == null || !url.contains('/album/')) return null;
    final afterAlbum = url.split('/album/').skip(1).join('/album/');
    final beforeQuery = afterAlbum.split('?').first;
    final lastSegment = beforeQuery.split('/').last.trim();
    if (lastSegment.isNotEmpty && RegExp(r'^\d+$').hasMatch(lastSegment)) {
      return lastSegment;
    }
    return null;
  }

  static Future<AnimatedArtwork?> _fetchAlbum(
    Dio dio, {
    required String albumId,
    required String bearer,
    String? songTitle,
    String? songArtist,
  }) async {
    final root = await _getJson(
      dio,
      '$_amp/$storefront/albums/$albumId',
      bearer: bearer,
      queryParameters: const {'extend': 'editorialVideo'},
    );
    if (root == null) return null;

    final data = root['data'];
    if (data is! List || data.isEmpty) return null;
    final album = data.first;
    if (album is! Map) return null;
    final attributes = album['attributes'];
    if (attributes is! Map) return null;

    final albumName = attributes['name']?.toString() ?? '';
    if (_isCompilation(albumName)) return null;

    final video = attributes['editorialVideo'];
    if (video is! Map) return null;
    final urls = _motionUrls(video);
    if (urls == null) return null;

    return AnimatedArtwork(
      url: urls.primary,
      fallbackUrl: urls.alternate,
      urlTall: urls.tall ?? '',
      title: songTitle,
      artist: songArtist ?? attributes['artistName']?.toString(),
      album: albumName,
      source: CanvasSource.apple,
    );
  }

  static ({String primary, String? alternate, String? tall})? _motionUrls(
    Map<dynamic, dynamic> video,
  ) {
    String? link(String key) {
      final asset = video[key];
      if (asset is! Map) return null;
      final raw = (asset['video'] ??
              asset['videoUrl'] ??
              asset['hlsUrl'] ??
              asset['url'])
          ?.toString()
          .trim();
      return (raw != null && raw.isNotEmpty) ? raw : null;
    }

    final square = link('motionDetailSquare') ?? link('motionSquareVideo1x1');
    final raw = link('motionDetailRaw');
    final tall = link('motionDetailTall') ?? link('motionTallVideo3x4');
    final primary = square ?? raw ?? tall;
    if (primary == null) return null;
    String? alternate;
    for (final candidate in [square, raw, tall]) {
      if (candidate != null && candidate != primary) {
        alternate = candidate;
        break;
      }
    }
    return (primary: primary, alternate: alternate, tall: tall);
  }

  static Future<String?> _token(Dio dio) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final cached = _cachedToken;
    if (cached != null && now < _tokenExpiresAtMs - 60000) {
      return Future.value(cached);
    }
    if (now < _retryTokenAfterMs) {
      return Future.value(null);
    }
    return _tokenInFlight ??= _scrapeToken(dio).whenComplete(() {
      _tokenInFlight = null;
    });
  }

  static Future<String?> _scrapeToken(Dio dio) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final cached = _cachedToken;
    if (cached != null && now < _tokenExpiresAtMs - 60000) {
      return cached;
    }
    if (now < _retryTokenAfterMs) return null;

    final html = await canvasGetText(
      dio,
      _webPlayer,
      headers: const {'User-Agent': canvasUserAgent},
    );
    final scripts = html == null
        ? const <String>[]
        : RegExp(r'/assets/index(?:-legacy)?[~-][A-Za-z0-9_-]+\.js')
            .allMatches(html)
            .map((m) => m.group(0)!)
            .toSet()
            .toList();

    final jwtRegex = RegExp(
      r'ey[A-Za-z0-9_-]+\.ey[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+',
    );

    for (final path in scripts) {
      final script = await canvasGetText(
        dio,
        'https://music.apple.com$path',
        headers: const {'User-Agent': canvasUserAgent},
      );
      if (script == null || script.isEmpty) continue;

      final seen = <String>{};
      final candidates = <({String jwt, int expiresAt})>[];
      for (final match in jwtRegex.allMatches(script)) {
        final jwt = match.group(0)!;
        if (!seen.add(jwt) || _rejected.contains(jwt)) continue;
        final exp = _expiry(jwt);
        if (exp != null && exp > now) {
          candidates.add((jwt: jwt, expiresAt: exp));
        }
      }
      if (candidates.isEmpty) continue;

      final chosen = candidates.firstWhere(
        (c) => _isWebPlayerToken(c.jwt),
        orElse: () => candidates.first,
      );
      _cachedToken = chosen.jwt;
      _tokenExpiresAtMs = chosen.expiresAt;
      return chosen.jwt;
    }

    _retryTokenAfterMs = now + _tokenRetryMs;
    return null;
  }

  static Future<Map<String, dynamic>?> _getJson(
    Dio dio,
    String url, {
    required String bearer,
    Map<String, dynamic>? queryParameters,
  }) async {
    try {
      final res = await dio.get<Object?>(
        url,
        queryParameters: queryParameters,
        options: Options(
          headers: _authHeaders(bearer),
          validateStatus: (code) => code != null && code < 500,
        ),
      );
      if (res.statusCode == 401) {
        _rejected.add(bearer);
        if (_cachedToken == bearer) {
          _cachedToken = null;
          _tokenExpiresAtMs = 0;
        }
        return null;
      }
      if (res.statusCode == null ||
          res.statusCode! < 200 ||
          res.statusCode! >= 300) {
        return null;
      }
      final data = res.data;
      if (data is Map) {
        return Map<String, dynamic>.from(data);
      }
      if (data is String && data.isNotEmpty) {
        final decoded = jsonDecode(data);
        if (decoded is Map) {
          return Map<String, dynamic>.from(decoded);
        }
      }
    } catch (_) {}
    return null;
  }

  static bool _isWebPlayerToken(String jwt) {
    try {
      final parts = jwt.split('.');
      if (parts.length < 2) return false;
      final header = utf8.decode(
        base64Url.decode(base64Url.normalize(parts[0])),
        allowMalformed: true,
      );
      final payload = utf8.decode(
        base64Url.decode(base64Url.normalize(parts[1])),
        allowMalformed: true,
      );
      return header.contains('WebPlayKid') || payload.contains('AMPWebPlay');
    } catch (_) {
      return false;
    }
  }

  static int? _expiry(String jwt) {
    try {
      final parts = jwt.split('.');
      if (parts.length < 2) return null;
      final payload = utf8.decode(
        base64Url.decode(base64Url.normalize(parts[1])),
        allowMalformed: true,
      );
      final match = RegExp(r'"exp"\s*:\s*(\d+)').firstMatch(payload);
      final seconds = int.tryParse(match?.group(1) ?? '');
      return seconds != null ? seconds * 1000 : null;
    } catch (_) {
      return null;
    }
  }

  static Map<String, String> _authHeaders(String bearer) => {
        'Authorization': 'Bearer $bearer',
        'Origin': 'https://music.apple.com',
        'Referer': 'https://music.apple.com/',
        'User-Agent': canvasUserAgent,
      };
}
