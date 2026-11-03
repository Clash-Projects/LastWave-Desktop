import 'dart:convert';

import 'package:dio/dio.dart';

import 'rate_guard.dart';

/// Thin Last.fm `2.0/` client.
///
/// Mirrors LastWave-native `data/network/LastFmApiService.kt`:
/// unsigned reads via GET, signed writes via form POST, all calls
/// multiplexed through the `method` parameter on
/// `https://ws.audioscrobbler.com/`.
class LastFmApiService {
  static const String baseUrl = 'https://ws.audioscrobbler.com/';

  final Dio _dio;
  final LastFmRateGuard _rateGuard;

  LastFmApiService(this._dio, this._rateGuard, {DateTime Function()? clock})
      : _now = clock ?? DateTime.now;

  final DateTime Function() _now;

  /// How long an unsigned read of each method may be replayed from memory.
  /// Catalog data barely moves; per-user data is kept short so a refresh
  /// after listening still sees new plays and the cache only dedupes the
  /// feed's repeated identical calls. Everything else (recent tracks, auth,
  /// user search) always goes to the network.
  static const Map<String, Duration> _ttl = {
    'artist.getinfo': Duration(hours: 6),
    'artist.getsimilar': Duration(hours: 6),
    'artist.gettoptracks': Duration(hours: 6),
    'artist.gettoptags': Duration(hours: 6),
    'track.getsimilar': Duration(hours: 6),
    'tag.gettoptracks': Duration(hours: 6),
    'user.gettoptracks': Duration(minutes: 2),
    'user.gettopartists': Duration(minutes: 2),
    'user.gettopalbums': Duration(minutes: 2),
    'user.gettoptags': Duration(minutes: 2),
    'user.getinfo': Duration(minutes: 2),
    'user.getfriends': Duration(minutes: 2),
  };
  static const int _memoCap = 200;

  final _memo =
      <String, ({DateTime at, Future<Map<String, dynamic>> value})>{};

  /// Unsigned read, replayed from memory for the methods in [_ttl]. Shares
  /// an in-flight request, and never keeps a failure or an API error body.
  Future<Map<String, dynamic>> get(Map<String, String> query) {
    final ttl = _ttl[(query['method'] ?? '').toLowerCase()];
    if (ttl == null) return _fetch(query);
    final entries = query.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final key = entries
        .map((e) =>
            '${e.key}=${e.key == 'method' ? e.value.toLowerCase() : e.value}')
        .join('&');
    final hit = _memo.remove(key);
    if (hit != null && _now().difference(hit.at) < ttl) {
      _memo[key] = hit; // re-insert: most recently used goes last
      return hit.value;
    }
    final future = _fetch(query);
    _memo[key] = (at: _now(), value: future);
    if (_memo.length > _memoCap) _memo.remove(_memo.keys.first);
    future.then((json) {
      if (json.containsKey('error') && identical(_memo[key]?.value, future)) {
        _memo.remove(key);
      }
    }, onError: (Object _) {
      if (identical(_memo[key]?.value, future)) _memo.remove(key);
    });
    return future;
  }

  Future<Map<String, dynamic>> _fetch(Map<String, String> query) async {
    await _rateGuard.awaitClearance();
    try {
      final res = await _dio.get<String>(
        '2.0/',
        queryParameters: {'format': 'json', ...query},
        options: Options(
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      _rateGuard.onRequestSucceeded();
      return _decode(res.data);
    } on DioException catch (e) {
      _handleRateLimit(e);
      rethrow;
    }
  }

  Future<Map<String, dynamic>> post(Map<String, String> fields) async {
    await _rateGuard.awaitClearance();
    try {
      final res = await _dio.post<String>(
        '2.0/',
        data: fields,
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      _rateGuard.onRequestSucceeded();
      return _decode(res.data);
    } on DioException catch (e) {
      _handleRateLimit(e);
      rethrow;
    }
  }

  void _handleRateLimit(DioException e) {
    final code = e.response?.statusCode;
    if (code == 429 || code == 503) {
      _rateGuard.onRequestLimited();
    }
  }

  Map<String, dynamic> _decode(String? body) {
    if (body == null || body.isEmpty) return const {};
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) return decoded;
    return {'value': decoded};
  }
}

/// Thrown for Last.fm API-level errors (`{"error": n, "message": ...}`).
class LastFmException implements Exception {
  final String message;
  final int? code;
  LastFmException(this.message, [this.code]);

  @override
  String toString() => 'LastFmException($code): $message';

  static void throwIfError(Map<String, dynamic> json) {
    if (json.containsKey('error')) {
      final code = (json['error'] as num?)?.toInt();
      final raw = json['message']?.toString() ?? 'Last.fm error';
      throw LastFmException(lastFmFriendlyMessage(code, raw), code);
    }
  }
}
