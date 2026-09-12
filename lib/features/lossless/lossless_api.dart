import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/stream_models.dart';
import '../../core/env/app_env.dart';
import '../../core/network/dio_factory.dart';

/// Lossless backend client (clashflac-compatible REST).
///
/// Ported from LastWave-native `data/lossless/LosslessMusicApi.kt`:
/// same endpoints, headers, quality tiers, attempt order, verified
/// match scoring and stream resolution — only the HTTP layer is Dio
/// instead of OkHttp.
class LosslessMusicApi {
  final Dio _dio;

  LosslessMusicApi([Dio? dio])
      : _dio = dio ??
            DioFactory.create()
              ..options
                  .connectTimeout = const Duration(seconds: 10);

  String get _base => AppEnv.losslessBackendUrl;
  bool get isConfigured => AppEnv.hasLosslessBackend;

  Map<String, String> get _headers => {
        if (AppEnv.losslessApiKey.isNotEmpty)
          'X-API-Key': AppEnv.losslessApiKey,
      };

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
    v = v.replaceAll(RegExp(r'^\s*[\w&.\- ]+\s*-\s+'), '');
    v = cleanForSearch(v);
    return v;
  }

  static String cleanForSearch(String s) {
    var v = s.toLowerCase();
    v = v.replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ');
    return v.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static const _versionTags = [
    'live', 'acoustic', 'karaoke', 'instrumental', 'tribute', 'cover',
    'remix', 'mashup', 'demo', 'slowed', 'reverb', 'sped-up', 'spaced',
    'nightcore', 'radio edit', 'extended',
  ];

  static Set<String> identityVariants(String s) {
    final n = cleanForSearch(s);
    final found = <String>{};
    for (final tag in _versionTags) {
      if (n.contains(tag)) found.add(tag);
    }
    return found;
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

  int? _verifiedMatchScore(
    LosslessCandidate item, {
    required String title,
    required String artist,
    required String album,
    required int expectedDurationSeconds,
  }) {
    if (normalizeTitle(item.title) != normalizeTitle(title)) {
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
    final queries = {
      '${cleanForSearch(title)} ${cleanForSearch(artist)}',
      '${cleanForSearch(artist)} ${cleanForSearch(title)}',
      cleanForSearch(title),
      title,
    }.where((q) => q.trim().isNotEmpty);
    LosslessCandidate? best;
    var bestScore = -1;
    for (final q in queries) {
      List<LosslessCandidate> items;
      try {
        items = await _search(q);
      } catch (_) {
        continue;
      }
      for (final item in items) {
        final score = _verifiedMatchScore(
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
    );
  }

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
    try {
      final candidate = await findBestVerifiedMatch(
        title: title,
        artist: artist,
        album: album,
        expectedDurationSeconds: expectedDurationSeconds,
      );
      if (candidate == null) return null;
      for (final q in getQualityAttemptOrder(preferredQuality)) {
        try {
          final stream = await _fetchTrackStreamUrl(
            candidate.id,
            q,
            fallback: false,
          );
          if (stream != null) return stream;
        } catch (_) {}
      }
      return await _fetchTrackStreamUrl(
        candidate.id,
        preferredQuality,
        fallback: true,
      );
    } catch (_) {
      return null;
    }
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

  LosslessCandidate({
    required this.id,
    required this.title,
    this.version = '',
    this.duration = 0,
    this.performer = '',
    this.performersText = '',
    this.albumTitle = '',
    this.albumArtist = '',
  });

  String get titleWithVersion =>
      version.isEmpty ? title : '$title $version';

  factory LosslessCandidate.fromJson(Map<String, dynamic> json) {
    final performer = json['performer'];
    String performerName = '';
    String performersText = '';
    if (performer is Map) {
      performerName = performer['name']?.toString() ?? '';
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
    return LosslessCandidate(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      version: json['version']?.toString() ?? '',
      duration: (json['duration'] as num?)?.toInt() ?? 0,
      performer: performerName,
      performersText:
          performersText.isNotEmpty ? performersText : performersKredit,
      albumTitle:
          album is Map ? album['title']?.toString() ?? '' : '',
      albumArtist:
          album is Map ? album['artist']?.toString() ?? '' : '',
    );
  }
}

final losslessApiProvider =
    Provider<LosslessMusicApi>((_) => LosslessMusicApi());
