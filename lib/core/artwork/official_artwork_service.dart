import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../network/dio_factory.dart';
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

/// Resolves official studio album artwork and album metadata from high-authority
/// music catalog CDNs (iTunes / Apple Music store catalog).
///
/// Bypasses YouTube 16:9 video frame stills and provides pristine square
/// 1400×1400 studio album covers for commercial music.
class OfficialArtworkService {
  static final OfficialArtworkService instance = OfficialArtworkService();

  final Dio _dio;
  AppDatabase? _db;
  InnerTubeMusicApi? _tube;
  final Map<String, OfficialArtworkResult> _cache = {};
  final Map<String, Future<OfficialArtworkResult?>> _inFlight = {};

  OfficialArtworkService([Dio? dio, AppDatabase? db, InnerTubeMusicApi? tube])
      : _dio = dio ??
            DioFactory.create()
              ..options.connectTimeout = const Duration(seconds: 8)
              ..options.receiveTimeout = const Duration(seconds: 8),
        _db = db,
        _tube = tube;

  void init({AppDatabase? db, InnerTubeMusicApi? tube}) {
    if (db != null) _db = db;
    if (tube != null) _tube = tube;
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

  /// Clean title for store matching (strip video noise, feat. clauses, etc.).
  static String normalizeForSearch(String text) {
    var s = text.toLowerCase();
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

  /// Resolve official album artwork and studio metadata for a track.
  Future<OfficialArtworkResult?> resolveOfficialArtwork({
    required String title,
    required String artist,
    String album = '',
  }) async {
    final cleanTitle = normalizeForSearch(title);
    final cleanArtist = normalizeForSearch(artist);
    if (cleanTitle.isEmpty) return null;

    final cacheKey = '$cleanArtist|$cleanTitle';
    if (_cache.containsKey(cacheKey)) {
      return _cache[cacheKey];
    }

    if (_db != null) {
      final dbEntry = _db!.loadArtworkEntry(cacheKey);
      if (dbEntry != null &&
          dbEntry['url'] != null &&
          dbEntry['url']!.isNotEmpty) {
        final cached = OfficialArtworkResult(
          artworkUrl: dbEntry['url']!,
          title: title,
          artist: artist,
          albumTitle: album,
        );
        _cache[cacheKey] = cached;
        return cached;
      }
    }

    if (_inFlight.containsKey(cacheKey)) {
      return _inFlight[cacheKey];
    }

    final future = _doResolve(cleanTitle, cleanArtist, title, artist, album);
    _inFlight[cacheKey] = future;

    try {
      final result = await future;
      if (result != null) {
        _cache[cacheKey] = result;
        if (_cache.length > 500) {
          _cache.remove(_cache.keys.first);
        }
        if (_db != null && result.artworkUrl.isNotEmpty) {
          _db!.saveArtworkEntry(
            cacheKey: cacheKey,
            url: result.artworkUrl,
            provider: isOfficialArtwork(result.artworkUrl) ? 'itunes' : 'innertube',
          );
        }
      }
      return result;
    } finally {
      _inFlight.remove(cacheKey);
    }
  }

  Future<OfficialArtworkResult?> _doResolve(
    String cleanTitle,
    String cleanArtist,
    String rawTitle,
    String rawArtist,
    String rawAlbum,
  ) async {
    // 1. Try iTunes Search API
    try {
      final query = cleanArtist.isNotEmpty
          ? '$cleanArtist $cleanTitle'
          : cleanTitle;

      final res = await _dio.get<dynamic>(
        'https://itunes.apple.com/search',
        queryParameters: {
          'term': query,
          'entity': 'song',
          'limit': '5',
        },
      );

      dynamic rawData = res.data;
      if (rawData is String && rawData.isNotEmpty) {
        try {
          rawData = jsonDecode(rawData);
        } catch (_) {}
      }
      final data = rawData is Map ? rawData : null;
      if (data != null && data['results'] is List) {
        final items = (data['results'] as List).whereType<Map<String, dynamic>>().toList();
        final match = _findBestMatch(items, cleanTitle, cleanArtist);
        if (match != null) {
          final rawArt = match['artworkUrl100']?.toString() ??
              match['artworkUrl60']?.toString() ??
              '';
          if (rawArt.isNotEmpty) {
            // Upgrade 100x100 thumbnail to pristine 1400x1400 studio album cover
            final highResArt = rawArt.replaceAll(
              RegExp(r'\d+x\d+bb'),
              '1400x1400bb',
            );
            return OfficialArtworkResult(
              artworkUrl: highResArt,
              albumTitle: match['collectionName']?.toString() ?? rawAlbum,
              artist: match['artistName']?.toString() ?? rawArtist,
              title: match['trackName']?.toString() ?? rawTitle,
            );
          }
        }
      }
    } catch (_) {}

    // 2. Fallback: try Album search if album title is known
    if (rawAlbum.isNotEmpty && cleanArtist.isNotEmpty) {
      try {
        final res = await _dio.get<dynamic>(
          'https://itunes.apple.com/search',
          queryParameters: {
            'term': '$cleanArtist ${normalizeForSearch(rawAlbum)}',
            'entity': 'album',
            'limit': '3',
          },
        );
        dynamic rawData = res.data;
        if (rawData is String && rawData.isNotEmpty) {
          try {
            rawData = jsonDecode(rawData);
          } catch (_) {}
        }
        final data = rawData is Map ? rawData : null;
        if (data != null && data['results'] is List) {
          final items = (data['results'] as List).whereType<Map<String, dynamic>>().toList();
          if (items.isNotEmpty) {
            final rawArt = items.first['artworkUrl100']?.toString() ?? '';
            if (rawArt.isNotEmpty) {
              final highResArt = rawArt.replaceAll(
                RegExp(r'\d+x\d+bb'),
                '1400x1400bb',
              );
              return OfficialArtworkResult(
                artworkUrl: highResArt,
                albumTitle: items.first['collectionName']?.toString() ?? rawAlbum,
                artist: items.first['artistName']?.toString() ?? rawArtist,
                title: rawTitle,
              );
            }
          }
        }
      } catch (_) {}
    }

    // 3. Fallback: query InnerTube Music API for tracks not in iTunes (e.g. anime, SoundCloud, YouTube originals)
    if (_tube != null) {
      try {
        final match = await _tube!.findBestMatchOrNull(rawTitle, rawArtist);
        if (match != null && match.artworkUrl.isNotEmpty) {
          return OfficialArtworkResult(
            artworkUrl: match.artworkUrl,
            albumTitle: match.album.isNotEmpty ? match.album : rawAlbum,
            artist: match.artist.isNotEmpty ? match.artist : rawArtist,
            title: match.title.isNotEmpty ? match.title : rawTitle,
          );
        }
      } catch (_) {}
    }

    return null;
  }

  Map<String, dynamic>? _findBestMatch(
    List<Map<String, dynamic>> items,
    String targetTitle,
    String targetArtist,
  ) {
    if (items.isEmpty) return null;

    Map<String, dynamic>? best;
    var bestScore = -1;

    for (final item in items) {
      final trackName = normalizeForSearch(item['trackName']?.toString() ?? '');
      final artistName = normalizeForSearch(item['artistName']?.toString() ?? '');
      if (trackName.isEmpty) continue;

      var score = 0;

      // Exact or substring title match
      if (trackName == targetTitle) {
        score += 100;
      } else if (trackName.contains(targetTitle) || targetTitle.contains(trackName)) {
        score += 60;
      } else {
        continue; // Title must have strong similarity
      }

      // Artist match
      if (targetArtist.isNotEmpty) {
        if (artistName == targetArtist) {
          score += 100;
        } else if (artistName.contains(targetArtist) || targetArtist.contains(artistName)) {
          score += 50;
        }
      }

      // Prefer non-instrumental unless target explicitly requested instrumental
      final isInstrumental = trackName.contains('instrumental');
      final wantsInstrumental = targetTitle.contains('instrumental');
      if (isInstrumental && !wantsInstrumental) {
        score -= 40;
      }

      if (score > bestScore) {
        bestScore = score;
        best = item;
      }
    }

    return best ?? (items.isNotEmpty ? items.first : null);
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
