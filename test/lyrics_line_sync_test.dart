import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/lyrics/lyrics_models.dart';
import 'package:lastwave_desktop/features/lyrics/lyrics_repository.dart';

/// Line-by-line reproduction: LRCLIB holds ONLY a line-synced record,
/// Apple/iTunes holds nothing. Both display modes must yield usable lines.
const _lineSyncedRecord = {
  'id': 1250,
  'trackName': 'Shape of You',
  'artistName': 'Ed Sheeran',
  'albumName': 'Divide',
  'duration': 234.0,
  'instrumental': false,
  'plainLyrics': "The club isn't the best place to find a lover",
  'syncedLyrics': '[00:09.73] The club isn\'t the best place to find a lover\n'
      '[00:15.12] So the bar is where I go',
};

Dio _stubDio() {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        final url = options.uri.toString();
        if (url.contains('itunes.apple.com')) {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: '{"resultCount":0,"results":[]}',
            ),
          );
          return;
        }
        if (url.contains('lrclib.net/api/get')) {
          handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.badResponse,
              response: Response(
                requestOptions: options,
                statusCode: 404,
              ),
            ),
          );
          return;
        }
        if (url.contains('lrclib.net/api/search')) {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: [_lineSyncedRecord],
            ),
          );
          return;
        }
        if (url.contains('paxsenix')) {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: <String, dynamic>{},
            ),
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
  test('line-only LRCLIB yields usable lines with wordByWord=false', () async {
    final repo = LyricsRepository(_stubDio());
    final result = await repo.getLyrics(
      title: 'Shape of You',
      artist: 'Ed Sheeran',
      wordByWord: false,
    );
    expect(result.isEmpty, isFalse);
    expect(result.isSynced, isTrue);
    expect(result.isWordSynced, isFalse);
    expect(result.lines.length, greaterThanOrEqualTo(2));
    expect(result.lines.first.timeMs, greaterThanOrEqualTo(9000));
  });

  test('line-only LRCLIB yields usable lines with wordByWord=true', () async {
    final repo = LyricsRepository(_stubDio());
    final result = await repo.getLyrics(
      title: 'Shape of You',
      artist: 'Ed Sheeran',
      wordByWord: true,
    );
    expect(result.isEmpty, isFalse);
    expect(result.isSynced, isTrue);
    expect(result.lines.length, greaterThanOrEqualTo(2));
  });

  test('lyricsForDisplayMode strips syllables for line display', () {
    final repo = LyricsRepository(_stubDio());
    expect(repo, isNotNull);
    final wordSynced = LyricsResult(
      lines: parseLrc(_lineSyncedRecord['syncedLyrics']! as String),
      isSynced: true,
      isWordSynced: true,
      plainLyrics: '',
      source: 'Apple Music',
    );
    final line = lyricsForDisplayMode(wordSynced, wordByWord: false);
    expect(line.isSynced, isTrue);
    expect(line.isWordSynced, isFalse);
    expect(line.lines.length, equals(wordSynced.lines.length));
    expect(line.lines.every((l) => l.syllables.isEmpty), isTrue);
  });
}
