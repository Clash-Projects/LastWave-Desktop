import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/artwork/artwork_resolver.dart';
import 'package:lastwave_desktop/core/artwork/official_artwork_service.dart';
import 'package:lastwave_desktop/core/audio/stream_models.dart';
import 'package:lastwave_desktop/core/storage/app_database.dart';

Dio _deezerArtworkStub() {
  final dio = Dio();
  dio.interceptors.add(InterceptorsWrapper(
    onRequest: (options, handler) {
      handler.resolve(Response(
        requestOptions: options,
        statusCode: 200,
        data: {
          'data': [
            {
              'title': 'All Caps',
              'artist': {'name': 'Madvillain'},
              'album': {
                'title': 'Madvillainy',
                'cover_xl':
                    'https://cdn-images.dzcdn.net/images/cover/madvillainy/1000x1000.jpg',
              },
            },
          ],
        },
      ));
    },
  ));
  return dio;
}

void main() {
  group('ArtworkResolver official priority & sizing', () {
    test('prioritizes official Deezer art over YouTube thumbnails', () {
      final req = ArtworkRequest(
        kind: ArtworkKind.track,
        candidates: [
          'https://i.ytimg.com/vi/video12345/hqdefault.jpg',
          'https://cdn-images.dzcdn.net/images/cover/abc/1000x1000.jpg',
        ],
        videoId: 'video12345',
        targetPx: 640,
      );
      final resolved = ArtworkResolver.resolve(req);
      expect(resolved.urls, isNotEmpty);
      expect(resolved.urls.first, contains('dzcdn.net'));

      final ytIndex = resolved.urls.indexWhere((u) => u.contains('ytimg.com'));
      final deezerIndex = resolved.urls.indexWhere((u) => u.contains('dzcdn.net'));
      expect(deezerIndex, lessThan(ytIndex));
    });

    test('rejects legacy Apple Music artwork URLs', () {
      expect(
        ArtworkResolver.normalize(
          'https://is1-ssl.mzstatic.com/image/thumb/cover.jpg/100x100bb.jpg',
        ),
        isNull,
      );
      expect(
        ArtworkResolver.normalize('https://itunes.apple.com/lookup?id=123'),
        isNull,
      );
    });

    test('sizes Qobuz cover URLs to large resolution', () {
      const original =
          'https://static.qobuz.com/images/covers/00/00/0000000000000_230.jpg';
      final sized = ArtworkResolver.sized(original, 600);
      expect(
        sized,
        'https://static.qobuz.com/images/covers/00/00/0000000000000_600.jpg',
      );
    });

    test('normalize rejects Last.fm placeholder star URLs', () {
      const starPlaceholder =
          'https://lastfm.freetls.fastly.net/i/u/300x300/2a96cbd8b46e442fc41c2b86b821562f.png';
      expect(ArtworkResolver.normalize(starPlaceholder), isNull);

      const defaultAlbum = 'https://example.com/images/default_album.png';
      expect(ArtworkResolver.normalize(defaultAlbum), isNull);

      const noImage = 'https://example.com/assets/noimage.jpg';
      expect(ArtworkResolver.normalize(noImage), isNull);
    });
  });

  group('OfficialArtworkService', () {
    test('isOfficialArtwork identifies official and non-official CDNs', () {
      expect(
        OfficialArtworkService.isOfficialArtwork(
          'https://static.qobuz.com/images/covers/cover_600.jpg',
        ),
        isFalse,
      );
      expect(
        OfficialArtworkService.isOfficialArtwork(
          'https://static.qobuz.com/images/covers/cover_600.jpg',
        ),
        isTrue,
      );
      expect(
        OfficialArtworkService.isOfficialArtwork(
          'https://i.scdn.co/image/ab67616d0000b273...',
        ),
        isTrue,
      );
      expect(
        OfficialArtworkService.isOfficialArtwork(
          'https://i.ytimg.com/vi/video12345/hqdefault.jpg',
        ),
        isFalse,
      );
      expect(
        OfficialArtworkService.isOfficialArtwork(
          'https://lh3.googleusercontent.com/some-yt-thumb',
        ),
        isFalse,
      );
      expect(OfficialArtworkService.isOfficialArtwork(''), isFalse);
    });

    test('isOfficialArtistPhoto is Deezer artist CDN only', () {
      expect(
        OfficialArtworkService.isOfficialArtistPhoto(
          'https://cdn-images.dzcdn.net/images/artist/abc/1000x1000.jpg',
        ),
        isTrue,
      );
      expect(
        OfficialArtworkService.isOfficialArtistPhoto(
          'https://cdn-images.dzcdn.net/images/cover/abc/1000x1000.jpg',
        ),
        isFalse,
      );
      expect(
        OfficialArtworkService.isOfficialArtistPhoto(
          'https://is1-ssl.mzstatic.com/image/thumb/cover.jpg/100x100bb.jpg',
        ),
        isFalse,
      );
      expect(OfficialArtworkService.isOfficialArtistPhoto(''), isFalse);
    });

    test('primaryArtistName and splitArtistCredits', () {
      expect(
        OfficialArtworkService.primaryArtistName(
          'Drake, Future & Metro Boomin',
        ),
        'Drake',
      );
      expect(
        OfficialArtworkService.primaryArtistName('Tyler, The Creator'),
        'Tyler, The Creator',
      );
      expect(
        OfficialArtworkService.primaryArtistName('Metro Boomin'),
        'Metro Boomin',
      );
      expect(
        OfficialArtworkService.splitArtistCredits(
          'Drake, Future & Metro Boomin',
        ).toList(),
        ['Drake', 'Future', 'Metro Boomin'],
      );
      expect(
        OfficialArtworkService.splitArtistCredits('Tyler, The Creator')
            .toList(),
        ['Tyler, The Creator'],
      );
      expect(OfficialArtworkService.splitArtistCredits('Madvillain').toList(), [
        'Madvillain',
      ]);
    });

    test(
      'stale YouTube cache is ignored so All Caps can resolve Deezer art',
      () async {
        final db = AppDatabase.inMemory();
        final service = OfficialArtworkService(_deezerArtworkStub(), db);
        db.saveArtworkEntry(
          cacheKey: 't5|madvillain|all caps',
          url: 'https://i.ytimg.com/vi/video12345/hqdefault.jpg',
          provider: 'innertube',
        );
        final result = await service.resolveOfficialArtwork(
          title: 'All Caps',
          artist: 'Madvillain',
        );
        expect(result, isNotNull);
        expect(
          OfficialArtworkService.isOfficialArtwork(result!.artworkUrl),
          isTrue,
        );
        expect(result.artworkUrl.contains('ytimg.com'), isFalse);
        db.close();
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test('does not steal another song cover via substring titles', () {
      expect(
        OfficialArtworkService.artworkTitleScore(
          'Cinderella (feat. Ty Dolla \$ign)',
          'Cider',
        ),
        0,
      );
      expect(
        OfficialArtworkService.artworkTitleScore(
          'Wisakda Me (Piranha, Pt. 2)',
          'Piranha',
        ),
        0,
      );
      expect(
        OfficialArtworkService.artworkTitleScore(
          'Piranha (feat. Tikx Kooda)',
          'Piranah',
        ),
        greaterThanOrEqualTo(90),
      );
      expect(
        OfficialArtworkService.artworkArtistScore('Zane', 'Zany Inzane'),
        0,
      );
      expect(
        OfficialArtworkService.artworkArtistScore('Zany Inzane', 'Zany Inzane'),
        100,
      );

      final piranha = OfficialArtworkService.pickBestTrackArtwork(
        [
          {
            'trackName': 'Wisakda Me (Piranha, Pt. 2)',
            'artistName': 'Zany Inzane',
            'collectionName': 'Kushcobar',
            'artworkUrl100': 'https://cdn-images.dzcdn.net/images/cover/wrong/1000x1000.jpg',
          },
          {
            'trackName': 'Piranha (feat. Tikx Kooda)',
            'artistName': 'Zany Inzane',
            'collectionName': 'Piranha (feat. Tikx Kooda) - Single',
            'artworkUrl100': 'https://cdn-images.dzcdn.net/images/cover/right/1000x1000.jpg',
          },
        ],
        title: 'Piranah',
        artist: 'Zany Inzane',
      );
      expect(piranha, isNotNull);
      expect(piranha!['collectionName'], isNot(contains('Kushcobar')));

      final cider = OfficialArtworkService.pickBestTrackArtwork(
        [
          {
            'trackName': 'Cinderella (feat. Ty Dolla \$ign)',
            'artistName': 'Mac Miller',
            'collectionName': 'The Divine Feminine',
            'artworkUrl100': 'https://cdn-images.dzcdn.net/images/cover/cinderella/1000x1000.jpg',
          },
          {
            'trackName': 'Cider',
            'artistName': 'Yezi',
            'collectionName': 'Foresight Dream - EP',
            'artworkUrl100': 'https://cdn-images.dzcdn.net/images/cover/yezi/1000x1000.jpg',
          },
          {
            'trackName': 'Cider',
            'artistName': 'Zany Inzane',
            'collectionName': 'Cider',
            'artworkUrl100':
                'https://cdn-images.dzcdn.net/images/cover/right/1000x1000.jpg',
          },
        ],
        title: 'Cider',
        artist: 'Zany Inzane',
      );
      expect(cider, isNotNull);
      expect(cider!['artistName'], 'Zany Inzane');
      expect(cider['collectionName'], 'Cider');
    });

    test('normalizeForSearch strips noise and featured artists', () {
      expect(
        OfficialArtworkService.normalizeForSearch(
          'Overdue (feat. Travis Scott) [Official Music Video]',
        ),
        'overdue',
      );
      expect(
        OfficialArtworkService.normalizeForSearch(
          'Metro Boomin - Space Cadet (Remastered)',
        ),
        'space cadet',
      );
    });

    test(
      'live lookup: Metro Boomin and Madvillain return Deezer artist photos',
      () async {
        final service = OfficialArtworkService();
        final metro = await service.resolveArtistArtwork('Metro Boomin');
        expect(metro, isNotNull);
        expect(metro!.artworkUrl, contains('dzcdn.net'));
        expect(
          OfficialArtworkService.isOfficialArtistPhoto(metro.artworkUrl),
          isTrue,
        );

        final mad = await service.resolveArtistArtwork('Madvillain');
        expect(mad, isNotNull);
        expect(mad!.artworkUrl, contains('dzcdn.net'));
        expect(
          OfficialArtworkService.isOfficialArtistPhoto(mad.artworkUrl),
          isTrue,
        );
        // Must not be an album sleeve.
        expect(mad.artworkUrl.contains('/images/cover/'), isFalse);
      },
      timeout: const Timeout(Duration(seconds: 20)),
    );

    test(
      'live lookup: Metro Boomin - Overdue returns official album cover',
      () async {
        final service = OfficialArtworkService();
        final result = await service.resolveOfficialArtwork(
          title: 'Overdue (feat. Travis Scott)',
          artist: 'Metro Boomin',
        );

        expect(result, isNotNull);
        expect(
          OfficialArtworkService.isOfficialArtwork(result!.artworkUrl),
          isTrue,
        );
        expect(result.artworkUrl.contains('ytimg.com'), isFalse);
        expect(
          result.albumTitle.toLowerCase(),
          contains('not all heroes wear capes'),
        );
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test(
      'live lookup: Madvillain - All Caps returns official studio album cover',
      () async {
        final service = OfficialArtworkService();
        final result = await service.resolveOfficialArtwork(
          title: 'All Caps',
          artist: 'Madvillain',
        );

        expect(result, isNotNull);
        expect(
          OfficialArtworkService.isOfficialArtwork(result!.artworkUrl),
          isTrue,
        );
        expect(result.artworkUrl.contains('ytimg.com'), isFalse);
        expect(result.albumTitle.toLowerCase(), contains('madvillainy'));
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test('persists artwork to AppDatabase and reuses it', () async {
      final db = AppDatabase.inMemory();
      final service = OfficialArtworkService(null, db);

      // Save an entry (track cache keys are versioned: t5|artist|title)
      db.saveArtworkEntry(
        cacheKey: 't5|madvillain|all caps',
        url: 'https://cdn-images.dzcdn.net/images/cover/madvillainy/1000x1000.jpg',
        provider: 'deezer',
      );

      final loaded = db.loadArtworkEntry('t5|madvillain|all caps');
      expect(loaded, isNotNull);
      expect(loaded!['url'], contains('madvillainy.jpg'));
      expect(loaded['provider'], 'deezer');

      // resolveOfficialArtwork returns from db without network
      final resolved = await service.resolveOfficialArtwork(
        title: 'All Caps',
        artist: 'Madvillain',
      );
      expect(resolved, isNotNull);
      expect(resolved!.artworkUrl, contains('madvillainy.jpg'));

      db.close();
    });
  });

  group('ResolvedStream album art', () {
    test('ResolvedStream stores artworkUrl and albumTitle', () {
      const stream = ResolvedStream(
        url: 'https://example.com/audio.flac',
        artworkUrl: 'https://static.qobuz.com/images/covers/123_600.jpg',
        albumTitle: 'NOT ALL HEROES WEAR CAPES',
        bitDepth: 24,
        samplingRateKhz: 96,
        isLossless: true,
      );

      expect(
        stream.artworkUrl,
        'https://static.qobuz.com/images/covers/123_600.jpg',
      );
      expect(stream.albumTitle, 'NOT ALL HEROES WEAR CAPES');
    });
  });
}
