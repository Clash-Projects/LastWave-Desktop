import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/artwork/animated_artwork_service.dart';
import 'package:lastwave_desktop/core/storage/app_database.dart';

const _masterPlaylist = '''
#EXTM3U
#EXT-X-I-FRAME-STREAM-INF:CODECS="avc1.64001f",RESOLUTION=486x486,URI="https://cdn.example/iframes.m3u8"
#EXT-X-STREAM-INF:CODECS="hvc1.2.20000000.H150.B0",RESOLUTION=2160x2160
https://cdn.example/hevc4k.m3u8
#EXT-X-STREAM-INF:CODECS="avc1.64001f",RESOLUTION=486x486
https://cdn.example/avc486.m3u8
#EXT-X-STREAM-INF:CODECS="avc1.64001f",RESOLUTION=1080x1080
https://cdn.example/avc1080.m3u8
''';

void main() {
  group('Canvas matching', () {
    test('normalizes accents, punctuation and case', () {
      expect(
        normalizeCanvasMatch('Beyoncé - CRAZY IN LOVE (feat. JAY-Z)'),
        'beyonce crazy in love feat jay z',
      );
    });

    test('splits featured and collaborative artists', () {
      expect(
        splitCanvasArtists('Taylor Swift feat. Post Malone'),
        ['taylor swift', 'post malone'],
      );
      expect(
        splitCanvasArtists('Daft Punk & Pharrell Williams'),
        ['daft punk', 'pharrell williams'],
      );
      expect(
        splitCanvasArtists('Marshmello x Khalid'),
        ['marshmello', 'khalid'],
      );
    });

    test('validates title, artist and album', () {
      const art = AnimatedArtwork(
        url: 'https://example.com/loop.mp4',
        title: 'Crazy In Love',
        artist: 'Beyoncé ft. Jay-Z',
        album: 'Dangerously in Love',
        source: CanvasSource.community,
      );
      expect(
        art.matches(
          wantTitle: 'Crazy in Love',
          wantArtist: 'Beyonce',
          wantAlbum: 'Dangerously In Love',
        ),
        isTrue,
      );
      expect(
        art.matches(
          wantTitle: 'Halo',
          wantArtist: 'Beyonce',
          wantAlbum: 'Dangerously In Love',
        ),
        isFalse,
      );
    });
  });

  group('TIDAL motion artwork', () {
    test('formats UUID into a 1280x1280 MP4 URL', () {
      expect(
        TidalCanvas.coverUrl('a1b2c3d4-e5f6-7890-abcd-ef1234567890'),
        'https://resources.tidal.com/videos/a1b2c3d4/e5f6/7890/abcd/ef1234567890/1280x1280.mp4',
      );
      expect(TidalCanvas.coverUrl('invalid-uuid'), isNull);
    });
  });

  group('HLS helpers', () {
    test('prefers mid-size H.264 over trick-play and 4K HEVC', () {
      expect(
        pickAnimatedArtworkStream(_masterPlaylist),
        'https://cdn.example/avc486.m3u8',
      );
    });

    test('extracts the fMP4 from a byte-range variant playlist', () {
      const variant = '''
#EXTM3U
#EXT-X-MAP:URI="clip-.mp4",BYTERANGE="898@0"
#EXTINF:3.5,
clip-.mp4
#EXT-X-ENDLIST
''';
      expect(
        pickAnimatedArtworkFile(
          variant,
          variantUrl: 'https://cdn.example/dir/variant.m3u8',
        ),
        'https://cdn.example/dir/clip-.mp4',
      );
    });
  });

  group('cache keys', () {
    test('tracks on the same album share a cache key', () {
      final first = animatedArtworkCacheKey(
        artist: 'Gorillaz',
        album: 'Plastic Beach',
        title: 'On Melancholy Hill',
      );
      final second = animatedArtworkCacheKey(
        artist: 'gorillaz',
        album: 'plastic beach',
        title: 'Rhinestone Eyes',
      );
      expect(first, second);
      expect(
        animatedArtworkCacheKey(
          artist: 'Gorillaz',
          album: 'Demon Days',
          title: 'Feel Good Inc.',
        ),
        isNot(first),
      );
    });

    test('queries with same album compare equal', () {
      const first = AnimatedArtworkQuery(
        artist: 'Metro Boomin',
        album: 'Heroes & Villains',
        title: 'Superhero',
      );
      const second = AnimatedArtworkQuery(
        artist: 'metro boomin',
        album: 'heroes & villains',
        title: 'Too Many Nights',
      );
      expect(first, second);
      expect(first.hashCode, second.hashCode);
    });
  });

  group('disk cache', () {
    test('round-trips TIDAL hits and misses', () {
      final db = AppDatabase.inMemory();
      addTearDown(db.close);
      db.saveArtworkEntry(
        cacheKey: 'anim6|demo|album',
        url: 'https://resources.tidal.com/videos/demo/1280x1280.mp4',
        provider: 'anim-tidal',
      );
      final hit = db.loadArtworkRecord('anim6|demo|album');
      expect(hit?['url'], contains('.mp4'));
      expect(hit?['provider'], 'anim-tidal');

      db.saveArtworkEntry(
        cacheKey: 'anim6|demo|album-none',
        url: '',
        provider: 'anim-v2-miss',
      );
      final miss = db.loadArtworkRecord('anim6|demo|album-none');
      expect(miss?['url'], isEmpty);
      expect(miss?['provider'], 'anim-v2-miss');
    });
  });

  group('AnimatedArtworkService', () {
    const query = AnimatedArtworkQuery(
      artist: 'Gorillaz',
      album: 'Plastic Beach',
      title: 'On Melancholy Hill',
    );

    test('uses TIDAL first and reuses its cached album artwork', () async {
      final dio = Dio();
      var tidalCalls = 0;
      var communityCalls = 0;
      dio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.uri.host == 'api.tidal.com') {
            tidalCalls++;
            handler.resolve(Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: {
                'tracks': {
                  'items': [
                    {
                      'title': 'On Melancholy Hill',
                      'artists': [{'name': 'Gorillaz'}],
                      'album': {
                        'title': 'Plastic Beach',
                        'videoCover': '11111111-2222-3333-4444-555555555555',
                      },
                    },
                  ],
                },
              },
            ));
            return;
          }
          if (options.uri.host == 'vivimusicanvas.mkmdevilmi.workers.dev') {
            communityCalls++;
          }
          handler.resolve(Response<Map<String, dynamic>>(
            requestOptions: options,
            statusCode: 404,
            data: const {},
          ));
        },
      ));

      final service = AnimatedArtworkService(dio: dio);
      final first = await service.lookup(query);
      expect(first?.source, CanvasSource.tidal);
      expect(
        first?.url,
        'https://resources.tidal.com/videos/11111111/2222/3333/4444/555555555555/1280x1280.mp4',
      );
      expect(tidalCalls, 1);
      expect(communityCalls, 0);

      final next = await service.lookup(const AnimatedArtworkQuery(
        artist: 'Gorillaz',
        album: 'Plastic Beach',
        title: 'Rhinestone Eyes',
      ));
      expect(next?.url, first?.url);
      expect(tidalCalls, 1);
    });

    test('falls back to Community Canvas when TIDAL has no match', () async {
      CommunityCanvas.resetForTesting();
      final dio = Dio();
      dio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.uri.host == 'api.tidal.com') {
            handler.resolve(Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: const {'tracks': {'items': []}},
            ));
            return;
          }
          handler.resolve(Response<Map<String, dynamic>>(
            requestOptions: options,
            statusCode: 200,
            data: const {
              'items': [
                {
                  'song': 'On Melancholy Hill',
                  'artist': 'Gorillaz',
                  'album': 'Plastic Beach',
                  'url': 'https://community.example/melancholy.mp4',
                },
              ],
            },
          ));
        },
      ));

      final service = AnimatedArtworkService(dio: dio);
      final result = await service.lookup(query);
      expect(result?.source, CanvasSource.community);
      expect(result?.url, 'https://community.example/melancholy.mp4');
    });

    test('does not repeat a negative lookup for the same key', () async {
      CommunityCanvas.resetForTesting();
      final dio = Dio();
      var calls = 0;
      dio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          calls++;
          handler.resolve(Response<Map<String, dynamic>>(
            requestOptions: options,
            statusCode: 200,
            data: const {
              'tracks': {'items': []},
              'items': [],
            },
          ));
        },
      ));
      final service = AnimatedArtworkService(dio: dio);
      expect(await service.lookup(query), isNull);
      final firstCalls = calls;
      expect(firstCalls, greaterThan(0));
      expect(await service.lookup(query), isNull);
      expect(calls, firstCalls);
    });
  });

  test('Starboy multi-artist credits match Community Canvas', () {
    const art = AnimatedArtwork(
      url: 'https://community.example/starboy.mp4',
      title: 'Starboy (feat. Daft Punk)',
      artist: 'The Weeknd',
      album: 'Starboy',
      source: CanvasSource.community,
    );
    expect(
      art.matches(
        wantTitle: 'Starboy',
        wantArtist: 'The Weeknd, Daft Punk',
        wantAlbum: 'Starboy',
      ),
      isTrue,
    );
  });
}
