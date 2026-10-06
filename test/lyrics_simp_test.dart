import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/lyrics/lyrics_providers.dart';

Dio _stubDio(Map<String, dynamic> payload) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        if (options.uri.toString().startsWith(
            'https://api-lyrics.simpmusic.org/v1/')) {
          handler.resolve(
            Response(
                requestOptions: options,
                statusCode: 200,
                data: payload),
          );
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
  test('rich sync yields word-synced lines', () async {
    final lines = await fetchSimpMusic(
      _stubDio({
        'success': true,
        'data': [
          {
            'duration': 213,
            'richSyncLyrics':
                '[00:01.00]<00:01.00>Hi <00:01.20>there\n[00:05.00]Yo\n',
            'syncedLyrics': '[00:01.00]Hi there\n',
          },
        ],
      }),
      videoId: 'abc123',
      durationSeconds: 213,
    );
    expect(lines, isNotNull);
    expect(lines!.first.hasSyllables, isTrue);
    expect(lines.first.text, 'Hi there');
  });

  test('plain synced falls back when rich sync absent', () async {
    final lines = await fetchSimpMusic(
      _stubDio({
        'success': true,
        'data': [
          {
            'duration': 213,
            'syncedLyrics': '[00:01.00]Hi there\n[00:05.00]Yo\n',
          },
        ],
      }),
      videoId: 'abc123',
      durationSeconds: 213,
    );
    expect(lines, isNotNull);
    expect(lines!.length, 2);
  });

  test('duration mismatch and failure yield null', () async {
    final dio = _stubDio({
      'success': true,
      'data': [
        {'duration': 213, 'syncedLyrics': '[00:01.00]Hi\n'},
      ],
    });
    expect(
      await fetchSimpMusic(dio, videoId: 'abc123', durationSeconds: 400),
      isNull,
    );
    expect(
      await fetchSimpMusic(_stubDio({'success': false}),
          videoId: 'abc123', durationSeconds: 213),
      isNull,
    );
    expect(await fetchSimpMusic(dio, videoId: null), isNull);
    expect(await fetchSimpMusic(dio, videoId: '  '), isNull);
  });
}
