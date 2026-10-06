import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/lyrics/lyrics_providers.dart';

const _miniKrc = '[offset:100]\n'
    '[500,1000]<0,200,0>Ed Sheeran - Shape of You\n'
    '[1000,2000]<0,200,0>Hello<200,300,0> world\n'
    '[4000,1500]<0,300,0>作词 : Someone\n'
    '[6000,1500]<0,200,0>Next<200,200,0> line\n';

String get _fixtureB64 =>
    File('test/fixtures/kugou_sample_krc.b64').readAsStringSync().trim();

Dio _stubDio(String fixtureB64) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        final url = options.uri.toString();
        if (url.contains('lyrics.kugou.com/search')) {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'status': 200,
                'candidates': [
                  {
                    'id': 'remix-id',
                    'accesskey': 'remix-key-0000000000000000000000',
                    'song': 'Shape of You (Remix)',
                    'singer': 'Ed Sheeran',
                    'duration': 207000,
                  },
                  {
                    'id': 'live-id',
                    'accesskey': 'live-key-00000000000000000000000',
                    'song': 'Shape of You',
                    'singer': 'Ed Sheeran',
                    'duration': 207177,
                  },
                ],
              },
            ),
          );
          return;
        }
        if (url.contains('lyrics.kugou.com/download')) {
          if ((options.uri.queryParameters['id'] ?? '') == 'live-id') {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {'content': fixtureB64, 'fmt': 'krc'},
              ),
            );
          } else {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.badResponse,
                response: Response(
                    requestOptions: options, statusCode: 404),
              ),
            );
          }
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
  test('fixture decrypts to KRC text', () {
    final text = decryptKugouKrc(_fixtureB64);
    expect(text, isNotNull);
    expect(text!, contains('['));
    expect(parseKugouKrc(text).isNotEmpty, isTrue);
  });

  test('short or bad payloads yield null, never throw', () {
    expect(decryptKugouKrc('AAAA'), isNull);
    expect(decryptKugouKrc(''), isNull);
    expect(decryptKugouKrc('!!!not-base64!!!'), isNull);
  });

  test('parse drops credits and title line, keeps word timing', () {
    final lines = parseKugouKrc(_miniKrc);
    expect(lines.length, 2);
    expect(lines.first.text, 'Hello world');
    expect(lines.first.timeMs, 1100);
    expect(lines.first.syllables.length, 2);
    expect(lines.first.syllables[0].timeMs, 1100);
    expect(lines.first.syllables[1].timeMs, 1300);
    expect(lines[1].text, 'Next line');
  });

  test('fetch rejects remix, decrypts the live cut', () async {
    final result = await fetchKugou(
      _stubDio(_fixtureB64),
      title: 'Shape of You',
      artist: 'Ed Sheeran',
      durationSeconds: 207,
    );
    expect(result, isNotNull);
    expect(result!.isWordSynced, isTrue);
    expect(result.source, contains('Kugou'));
    expect(result.lines.isNotEmpty, isTrue);
  });
}
