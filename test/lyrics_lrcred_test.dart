import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/lyrics/lyrics_providers.dart';

// Recorded 2026-10-06 from https://lrc.red/api/v1?q=Ed%20Sheeran%20-%20Shape%20of%20You
const _searchPayload = {
  'results': [
    {
      'album_name': 'Divide',
      'artist_name': 'Ed Sheeran',
      'duration': 234,
      'id': 'GBAHS1700003',
      'isrc': 'GBAHS1700003',
      'lyricsUrl': 'https://lrc.red/s/GBAHS1700003.ttml',
      'timing_type': 'word',
      'track_name': 'Shape of You',
    },
    {
      'album_name': 'Shape of You (Latin Remix) [feat. Zion & Lennox]',
      'artist_name': 'Ed Sheeran',
      'duration': 238,
      'id': 'GBAHS1700245',
      'isrc': 'GBAHS1700245',
      'lyricsUrl': 'https://lrc.red/s/GBAHS1700245.ttml',
      'timing_type': 'word',
      'track_name': 'Shape of You (Latin Remix) [feat. Zion & Lennox]',
    },
    {
      'album_name': 'Covers',
      'artist_name': 'Someone Else',
      'duration': 234,
      'id': 'XX0000000000',
      'isrc': 'XX0000000000',
      'lyricsUrl': 'https://lrc.red/s/XX0000000000.ttml',
      'timing_type': 'word',
      'track_name': 'Shape of You',
    },
  ],
  'source': 'HIT-LRC-RED',
  'total': 3,
};

const _wordTtml = '<tt xmlns="http://www.w3.org/ns/ttml"><body><div>'
    '<p begin="00:09.73" end="00:12.00">'
    '<span begin="00:09.73" end="00:10.00">The</span>'
    '<span begin="00:10.00" end="00:10.40">club</span></p>'
    '</div></body></tt>';

Dio _stubDio() {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        final url = options.uri.toString();
        if (url.startsWith('https://lrc.red/api/v1')) {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: _searchPayload,
            ),
          );
          return;
        }
        if (url.startsWith('https://lrc.red/s/')) {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: _wordTtml,
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

List<LrcRedHit> _hits() => ((_searchPayload['results']!) as List)
    .map((e) => LrcRedHit.fromJson(Map<String, dynamic>.from(e as Map)))
    .toList();

void main() {
  test('selectBest prefers exact word hit over remix and wrong artist', () {
    final best = selectLrcRedBest(
      _hits(),
      title: 'Shape of You',
      artist: 'Ed Sheeran',
      durationSeconds: 234,
    );
    expect(best, isNotNull);
    expect(best!.isrc, 'GBAHS1700003');
  });

  test('score floor rejects artist mismatch and remix', () {
    final hits = _hits();
    final wrongArtist = hits[2];
    expect(
      scoreLrcRedHit(wrongArtist,
          title: 'Shape of You', artist: 'Ed Sheeran'),
      lessThan(5),
    );
    final remix = hits[1];
    expect(
      selectLrcRedBest([remix],
          title: 'Shape of You', artist: 'Ed Sheeran', durationSeconds: 238),
      isNull,
    );
  });

  test('fetchLrcRed resolves word-sync end to end', () async {
    final result = await fetchLrcRed(
      _stubDio(),
      title: 'Shape of You',
      artist: 'Ed Sheeran',
      durationSeconds: 234,
    );
    expect(result, isNotNull);
    expect(result!.isWordSynced, isTrue);
    expect(result.isSynced, isTrue);
    expect(result.source, contains('Lrc.Red'));
    expect(result.lines.first.text, 'The club');
  });
}
