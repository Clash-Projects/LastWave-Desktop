import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/lyrics/lyrics_providers.dart';

Dio _stubDio() {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        final url = options.uri.toString();
        Map<String, dynamic> envelope(dynamic body) => {
              'message': {
                'header': {'status_code': 200},
                'body': body,
              },
            };
        if (url.contains('token.get')) {
          handler.resolve(Response(
              requestOptions: options,
              statusCode: 200,
              data: envelope({'user_token': 'tok123'})));
          return;
        }
        if (url.contains('track.search')) {
          handler.resolve(Response(
              requestOptions: options,
              statusCode: 200,
              data: envelope({
                'track_list': [
                  {
                    'track': {
                      'track_id': 42,
                      'track_name': 'Shape of You',
                      'artist_name': 'Ed Sheeran',
                      'track_length': 234,
                      'has_subtitles': 1,
                    },
                  },
                  {
                    'track': {
                      'track_id': 43,
                      'track_name': 'Shape of You',
                      'artist_name': 'Someone Else',
                      'track_length': 234,
                      'has_subtitles': 1,
                    },
                  },
                ],
              })));
          return;
        }
        if (url.contains('track.subtitle.get')) {
          // Only the right track carries a subtitle: picking the
          // same-title wrong-artist track must not yield lyrics.
          final picked = options.uri.queryParameters['track_id'];
          handler.resolve(Response(
              requestOptions: options,
              statusCode: 200,
              data: envelope({
                'subtitle': {
                  'subtitle_body': picked == '42'
                      ? '[{"text":"The club","time":{"total":9.73}},{"text":"So the bar","time":{"total":15.12}}]'
                      : null,
                },
              })));
          return;
        }
        handler.reject(
          DioException(requestOptions: options, type: DioExceptionType.unknown),
        );
      },
    ),
  );
  return dio;
}

void main() {
  test('sign attaches sha256 signature protocol', () {
    final signed = musixmatchSign(
      'https://apic.musixmatch.com/ws/1.1/token.get?app_id=x',
      now: DateTime.utc(2026, 10, 6),
    );
    expect(signed, contains('signature_protocol=sha256'));
    expect(signed, contains('signature='));
    // Deterministic for a fixed date.
    expect(
      musixmatchSign('https://x/', now: DateTime.utc(2026, 10, 6)),
      musixmatchSign('https://x/', now: DateTime.utc(2026, 10, 6)),
    );
  });

  test('subtitle JSON converts to LRC lines', () {
    final lrc = musixmatchSubtitleToLrc(
      '[{"text":"The club","time":{"total":9.73}},{"text":"","time":{"total":10.0}},{"text":"So the bar","time":{"total":15.12}}]',
    );
    expect(lrc, contains('[00:09.730]The club'));
    expect(lrc, contains('[00:15.120]So the bar'));
  });

  test('scorer rejects wrong title; artist gate rejects wrong singer', () {
    // Wrong title never reaches the floor even with artist + duration.
    expect(
      musixmatchScore(
        trackName: 'Completely Different Song',
        artistName: 'Ed Sheeran',
        trackLength: 234,
        title: 'Shape of You',
        artist: 'Ed Sheeran',
        seconds: 234,
      ),
      lessThan(80),
    );
    // Native parity: exact title + duration scores 110 even for a
    // wrong singer — rejection happens in the mandatory artist gate
    // inside fetchMusixmatch (covered by the end-to-end test below,
    // whose stub serves two same-title tracks).
    expect(
      musixmatchScore(
        trackName: 'Shape of You',
        artistName: 'Someone Else',
        trackLength: 234,
        title: 'Shape of You',
        artist: 'Ed Sheeran',
        seconds: 234,
      ),
      110,
    );
    expect(
      musixmatchScore(
        trackName: 'Shape of You',
        artistName: 'Ed Sheeran',
        trackLength: 234,
        title: 'Shape of You',
        artist: 'Ed Sheeran',
        seconds: 234,
      ),
      greaterThanOrEqualTo(80),
    );
  });

  test('fetchMusixmatch resolves line-sync end to end', () async {
    final result = await fetchMusixmatch(
      _stubDio(),
      title: 'Shape of You',
      artist: 'Ed Sheeran',
      durationSeconds: 234,
    );
    expect(result, isNotNull);
    expect(result!.isSynced, isTrue);
    expect(result.source, contains('Catalog'));
    expect(result.lines.length, 2);
    expect(result.lines.first.timeMs, 9730);
  });
}
