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

  LastFmApiService(this._dio, this._rateGuard);

  Future<Map<String, dynamic>> get(Map<String, String> query) async {
    await _rateGuard.awaitClearance();
    try {
      final res = await _dio.get<String>(
        '2.0/',
        queryParameters: {'format': 'json', ...query},
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
