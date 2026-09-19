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
      expect(a.startsWith('anim5|'), isTrue);
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
        cacheKey: 'anim5|demo|album',
        url: 'https://cdn.example/a.m3u8',
        provider: 'anim',
      );
      final hit = db.loadArtworkRecord('anim5|demo|album');
      expect(hit?['url'], contains('.m3u8'));
      expect(hit?['provider'], 'anim');
      expect(hit?['timestamp_millis'], greaterThan(0));

      db.saveArtworkEntry(
        cacheKey: 'anim5|demo|album-none',
        url: '',
        provider: 'anim-miss',
      );
      final miss = db.loadArtworkRecord('anim5|demo|album-none');
      expect(miss?['url'], isEmpty);
      expect(miss?['provider'], 'anim-miss');
    });
  });

  group('AnimatedArtworkService cache', () {
    late Dio dio;
    late AppDatabase db;
    late int calls;
    late int status;
    late Map<String, dynamic> payload;

    setUp(() {
      calls = 0;
      status = 200;
      payload = {
        'url':
            'https://mvod.itunes.apple.com/itunes-assets/x/P1_default.m3u8',
      };
      dio = Dio();
      dio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          calls++;
          if (options.uri.host == 'itunes.apple.com') {
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
  });
}
