import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/artwork/artwork_resolver.dart';
import 'package:lastwave_desktop/core/artwork/official_artwork_service.dart';
import 'package:lastwave_desktop/core/audio/stream_models.dart';
import 'package:lastwave_desktop/core/storage/app_database.dart';
import 'package:lastwave_desktop/features/lossless/lossless_api.dart';

void main() {
  group('ArtworkResolver official priority & sizing', () {
    test('prioritizes official Apple/iTunes art over YouTube thumbnails', () {
      final req = ArtworkRequest(
        kind: ArtworkKind.track,
        candidates: [
          'https://i.ytimg.com/vi/video12345/hqdefault.jpg',
          'https://is1-ssl.mzstatic.com/image/thumb/Music125/v4/b1/e3/27/cover.jpg/100x100bb.jpg',
        ],
        videoId: 'video12345',
        targetPx: 640,
      );
      final resolved = ArtworkResolver.resolve(req);
      expect(resolved.urls, isNotEmpty);
      // First URL in the chain must be the official studio cover, sized to targetPx
      expect(resolved.urls.first, contains('mzstatic.com'));
      expect(resolved.urls.first, contains('640x640bb'));

      // YouTube fallback occurs only after official covers
      final ytIndex = resolved.urls.indexWhere((u) => u.contains('ytimg.com'));
      final appleIndex = resolved.urls.indexWhere((u) => u.contains('mzstatic.com'));
      expect(appleIndex, lessThan(ytIndex));
    });

    test('sizes Apple Music / mzstatic URLs to target dimension', () {
      const original =
          'https://is1-ssl.mzstatic.com/image/thumb/Music125/v4/b1/e3/27/cover.jpg/100x100bb.jpg';
      final sized640 = ArtworkResolver.sized(original, 640);
      expect(sized640,
          'https://is1-ssl.mzstatic.com/image/thumb/Music125/v4/b1/e3/27/cover.jpg/640x640bb.jpg');

      const template =
          'https://is1-ssl.mzstatic.com/image/thumb/Music125/v4/b1/e3/27/cover.jpg/{w}x{h}bb.{f}';
      final sized1000 = ArtworkResolver.sized(template, 1000);
      expect(sized1000,
          'https://is1-ssl.mzstatic.com/image/thumb/Music125/v4/b1/e3/27/cover.jpg/1000x1000bb.jpg');
    });

    test('sizes Qobuz cover URLs to large resolution', () {
      const original =
          'https://static.qobuz.com/images/covers/00/00/0000000000000_230.jpg';
      final sized = ArtworkResolver.sized(original, 600);
      expect(sized,
          'https://static.qobuz.com/images/covers/00/00/0000000000000_600.jpg');
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
              'https://is1-ssl.mzstatic.com/image/thumb/cover.jpg/100x100bb.jpg'),
          isTrue);
      expect(
          OfficialArtworkService.isOfficialArtwork(
              'https://static.qobuz.com/images/covers/cover_600.jpg'),
          isTrue);
      expect(
          OfficialArtworkService.isOfficialArtwork(
              'https://i.scdn.co/image/ab67616d0000b273...'),
          isTrue);
      expect(
          OfficialArtworkService.isOfficialArtwork(
              'https://i.ytimg.com/vi/video12345/hqdefault.jpg'),
          isFalse);
      expect(
          OfficialArtworkService.isOfficialArtwork(
              'https://lh3.googleusercontent.com/some-yt-thumb'),
          isFalse);
      expect(OfficialArtworkService.isOfficialArtwork(''), isFalse);
    });

    test('normalizeForSearch strips noise and featured artists', () {
      expect(
          OfficialArtworkService.normalizeForSearch(
              'Overdue (feat. Travis Scott) [Official Music Video]'),
          'overdue');
      expect(
          OfficialArtworkService.normalizeForSearch(
              'Metro Boomin - Space Cadet (Remastered)'),
          'space cadet');
    });

    test('live lookup: Metro Boomin - Overdue returns official album cover', () async {
      final service = OfficialArtworkService();
      final result = await service.resolveOfficialArtwork(
        title: 'Overdue (feat. Travis Scott)',
        artist: 'Metro Boomin',
      );

      expect(result, isNotNull);
      expect(result!.artworkUrl, contains('mzstatic.com'));
      expect(result.artworkUrl, contains('1400x1400bb'));
      expect(result.albumTitle.toLowerCase(),
          contains('not all heroes wear capes'));
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('live lookup: Madvillain - All Caps returns official studio album cover', () async {
      final service = OfficialArtworkService();
      final result = await service.resolveOfficialArtwork(
        title: 'All Caps',
        artist: 'Madvillain',
      );

      expect(result, isNotNull);
      expect(result!.artworkUrl, contains('mzstatic.com'));
      expect(result.artworkUrl, contains('1400x1400bb'));
      expect(result.albumTitle.toLowerCase(), contains('madvillainy'));
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('persists artwork to AppDatabase and reuses it', () async {
      final db = AppDatabase.inMemory();
      final service = OfficialArtworkService(null, db);

      // Save an entry
      db.saveArtworkEntry(
        cacheKey: 'madvillain|all caps',
        url: 'https://is1-ssl.mzstatic.com/image/thumb/Music123/v4/madvillainy.jpg/1400x1400bb.jpg',
        provider: 'itunes',
      );

      final loaded = db.loadArtworkEntry('madvillain|all caps');
      expect(loaded, isNotNull);
      expect(loaded!['url'], contains('madvillainy.jpg'));
      expect(loaded['provider'], 'itunes');

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

  group('LosslessCandidate and ResolvedStream album art', () {
    test('extracts album art from Qobuz candidate payload', () {
      final json = {
        'id': '123456',
        'title': 'Overdue',
        'duration': 166,
        'performer': {'name': 'Metro Boomin'},
        'album': {
          'title': 'NOT ALL HEROES WEAR CAPES',
          'image': {
            'small': 'https://static.qobuz.com/images/covers/123_230.jpg',
            'large': 'https://static.qobuz.com/images/covers/123_600.jpg',
          },
        },
      };

      final candidate = LosslessCandidate.fromJson(json);
      expect(candidate.albumTitle, 'NOT ALL HEROES WEAR CAPES');
      expect(candidate.albumArtUrl,
          'https://static.qobuz.com/images/covers/123_600.jpg');
    });

    test('ResolvedStream stores artworkUrl and albumTitle', () {
      const stream = ResolvedStream(
        url: 'https://example.com/audio.flac',
        artworkUrl: 'https://static.qobuz.com/images/covers/123_600.jpg',
        albumTitle: 'NOT ALL HEROES WEAR CAPES',
        bitDepth: 24,
        samplingRateKhz: 96,
        isLossless: true,
      );

      expect(stream.artworkUrl,
          'https://static.qobuz.com/images/covers/123_600.jpg');
      expect(stream.albumTitle, 'NOT ALL HEROES WEAR CAPES');
    });
  });
}
