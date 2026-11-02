import 'dart:convert';

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

String _makeFakeJwt() {
  final header = base64Url
      .encode(utf8.encode('{"alg":"ES256","kid":"WebPlayKid"}'))
      .replaceAll('=', '');
  final exp = (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 3600;
  final payload = base64Url
      .encode(utf8.encode('{"iss":"AMPWebPlay","exp":$exp}'))
      .replaceAll('=', '');
  return '$header.$payload.signature';
}

void main() {
  group('CanvasMatchingTest parity', () {
    test('normalizeCanvasMatch strips accents, punctuation and case', () {
      const raw = 'Beyoncé - CRAZY IN LOVE (feat. JAY-Z)';
      final normalized = normalizeCanvasMatch(raw);
      expect(normalized, 'beyonce crazy in love feat jay z');
    });

    test('splitCanvasArtists splits across feat, &, and x', () {
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

    test('AnimatedArtwork.matches validates title, artist and album', () {
      const canvas = AnimatedArtwork(
        url: 'https://example.com/loop.mp4',
        title: 'Crazy In Love',
        artist: 'Beyoncé ft. Jay-Z',
        album: 'Dangerously in Love',
        source: CanvasSource.apple,
      );

      expect(
        canvas.matches(
          wantTitle: 'Crazy in Love',
          wantArtist: 'Beyonce',
          wantAlbum: 'Dangerously In Love',
        ),
        isTrue,
      );

      expect(
        canvas.matches(
          wantTitle: 'Halo',
          wantArtist: 'Beyonce',
          wantAlbum: 'Dangerously In Love',
        ),
        isFalse,
      );
    });

    test('TidalCanvas.coverUrl formats UUID into 1280x1280 mp4 URL', () {
      const uuid = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890';
      const expected =
          'https://resources.tidal.com/videos/a1b2c3d4/e5f6/7890/abcd/ef1234567890/1280x1280.mp4';
      expect(TidalCanvas.coverUrl(uuid), expected);
      expect(TidalCanvas.coverUrl('invalid-uuid'), isNull);
    });
  });

  group('parseAnimatedArtworkPayload', () {
    test('reads square HLS url and tall variant', () {
      final art = parseAnimatedArtworkPayload({
        'url':
            'https://mvod.itunes.apple.com/itunes-assets/HLSMusic211/v4/x/P1_default.m3u8',
        'url_tall':
            'https://mvod.itunes.apple.com/itunes-assets/HLSMusic211/v4/y/P2_default.m3u8',
        'artist': 'Gorillaz',
        'album': 'Plastic Beach',
        'isCached': true,
      });
      expect(art, isNotNull);
      expect(art!.url, contains('P1_default.m3u8'));
      expect(art.urlTall, contains('P2_default.m3u8'));
    });

    test('rejects missing or non-HLS urls', () {
      expect(parseAnimatedArtworkPayload(null), isNull);
      expect(parseAnimatedArtworkPayload({'url': ''}), isNull);
      expect(
        parseAnimatedArtworkPayload({'url': 'https://example.com/cover.jpg'}),
        isNull,
      );
    });
  });

  group('pickAnimatedArtworkStream', () {
    test('prefers mid-size H.264 over iframe and 4K HEVC', () {
      expect(
        pickAnimatedArtworkStream(_masterPlaylist),
        'https://cdn.example/avc486.m3u8',
      );
    });

    test('extracts the fMP4 from a byterange variant playlist', () {
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
          variantUrl:
              'https://cdn.example/dir/P1_Anull_video_gr210_sdr_486x486.m3u8',
        ),
        'https://cdn.example/dir/clip-.mp4',
      );
    });
  });

  group('animatedArtworkCacheKey', () {
    test('same album shares a key regardless of title', () {
      final a = animatedArtworkCacheKey(
        artist: 'Gorillaz',
        album: 'Plastic Beach',
        title: 'On Melancholy Hill (Official Video)',
      );
      final b = animatedArtworkCacheKey(
        artist: 'gorillaz',
        album: 'plastic beach',
        title: 'Rhinestone Eyes',
      );
      expect(a.startsWith('anim6|'), isTrue);
      expect(a, b);
      expect(
        animatedArtworkCacheKey(
          artist: 'Gorillaz',
          album: 'Demon Days',
          title: 'Feel Good Inc.',
        ),
        isNot(a),
      );
    });

    test('query equality follows the album cache key', () {
      const a = AnimatedArtworkQuery(
        artist: 'Metro Boomin',
        album: 'Heroes & Villains',
        title: 'Superhero',
      );
      const b = AnimatedArtworkQuery(
        artist: 'metro boomin',
        album: 'heroes & villains',
        title: 'Too Many Nights',
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });

  group('disk cache', () {
    test('round-trips hit and miss rows', () {
      final db = AppDatabase.inMemory();
      addTearDown(db.close);
      db.saveArtworkEntry(
        cacheKey: 'anim6|demo|album',
        url: 'https://cdn.example/a.m3u8',
        provider: 'anim',
      );
      final hit = db.loadArtworkRecord('anim6|demo|album');
      expect(hit?['url'], contains('.m3u8'));
      expect(hit?['provider'], 'anim');
      expect(hit?['timestamp_millis'], greaterThan(0));

      db.saveArtworkEntry(
        cacheKey: 'anim6|demo|album-none',
        url: '',
        provider: 'anim-miss',
      );
      final miss = db.loadArtworkRecord('anim6|demo|album-none');
      expect(miss?['url'], isEmpty);
      expect(miss?['provider'], 'anim-miss');
    });
  });

  group('AnimatedArtworkService cache & waterfall priority', () {
    late Dio dio;
    late AppDatabase db;
    late int calls;
    late int status;
    late Map<String, dynamic> payload;

    setUp(() {
      AppleMusicCanvas.resetForTesting();
      CommunityCanvas.resetForTesting();
      calls = 0;
      status = 200;
      payload = {
        'url':
            'https://mvod.itunes.apple.com/itunes-assets/x/P1_default.m3u8',
      };
      dio = Dio();
      dio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          final host = options.uri.host;
          if (host == 'music.apple.com' ||
              host == 'amp-api.music.apple.com' ||
              host == 'api.tidal.com' ||
              host == 'vivimusicanvas.mkmdevilmi.workers.dev') {
            handler.resolve(Response<String>(
              requestOptions: options,
              statusCode: 404,
              data: '',
            ));
            return;
          }
          calls++;
          if (host == 'itunes.apple.com') {
            handler.resolve(Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: const {'results': []},
            ));
            return;
          }
          if (options.uri.path.contains('/api/')) {
            handler.resolve(Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: status,
              data: Map<String, dynamic>.from(payload),
            ));
            return;
          }
          handler.resolve(Response<String>(
            requestOptions: options,
            statusCode: 200,
            data: _masterPlaylist,
          ));
        },
      ));
      db = AppDatabase.inMemory();
    });

    tearDown(() => db.close());

    const query = AnimatedArtworkQuery(
      artist: 'Gorillaz',
      album: 'Plastic Beach',
      title: 'On Melancholy Hill',
    );

    test('memory cache skips a second network lookup', () async {
      final service = AnimatedArtworkService(dio: dio, db: db);
      final first = await service.lookup(query);
      final second = await service.lookup(query);
      expect(first?.url, 'https://cdn.example/avc486.m3u8');
      expect(second?.url, first?.url);
      expect(calls, 3);
    });

    test('404 is negatively cached and not refetched', () async {
      status = 404;
      final service = AnimatedArtworkService(dio: dio, db: db);
      expect(await service.lookup(query), isNull);
      expect(await service.lookup(query), isNull);
      expect(calls, 3);

      final other = AnimatedArtworkService(dio: dio, db: db);
      expect(await other.lookup(query), isNull);
      expect(calls, 3);
    });

    test('in-flight lookups share one request', () async {
      final service = AnimatedArtworkService(dio: dio, db: db);
      final results = await Future.wait([
        service.lookup(query),
        service.lookup(query),
      ]);
      expect(results[0]?.url, 'https://cdn.example/avc486.m3u8');
      expect(results[1]?.url, results[0]?.url);
      expect(calls, 3);
    });

    test('second track on the same album reuses the cached clip', () async {
      final service = AnimatedArtworkService(dio: dio, db: db);
      await service.lookup(query);
      final next = await service.lookup(const AnimatedArtworkQuery(
        artist: 'Gorillaz',
        album: 'Plastic Beach',
        title: 'Rhinestone Eyes',
      ));
      expect(next?.url, 'https://cdn.example/avc486.m3u8');
      expect(calls, 3);
    });

    test('lookupByUrl hits the url endpoint once', () async {
      final service = AnimatedArtworkService(dio: dio, db: db);
      const apple =
          'https://music.apple.com/us/album/plastic-beach/1440873138?i=1440873316';
      final first = await service.lookupByUrl(apple);
      final second = await service.lookupByUrl(apple);
      expect(first?.url, 'https://cdn.example/avc486.m3u8');
      expect(second?.url, first?.url);
      expect(calls, 3);
    });

    test('falls back to album-only search after a title miss', () async {
      dio.interceptors.clear();
      dio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          final host = options.uri.host;
          if (host == 'music.apple.com' ||
              host == 'amp-api.music.apple.com' ||
              host == 'api.tidal.com' ||
              host == 'vivimusicanvas.mkmdevilmi.workers.dev') {
            handler.resolve(Response<String>(
              requestOptions: options,
              statusCode: 404,
              data: '',
            ));
            return;
          }
          calls++;
          if (options.uri.path.contains('/api/')) {
            final hasTitle =
                options.uri.queryParameters['title']?.isNotEmpty == true;
            handler.resolve(Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: hasTitle ? 404 : 200,
              data: hasTitle
                  ? <String, dynamic>{}
                  : Map<String, dynamic>.from(payload),
            ));
            return;
          }
          handler.resolve(Response<String>(
            requestOptions: options,
            statusCode: 200,
            data: _masterPlaylist,
          ));
        },
      ));
      final service = AnimatedArtworkService(dio: dio, db: db);
      final art = await service.lookup(query);
      expect(art?.url, 'https://cdn.example/avc486.m3u8');
      expect(calls, 4);
    });

    test('enforces priority Apple Music > Tidal > Community', () async {
      var enableApple = true;
      var enableTidal = true;
      var enableCommunity = true;
      final fakeJwt = _makeFakeJwt();

      void configurePriorityDio() {
        AppleMusicCanvas.resetForTesting();
        CommunityCanvas.resetForTesting();
        dio.interceptors.clear();
        dio.interceptors.add(InterceptorsWrapper(
          onRequest: (options, handler) {
            final host = options.uri.host;
            final path = options.uri.path;

            if (host == 'music.apple.com' && path == '/us/browse') {
              handler.resolve(Response<String>(
                requestOptions: options,
                statusCode: enableApple ? 200 : 404,
                data: enableApple
                    ? '<script src="/assets/index-abc123.js"></script>'
                    : '',
              ));
              return;
            }
            if (host == 'music.apple.com' && path.startsWith('/assets/')) {
              handler.resolve(Response<String>(
                requestOptions: options,
                statusCode: 200,
                data: 'const token = "$fakeJwt";',
              ));
              return;
            }
            if (host == 'amp-api.music.apple.com') {
              handler.resolve(Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: enableApple ? 200 : 404,
                data: enableApple
                    ? {
                        'results': {
                          'songs': {
                            'data': [
                              {
                                'id': '1',
                                'attributes': {
                                  'name': 'On Melancholy Hill',
                                  'artistName': 'Gorillaz',
                                  'albumName': 'Plastic Beach',
                                  'editorialVideo': {
                                    'motionDetailSquare': {
                                      'video':
                                          'https://mvod.itunes.apple.com/apple_square.m3u8',
                                    },
                                  },
                                },
                              },
                            ],
                          },
                        },
                      }
                    : const {},
              ));
              return;
            }
            if (host == 'artwork.m8tec.top' || host == 'itunes.apple.com') {
              handler.resolve(Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 404,
                data: const {},
              ));
              return;
            }
            if (host == 'api.tidal.com') {
              handler.resolve(Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: enableTidal ? 200 : 404,
                data: enableTidal
                    ? {
                        'tracks': {
                          'items': [
                            {
                              'title': 'On Melancholy Hill',
                              'artists': [
                                {'name': 'Gorillaz'},
                              ],
                              'album': {
                                'title': 'Plastic Beach',
                                'videoCover':
                                    '11111111-2222-3333-4444-555555555555',
                              },
                            },
                          ],
                        },
                      }
                    : const {},
              ));
              return;
            }
            if (host == 'vivimusicanvas.mkmdevilmi.workers.dev') {
              handler.resolve(Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: enableCommunity ? 200 : 404,
                data: enableCommunity
                    ? {
                        'items': [
                          {
                            'song': 'On Melancholy Hill',
                            'artist': 'Gorillaz',
                            'album': 'Plastic Beach',
                            'url': 'https://community.example/melancholy.mp4',
                          },
                        ],
                      }
                    : const {},
              ));
              return;
            }
            handler.resolve(Response<String>(
              requestOptions: options,
              statusCode: 200,
              data: _masterPlaylist,
            ));
          },
        ));
      }

      // 1. All 3 enabled -> Apple Music wins
      configurePriorityDio();
      final svc1 = AnimatedArtworkService(
        dio: dio,
        db: AppDatabase.inMemory(),
      );
      final res1 = await svc1.lookup(query);
      expect(res1?.source, CanvasSource.apple);
      expect(res1?.url, 'https://cdn.example/avc486.m3u8');

      // 2. Apple disabled, Tidal + Community enabled -> Tidal wins
      enableApple = false;
      enableTidal = true;
      enableCommunity = true;
      configurePriorityDio();
      final svc2 = AnimatedArtworkService(
        dio: dio,
        db: AppDatabase.inMemory(),
      );
      final res2 = await svc2.lookup(query);
      expect(res2?.source, CanvasSource.tidal);
      expect(
        res2?.url,
        'https://resources.tidal.com/videos/11111111/2222/3333/4444/555555555555/1280x1280.mp4',
      );

      // 3. Apple + Tidal disabled, Community enabled -> Community wins
      enableApple = false;
      enableTidal = false;
      enableCommunity = true;
      configurePriorityDio();
      final svc3 = AnimatedArtworkService(
        dio: dio,
        db: AppDatabase.inMemory(),
      );
      final res3 = await svc3.lookup(query);
      expect(res3?.source, CanvasSource.community);
      expect(res3?.url, 'https://community.example/melancholy.mp4');
    });

    test('matches Starboy by The Weeknd, Daft Punk in Community Canvas and shares cache across album', () async {
      var communityManifestCalls = 0;
      CommunityCanvas.resetForTesting();
      dio.interceptors.clear();
      dio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          final host = options.uri.host;
          if (host == 'vivimusicanvas.mkmdevilmi.workers.dev') {
            communityManifestCalls++;
            handler.resolve(Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: const {
                'items': [
                  {
                    'song': 'Starboy (feat. Daft Punk)',
                    'artist': 'The Weeknd',
                    'album': 'Starboy',
                    'url': 'https://vivimusicanvas.mkmdevilmi.workers.dev/Song/16.mp4',
                  },
                ],
              },
            ));
            return;
          }
          handler.resolve(Response<Map<String, dynamic>>(
            requestOptions: options,
            statusCode: 404,
            data: const {},
          ));
        },
      ));

      final svc = AnimatedArtworkService(
        dio: dio,
        db: AppDatabase.inMemory(),
        albumLookup: (title, artist) async => 'Starboy',
      );

      // 1. Lookup Starboy with YTM multi-artist credit and empty initial album
      const starboyQuery = AnimatedArtworkQuery(
        artist: 'The Weeknd, Daft Punk',
        album: '',
        title: 'Starboy',
      );
      final starboyArt = await svc.lookup(starboyQuery);
      expect(starboyArt, isNotNull);
      expect(starboyArt?.source, CanvasSource.community);
      expect(
        starboyArt?.url,
        'https://vivimusicanvas.mkmdevilmi.workers.dev/Song/16.mp4',
      );
      expect(communityManifestCalls, 1);

      // 2. Subsequent track on the same album reuses the cached album canvas
      // immediately without re-querying providers
      const nextTrackOnAlbum = AnimatedArtworkQuery(
        artist: 'The Weeknd',
        album: 'Starboy',
        title: 'Party Monster',
      );
      expect(svc.isCached(nextTrackOnAlbum), isTrue);
      expect(
        svc.peek(nextTrackOnAlbum)?.url,
        'https://vivimusicanvas.mkmdevilmi.workers.dev/Song/16.mp4',
      );
    });
  });
}
