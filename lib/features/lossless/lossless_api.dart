import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/stream_models.dart';
import '../../core/env/app_env.dart';
import '../../core/network/dio_factory.dart';
import 'tidal_api.dart';

/// Lossless backend client (clashflac-compatible REST).
///
/// Ported from LastWave-native `data/lossless/LosslessMusicApi.kt`:
/// same endpoints, headers, quality tiers, attempt order, verified
/// match scoring and stream resolution — only the HTTP layer is Dio
/// instead of OkHttp.
class LosslessMusicApi {
  final Dio _dio;
  final TidalApi _tidal;
  final ResolvedStreamCache _streamCache = ResolvedStreamCache(maxEntries: 16);
  final Map<String, Future<ResolvedStream?>> _inflight = {};

  LosslessMusicApi([Dio? dio, TidalApi? tidal])
      : _dio = dio ??
            DioFactory.create()
              ..options
                  .connectTimeout = const Duration(seconds: 10),
        _tidal = tidal ?? TidalApi(dio);

  String get _base => AppEnv.losslessBackendUrl;
  bool get isConfigured => AppEnv.hasAnyLosslessCatalog;

  Map<String, String> get _headers => {
        if (AppEnv.losslessApiKey.isNotEmpty)
          'X-API-Key': AppEnv.losslessApiKey,
      };

  static bool _isBackendFailure(DioException error) {
    final status = error.response?.statusCode;
    return status == null || status == 401 || status == 403 ||
        status == 429 || status >= 500;
  }

  // -- quality tiers (identical constants) --------------------------------
  static const int qualityMaxHiRes = 27;
  static const int qualityHiRes96 = 7;
  static const int qualityCdLossless = 6;
  static const int qualityMp3320 = 5;
  static const int qualityYoutube = -1;

  static const int maxDurationDifferenceSeconds = 8;

  /// Attempt order: preferred first, then higher tiers, then lower
  /// (reversed). Mirrors `getQualityAttemptOrder`.
  static List<int> getQualityAttemptOrder(int preferred) {
    if (preferred == qualityYoutube) return const [];
    const ascending = [qualityMp3320, qualityCdLossless, qualityHiRes96, qualityMaxHiRes];
    if (!ascending.contains(preferred)) {
      return const [qualityMaxHiRes, qualityHiRes96, qualityCdLossless, qualityMp3320];
    }
    final above = ascending.where((q) => q > preferred).toList();
    final below =
        ascending.where((q) => q < preferred).toList().reversed.toList();
    return [preferred, ...above, ...below];
  }

  // -- search ---------------------------------------------------------------

  Future<List<LosslessCandidate>> _search(String query) async {
    final res = await _dio.get<Map<String, dynamic>>(
      '$_base/api/search',
      queryParameters: {'q': query, 'type': 'track', 'limit': '15'},
      options: Options(headers: _headers),
    );
    final data = res.data ?? const {};
    if (data['success'] != true) return const [];
    final results = data['results'] as Map<String, dynamic>?;
    final tracks = results?['tracks'] as Map<String, dynamic>?;
    final items = tracks?['items'];
    if (items is! List) return const [];
    return items
        .whereType<Map<String, dynamic>>()
        .map(LosslessCandidate.fromJson)
        .toList();
  }

  // -- matching ---------------------------------------------------------------

  static String normalizeTitle(String s) {
    var v = s.toLowerCase();
    v = v.replaceAll(
        RegExp(
            r'\s*-\s*(?:official|video|audio|remaster|remastered|lyrics?).*$',
            caseSensitive: false),
        '');
    v = v.replaceAll(
        RegExp(
            r'\s*\([^)]*(?:feat|ft\.?|featuring|official|video|audio|remaster|visualizer|lyrics?)[^)]*\)',
            caseSensitive: false),
        '');
    v = v.replaceAll(
        RegExp(
            r'\s*\[[^\]]*(?:feat|ft\.?|featuring|official|video|audio|remaster|visualizer|lyrics?)[^\]]*\]',
            caseSensitive: false),
        '');
    v = v.replaceAll(
        RegExp(
            r'\s*[\(\[][^)\]]*(?:explicit|deluxe|expanded|anniversary|bonus|edition)[^)\]]*[\)\]]',
            caseSensitive: false),
        '');
    // Only strip "Artist - " prefix if there is still a " - " separator
    v = v.replaceAll(RegExp(r'^\s*[\w&.\- ]+\s*-\s+'), '');
    v = cleanForSearch(v);
    return v;
  }

  static String cleanForSearch(String s) {
    var v = s.toLowerCase();
    v = v.replaceAll(RegExp(r"['’`´]"), '');
    v = v.replaceAll('\$', 's');
    v = v.replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ');
    return v.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static const _versionTags = [
    'live', 'acoustic', 'karaoke', 'instrumental', 'tribute', 'cover',
    'remix', 'mashup', 'demo', 'slowed', 'reverb', 'sped up', 'sped-up',
    'spaced', 'nightcore', 'radio edit', 'extended',
  ];

  static Set<String> identityVariants(String s) {
    final n = cleanForSearch(s);
    if (n.isEmpty) return {};
    final found = <String>{};
    for (final tag in _versionTags) {
      final hit = tag.contains(' ')
          ? n.contains(tag)
          : RegExp('\\b${RegExp.escape(tag)}\\b').hasMatch(n);
      if (hit) found.add(tag);
    }
    return found;
  }

  /// True when two titles are the same recording after YouTube noise
  /// is stripped. Exact match first; high token overlap allows
  /// apostrophe/`feat` leftovers that used to force Opus fallback.
  static bool titlesMatch(String a, String b) => _titlesMatch(a, b);

  static bool _titlesMatch(String a, String b) {
    final na = normalizeTitle(a);
    final nb = normalizeTitle(b);
    if (na.isEmpty || nb.isEmpty) return false;
    if (na == nb) return true;
    final ta = na.split(' ').where((t) => t.length > 1).toSet();
    final tb = nb.split(' ').where((t) => t.length > 1).toSet();
    if (ta.isEmpty || tb.isEmpty) return false;
    final common = ta.intersection(tb).length;
    if (common == 0) return false;
    final dice = (200 * common) / (ta.length + tb.length);
    if (dice >= 92) return true;
    if (ta.containsAll(tb) || tb.containsAll(ta)) {
      final ratio = (common * 100) / (ta.length > tb.length ? ta.length : tb.length);
      return ratio >= 75;
    }
    // One-character catalog typos: "Nube Ras" vs "Numbe Ras".
    if (na.length >= 7 && nb.length >= 7 && _editDistance(na, nb) <= 1) {
      return true;
    }
    return false;
  }

  static int _editDistance(String a, String b) {
    if (a == b) return 0;
    if ((a.length - b.length).abs() > 1) return 99;
    final m = a.length;
    final n = b.length;
    var prev = List<int>.generate(n + 1, (j) => j);
    for (var i = 1; i <= m; i++) {
      final cur = List<int>.filled(n + 1, 0);
      cur[0] = i;
      for (var j = 1; j <= n; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        cur[j] = [
          prev[j] + 1,
          cur[j - 1] + 1,
          prev[j - 1] + cost,
        ].reduce((x, y) => x < y ? x : y);
      }
      prev = cur;
    }
    return prev[n];
  }

  static bool _isVerifiedArtistMatch({
    required String target,
    required String performer,
    required String albumArtist,
    required String performersText,
  }) {
    final nTarget = cleanForSearch(target);
    if (nTarget.isEmpty) return false;
    bool tokenSubset(String a, String b) {
      const stop = {
        'the', 'and', 'feat', 'ft', 'featuring', 'with', 'x', '&'
      };
      final ta = a.split(' ').where((t) => !stop.contains(t)).toSet();
      final tb = b.split(' ').where((t) => !stop.contains(t)).toSet();
      return ta.isNotEmpty && tb.containsAll(ta) ||
          tb.isNotEmpty && ta.containsAll(tb);
    }

    if (cleanForSearch(performer) == nTarget) return true;
    if (cleanForSearch(albumArtist) == nTarget) return true;
    if (tokenSubset(nTarget, cleanForSearch(performer))) return true;
    if (tokenSubset(nTarget, cleanForSearch(albumArtist))) return true;
    if (performersText.isNotEmpty &&
        tokenSubset(nTarget, cleanForSearch(performersText))) {
      return true;
    }
    return false;
  }

  int? verifiedMatchScore(
    LosslessCandidate item, {
    required String title,
    required String artist,
    required String album,
    required int expectedDurationSeconds,
  }) {
    if (!_titlesMatch(item.title, title) &&
        !_titlesMatch(item.titleWithVersion, title)) {
      return null;
    }
    final a = identityVariants(item.titleWithVersion);
    final b = identityVariants(title);
    if (a.length != b.length || !a.containsAll(b)) return null;
    if (!_isVerifiedArtistMatch(
      target: artist,
      performer: item.performer,
      albumArtist: item.albumArtist,
      performersText: item.performersText,
    )) {
      return null;
    }
    if (expectedDurationSeconds > 0) {
      if (item.duration <= 0) return null;
      final diff = (item.duration - expectedDurationSeconds).abs();
      if (diff > maxDurationDifferenceSeconds) return null;
    }
    var score = 1000;
    if (cleanForSearch(item.performer) == cleanForSearch(artist) ||
        cleanForSearch(item.albumArtist) == cleanForSearch(artist)) {
      score += 300;
    }
    if (album.isNotEmpty &&
        cleanForSearch(item.albumTitle) == cleanForSearch(album)) {
      score += 120;
    }
    if (expectedDurationSeconds > 0 && item.duration > 0) {
      final diff = (item.duration - expectedDurationSeconds).abs();
      score += (8 - diff) * 10;
    }
    return score;
  }

  Future<LosslessCandidate?> findBestVerifiedMatch({
    required String title,
    required String artist,
    String album = '',
    int expectedDurationSeconds = 0,
  }) async {
    if (AppEnv.hasLosslessBackend) {
      final qobuz = await _findBestVerifiedMatch(
        search: _search,
        title: title,
        artist: artist,
        album: album,
        expectedDurationSeconds: expectedDurationSeconds,
      );
      if (qobuz != null) return qobuz;
    }
    if (AppEnv.hasTidalBackend) {
      return _findBestVerifiedMatch(
        search: _searchTidal,
        title: title,
        artist: artist,
        album: album,
        expectedDurationSeconds: expectedDurationSeconds,
      );
    }
    return null;
  }

  Future<List<LosslessCandidate>> _searchTidal(String query) async {
    final hits = await _tidal.searchTracks(query);
    return [
      for (final hit in hits)
        LosslessCandidate.fromJson(tidalHitToCandidateJson(hit)),
    ];
  }

  Future<LosslessCandidate?> _findBestVerifiedMatch({
    required Future<List<LosslessCandidate>> Function(String query) search,
    required String title,
    required String artist,
    required String album,
    required int expectedDurationSeconds,
  }) async {
    final cleanT = normalizeTitle(title);
    final cleanA = cleanForSearch(artist);
    final cleanAlbum = cleanForSearch(album);
    final coreT = cleanT
        .replaceAll(RegExp(r'\b(?:interlude|intro|outro|reprise)\b'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final queries = {
      if (cleanAlbum.isNotEmpty && cleanA.isNotEmpty && cleanT.isNotEmpty)
        '$cleanAlbum $cleanA $cleanT',
      if (cleanAlbum.isNotEmpty && cleanA.isNotEmpty && coreT.isNotEmpty)
        '$cleanAlbum $cleanA $coreT',
      if (cleanT.isNotEmpty && cleanA.isNotEmpty) '$cleanA - $cleanT',
      if (cleanT.isNotEmpty && cleanA.isNotEmpty) '$cleanT $cleanA',
      if (cleanT.isNotEmpty && cleanA.isNotEmpty) '$cleanA $cleanT',
      if (coreT.isNotEmpty && coreT != cleanT && cleanA.isNotEmpty)
        '$cleanA $coreT',
      '${cleanForSearch(title)} ${cleanForSearch(artist)}',
      '${cleanForSearch(artist)} ${cleanForSearch(title)}',
      if (cleanT.isNotEmpty) cleanT,
      if (coreT.isNotEmpty) coreT,
      cleanForSearch(title),
      title,
    }.where((q) => q.trim().isNotEmpty);
    LosslessCandidate? best;
    var bestScore = -1;
    for (final q in queries) {
      List<LosslessCandidate> items;
      try {
        items = await search(q);
      } on DioException catch (error) {
        if (_isBackendFailure(error)) rethrow;
        continue;
      } catch (_) {
        continue;
      }
      for (final item in items) {
        final score = verifiedMatchScore(
          item,
          title: title,
          artist: artist,
          album: album,
          expectedDurationSeconds: expectedDurationSeconds,
        );
        if (score != null && score > bestScore) {
          bestScore = score;
          best = item;
        }
      }
      if (best != null) break;
    }
    return best;
  }

  // -- stream URL ---------------------------------------------------------------

  Future<ResolvedStream?> _fetchTrackStreamUrl(
    String trackId,
    int quality, {
    bool fallback = false,
    String artworkUrl = '',
    String albumTitle = '',
  }) async {
    final res = await _dio.get<Map<String, dynamic>>(
      '$_base/api/track/$trackId/url',
      queryParameters: {
        'quality': '$quality',
        'fallback': '$fallback',
      },
      options: Options(headers: _headers),
    );
    final data = res.data ?? const {};
    if (data['success'] != true) return null;
    final d = data['data'] as Map<String, dynamic>?;
    if (d == null) return null;
    final url = d['url']?.toString() ?? '';
    if (url.isEmpty) return null;
    final formatId = (d['format_id'] as num?)?.toInt() ?? 6;
    final mime = d['mime_type']?.toString() ?? 'audio/flac';
    final bitDepth = (d['bit_depth'] as num?)?.toInt() ?? 16;
    final samplingRate =
        (d['sampling_rate'] as num?)?.toDouble() ?? 44.1;
    final bitrateKbps = switch (formatId) {
      27 || 7 => (bitDepth * samplingRate * 2).toInt(),
      6 => 1411,
      5 => 320,
      _ => 1411,
    };
    final codec = switch (formatId) {
      27 || 7 => 'HI-RES FLAC',
      6 => 'LOSSLESS',
      5 => 'MP3 320k',
      _ => 'FLAC',
    };
    return ResolvedStream(
      url: url,
      mimeType: mime,
      bitrateKbps: bitrateKbps,
      audioCodec: codec,
      cacheKey: 'lossless:$trackId:$formatId',
      isLossless: formatId != 5,
      bitDepth: bitDepth,
      samplingRateKhz: samplingRate,
      artworkUrl: artworkUrl,
      albumTitle: albumTitle,
      expiresAt: DateTime.now().add(const Duration(minutes: 20)),
    );
  }

  String _streamCacheKey(
    String title,
    String artist,
    int preferredQuality,
  ) =>
      '${normalizeTitle(title)}|${cleanForSearch(artist)}|$preferredQuality';

  void invalidateStream({required String title, required String artist}) {
    final prefix = '${normalizeTitle(title)}|${cleanForSearch(artist)}|';
    _streamCache.invalidateWhere((key) => key.startsWith(prefix));
  }

  void clearStreamCache() => _streamCache.clear();

  /// Resolve the best lossless stream, mirroring Android
  /// `LosslessMusicApi.resolveStream` (verified match → tier order →
  /// final fallback attempt).
  Future<ResolvedStream?> resolveStream({
    required String title,
    required String artist,
    String album = '',
    int expectedDurationSeconds = 0,
    int preferredQuality = qualityMaxHiRes,
  }) async {
    if (!isConfigured) return null;
    if (preferredQuality == qualityYoutube) return null;
    if (title.trim().isEmpty || artist.trim().isEmpty) return null;
    final cacheKey = _streamCacheKey(title, artist, preferredQuality);
    final cached = _streamCache.get(cacheKey);
    if (cached != null) return cached;
    final pending = _inflight[cacheKey];
    if (pending != null) return pending;
    final future = _resolveStreamUncached(
      title: title,
      artist: artist,
      album: album,
      expectedDurationSeconds: expectedDurationSeconds,
      preferredQuality: preferredQuality,
    );
    _inflight[cacheKey] = future;
    try {
      final stream = await future;
      if (stream != null) _streamCache.put(cacheKey, stream);
      return stream;
    } finally {
      _inflight.remove(cacheKey);
    }
  }

  Future<ResolvedStream?> _resolveStreamUncached({
    required String title,
    required String artist,
    String album = '',
    int expectedDurationSeconds = 0,
    int preferredQuality = qualityMaxHiRes,
  }) async {
    if (AppEnv.hasLosslessBackend) {
      try {
        final candidate = await _findBestVerifiedMatch(
          search: _search,
          title: title,
          artist: artist,
          album: album,
          expectedDurationSeconds: expectedDurationSeconds,
        );
        if (candidate != null) {
          final stream = await _fetchQobuzStream(
            candidate,
            preferredQuality,
          );
          if (stream != null) return stream;
        }
      } catch (_) {
        // Qobuz miss or backend error — Tidal is next.
      }
    }
    if (AppEnv.hasTidalBackend) {
      try {
        final candidate = await _findBestVerifiedMatch(
          search: _searchTidal,
          title: title,
          artist: artist,
          album: album,
          expectedDurationSeconds: expectedDurationSeconds,
        );
        if (candidate == null) return null;
        return await _tidal.fetchPlayable(
          candidate.id,
          preferredQuality,
          artworkUrl: candidate.albumArtUrl,
          albumTitle: candidate.albumTitle,
        );
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  Future<ResolvedStream?> _fetchQobuzStream(
    LosslessCandidate candidate,
    int preferredQuality,
  ) async {
    try {
      final stream = await _fetchTrackStreamUrl(
        candidate.id,
        preferredQuality,
        fallback: true,
        artworkUrl: candidate.albumArtUrl,
        albumTitle: candidate.albumTitle,
      );
      if (stream != null) return stream;
    } catch (_) {}

    for (final q in getQualityAttemptOrder(preferredQuality)) {
      try {
        final stream = await _fetchTrackStreamUrl(
          candidate.id,
          q,
          fallback: true,
          artworkUrl: candidate.albumArtUrl,
          albumTitle: candidate.albumTitle,
        );
        if (stream != null) return stream;
      } catch (_) {}
    }
    return null;
  }
}

class LosslessCandidate {
  final String id;
  final String title;
  final String version;
  final int duration;
  final String performer;
  final String performersText;
  final String albumTitle;
  final String albumArtist;
  final String albumArtUrl;

  LosslessCandidate({
    required this.id,
    required this.title,
    this.version = '',
    this.duration = 0,
    this.performer = '',
    this.performersText = '',
    this.albumTitle = '',
    this.albumArtist = '',
    this.albumArtUrl = '',
  });

  String get titleWithVersion =>
      version.isEmpty ? title : '$title $version';

  static int _parseCandidateDuration(Object? raw) {
    var n = 0;
    if (raw is num) {
      n = raw.toInt();
    } else {
      n = int.tryParse(raw?.toString() ?? '') ?? 0;
    }
    if (n <= 0) return 0;
    if (n > 10000) n = (n / 1000).round();
    if (n > 24 * 3600) return 0;
    return n;
  }

  factory LosslessCandidate.fromJson(Map<String, dynamic> json) {
    final performer = json['performer'];
    String performerName = '';
    String performersText = '';
    if (performer is Map) {
      performerName = performer['name']?.toString() ?? '';
    } else if (performer is String) {
      performerName = performer;
    } else if (performer is List) {
      final names = performer
          .whereType<Map>()
          .map((e) => e['name']?.toString() ?? '')
          .where((e) => e.isNotEmpty)
          .toList();
      performerName = names.isNotEmpty ? names.first : '';
      performersText = names.join(' ');
    }
    String performersKredit = '';
    final performers = json['performers'];
    if (performers is List) {
      performersKredit = performers
          .whereType<Map>()
          .map((e) => e['name']?.toString() ?? '')
          .where((e) => e.isNotEmpty)
          .join(' ');
    }
    final album = json['album'];
    final albumArtist = album is Map ? album['artist'] : null;
    String albumArt = '';
    if (album is Map) {
      final img = album['image'];
      if (img is Map) {
        albumArt = img['large']?.toString() ??
            img['extralarge']?.toString() ??
            img['small']?.toString() ??
            img['thumbnail']?.toString() ??
            '';
      } else if (img is String && img.isNotEmpty) {
        albumArt = img;
      }
      if (albumArt.isEmpty) {
        albumArt = album['cover']?.toString() ?? '';
      }
    }
    return LosslessCandidate(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      version: json['version']?.toString() ?? '',
      duration: _parseCandidateDuration(json['duration']),
      performer: performerName,
      performersText:
          performersText.isNotEmpty ? performersText : performersKredit,
      albumTitle:
          album is Map ? album['title']?.toString() ?? '' : '',
      albumArtist: albumArtist is Map
          ? albumArtist['name']?.toString() ?? ''
          : albumArtist?.toString() ?? '',
      albumArtUrl: albumArt,
    );
  }
}

final losslessApiProvider =
    Provider<LosslessMusicApi>((_) => LosslessMusicApi());
