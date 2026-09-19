import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

import 'rate_guard.dart';

/// Shared Dio factory with LastWave networking behaviour ported from
/// Android `di/NetworkModule.kt`:
/// - desktop User-Agent + JSON accept headers
/// - generous pool/timeouts, retry-on-connection-failure
/// - Last.fm 429/503 backoff via [LastFmRateGuard]
class DioFactory {
  DioFactory._();

  static const String desktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) '
      'Gecko/20100101 Firefox/140.0 LastWave-Desktop/1.0';

  static Dio create({LastFmRateGuard? rateGuard}) {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
        sendTimeout: const Duration(seconds: 15),
        headers: {
          'User-Agent': desktopUserAgent,
          'Accept': 'application/json, text/plain, */*',
          'Accept-Language': 'en-US,en;q=0.9',
        },
      ),
    );

    if (rateGuard != null) {
      dio.interceptors.add(
        InterceptorsWrapper(
          onResponse: (res, handler) {
            final code = res.statusCode;
            if (code == 429 || code == 503) {
              rateGuard.onRequestLimited();
            } else {
              rateGuard.onRequestSucceeded();
            }
            handler.next(res);
          },
          onError: (e, handler) async {
            final code = e.response?.statusCode;
            if ((code == 429 || code == 503) &&
                (e.requestOptions.extra['lfm_retried'] != true)) {
              rateGuard.onRequestLimited();
              e.requestOptions.extra['lfm_retried'] = true;
              await Future<void>.delayed(
                  const Duration(milliseconds: 1500));
              try {
                final res = await dio.fetch(e.requestOptions);
                return handler.resolve(res);
              } catch (_) {
                // fall through to original error
              }
            }
            handler.next(e);
          },
        ),
      );
    }

    if (kDebugMode) {
      final logger = Logger();
      dio.interceptors.add(
        InterceptorsWrapper(
          onError: (e, handler) {
            final host = e.requestOptions.uri.host;
            final code = e.response?.statusCode;
            // iTunes Search 403s when burst-queried; artwork code
            // handles that with a Deezer fallback. Don't dump a stack
            // per tile.
            if (code == 403 && host.contains('itunes.apple.com')) {
              handler.next(e);
              return;
            }
            // LRCLIB 404 is expected (no lyrics) — handled via search fallback.
            if (code == 404 && host.contains('lrclib.net')) {
              handler.next(e);
              return;
            }
            if (code == 404 && host.contains('artwork.m8tec.top')) {
              handler.next(e);
              return;
            }
            logger.w(
              'HTTP $code ${e.requestOptions.method} '
              '$host${e.requestOptions.uri.path}',
            );
            handler.next(e);
          },
        ),
      );
    }

    return dio;
  }

  /// Simple exponential retry for transient failures (408/429/5xx/IO),
  /// mirroring `InnerTubeMusicApi` retry policy (max 2 attempts).
  static Future<T> withRetry<T>(
    Future<T> Function() fn, {
    int maxAttempts = 2,
  }) async {
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await fn();
      } on DioException catch (e) {
        lastError = e;
        if (!_isTransient(e) || attempt == maxAttempts) rethrow;
        final backoff =
            Duration(milliseconds: 250 * (1 << (attempt - 1)));
        await Future<void>.delayed(backoff);
      }
    }
    throw lastError ?? StateError('withRetry failed');
  }

  static bool _isTransient(DioException e) {
    if (e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.sendTimeout) {
      return true;
    }
    final code = e.response?.statusCode;
    return code == 408 || code == 429 || (code != null && code >= 500);
  }
}
