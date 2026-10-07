import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/lyrics/lyrics_models.dart';
import 'package:lastwave_desktop/features/lyrics/lyrics_repository.dart';

/// Bug 1: a failed first fetch poisons retries.
/// Bug 2: LRCLIB word-stamped (enhanced) LRC is served as line-sync.

LyricsResult _line(String source) => LyricsResult(
      lines: const [
        LyricLine(timeMs: 1000, durationMs: 3000, text: 'Hello world'),
        LyricLine(timeMs: 5000, durationMs: 3000, text: 'Second line'),
      ],
      isSynced: true,
      isWordSynced: false,
      plainLyrics: 'Hello world\nSecond line',
      source: source,
    );

class _FlakyRepo extends LyricsRepository {
  final Future<LyricsResult?> Function() next;
  _FlakyRepo(this.next, Dio dio) : super(dio);

  @override
  Future<LyricsResult?> fetchFromProvider(
    String providerId, {
    required String title,
    required String artist,
    String album = '',
    int? durationSeconds,
    String? videoId,
  }) =>
      next();
}

class _LrclibOnlyRepo extends LyricsRepository {
  _LrclibOnlyRepo(super.dio);

  @override
  Future<LyricsResult?> fetchFromProvider(
    String providerId, {
    required String title,
    required String artist,
    String album = '',
    int? durationSeconds,
    String? videoId,
  }) {
    if (providerId == 'lrclib') {
      return super.fetchFromProvider(
        providerId,
        title: title,
        artist: artist,
        album: album,
        durationSeconds: durationSeconds,
        videoId: videoId,
      );
    }
    return Future.value(null);
  }
}

Dio _lrclibStubDio(String synced) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        final url = options.uri.toString();
        if (url.contains('itunes.apple.com')) {
          handler.resolve(Response(
              requestOptions: options,
              statusCode: 200,
              data: '{"resultCount":0,"results":[]}'));
          return;
        }
        if (url.contains('lrclib.net/api/get')) {
          handler.reject(DioException(
              requestOptions: options,
              type: DioExceptionType.badResponse,
              response: Response(
                  requestOptions: options, statusCode: 404)));
          return;
        }
        if (url.contains('lrclib.net/api/search')) {
          handler.resolve(Response(
              requestOptions: options,
              statusCode: 200,
              data: [
                {
                  'id': 9,
                  'trackName': 'Shape of You',
                  'artistName': 'Ed Sheeran',
                  'duration': 234.0,
                  'instrumental': false,
                  'plainLyrics': 'Hello world\nSecond line',
                  'syncedLyrics': synced,
                },
              ]));
          return;
        }
        handler.reject(DioException(
            requestOptions: options, type: DioExceptionType.unknown));
      },
    ),
  );
  return dio;
}

void main() {
  test('empty is never cached: retry refetches and recovers', () async {
    var open = false;
    final repo = _FlakyRepo(() async {
      if (!open) return null;
      return _line('lrclib');
    }, Dio());
    final first = await repo.getLyrics(title: 'T', artist: 'A');
    expect(first.isEmpty, isTrue);
    open = true;
    final second = await repo.getLyrics(title: 'T', artist: 'A');
    expect(second.isEmpty, isFalse);
    expect(second.source, contains('lrclib'));
  });

  test('LRCLIB enhanced LRC reports word-sync', () async {
    final repo = _LrclibOnlyRepo(_lrclibStubDio(
      '[00:01.00]<00:01.00>Hi <00:01.20>there\n[00:05.00]Yo\n',
    ));
    final result = await repo.getLyrics(
      title: 'Shape of You',
      artist: 'Ed Sheeran',
      wordByWord: true,
    );
    expect(result.isEmpty, isFalse);
    expect(result.isSynced, isTrue);
    expect(result.isWordSynced, isTrue);
  });

  test('LRCLIB plain LRC stays line-sync', () async {
    final repo = _LrclibOnlyRepo(_lrclibStubDio(
      '[00:01.00]Hello world\n[00:05.00]Second line\n[00:09.00]Third\n',
    ));
    final result = await repo.getLyrics(
      title: 'Shape of You',
      artist: 'Ed Sheeran',
      wordByWord: true,
    );
    expect(result.isEmpty, isFalse);
    expect(result.isSynced, isTrue);
    expect(result.isWordSynced, isFalse);
  });
}
