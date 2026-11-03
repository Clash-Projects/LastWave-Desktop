import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lastwave_desktop/core/storage/app_database.dart';
import 'package:lastwave_desktop/features/home/home_snapshot.dart';
import 'package:lastwave_desktop/features/innertube/innertube_api.dart';
import 'package:lastwave_desktop/features/search/shared_providers.dart';

const _a = YtConnection(
  connected: true,
  profileEmail: 'Me@Example.com',
  activePageId: '',
);
const _b = YtConnection(
  connected: true,
  profileEmail: 'me@example.com',
  activePageId: '42',
);

List<YouTubeMusicTrack> _tracks(int n, {String tag = ''}) => [
      for (var i = 0; i < n; i++)
        YouTubeMusicTrack(
          videoId: 'v$i',
          title: 'Song $i$tag',
          artist: 'Artist',
          album: 'Album',
          durationSeconds: 180,
          albumBrowseId: 'MPRE$i',
        ),
    ];

void main() {
  group('keys', () {
    test('library lists are per identity and absent signed out', () {
      expect(libraryCacheKey('liked', const YtConnection()), isNull);
      expect(libraryCacheKey('liked', _a), isNotNull);
      // Same login, different channel => different list.
      expect(libraryCacheKey('liked', _a), isNot(libraryCacheKey('liked', _b)));
      expect(libraryCacheKey('liked', _a), isNot(libraryCacheKey('history', _a)));
    });

    test('the email is case-insensitive', () {
      const upper = YtConnection(
          connected: true, profileEmail: 'ME@EXAMPLE.COM', activePageId: '');
      expect(libraryCacheKey('liked', _a), libraryCacheKey('liked', upper));
    });

    test('playlists are per identity, albums are shared', () {
      expect(playlistCacheKey('PL1', _a), isNot(playlistCacheKey('PL1', _b)));
      expect(playlistCacheKey('', _a), isNull);
      expect(albumCacheKey('MPRE1'), albumCacheKey('MPRE1'));
      expect(albumCacheKey(''), isNull);
    });
  });

  group('codecs', () {
    test('track list keeps the album id the album links need', () {
      final back =
          ytTracksSnapshotCodec.decode(ytTracksSnapshotCodec.encode(_tracks(3)))!;
      expect(back, hasLength(3));
      expect(back[2].title, 'Song 2');
      expect(back[2].albumBrowseId, 'MPRE2');
      expect(back[2].durationSeconds, 180);
    });

    test('account playlists round-trip', () {
      const list = [
        YouTubePlaylistSummary(
          id: 'PL1',
          title: 'Gym',
          author: 'me',
          trackCountText: '42 songs',
          artworkUrl: 'https://img/p.jpg',
        ),
      ];
      final back = ytPlaylistSummariesSnapshotCodec
          .decode(ytPlaylistSummariesSnapshotCodec.encode(list))!;
      expect(back.single.title, 'Gym');
      expect(back.single.trackCountText, '42 songs');
    });

    test('a playlist keeps its header and tracks; "unavailable" is never kept',
        () {
      final p = YouTubePlaylistResult(
        id: 'PL1',
        title: 'Gym',
        author: 'me',
        artworkUrl: 'https://img/p.jpg',
        trackCount: 2,
        tracks: _tracks(2),
      );
      final back = ytPlaylistResultSnapshotCodec
          .decode(ytPlaylistResultSnapshotCodec.encode(p))!;
      expect(back.title, 'Gym');
      expect(back.trackCount, 2);
      expect(back.tracks, hasLength(2));
      expect(ytPlaylistResultSnapshotCodec.isEmpty(noPlaylistResult), isTrue);
      expect(ytPlaylistResultSnapshotCodec.isEmpty(p), isFalse);
    });
  });

  group('swrLoad options', () {
    late AppDatabase db;
    setUp(() => db = AppDatabase.inMemory());

    ProviderContainer container() => ProviderContainer(
          overrides: [databaseProvider.overrideWithValue(db)],
        );

    FutureProvider<List<YouTubeMusicTrack>> provider(
      Future<List<YouTubeMusicTrack>> Function() fetch, {
      bool everyBuild = false,
      int maxChars = 1500000,
    }) =>
        FutureProvider<List<YouTubeMusicTrack>>(
          (ref) => swrLoad<List<YouTubeMusicTrack>>(
            ref,
            key: 'k',
            codec: ytTracksSnapshotCodec,
            group: cacheGroupAlbum,
            everyBuild: everyBuild,
            maxChars: maxChars,
            fetch: fetch,
          ),
        );

    void seed() => db.cachePut(
          'k',
          cacheGroupAlbum,
          ytTracksSnapshotCodec.encode(_tracks(1, tag: ' (old)')),
        );

    test('everyBuild paints the copy on every visit, not only the first',
        () async {
      seed();
      final gate = Completer<List<YouTubeMusicTrack>>();
      final p = provider(() => gate.future, everyBuild: true);
      final c = container();
      addTearDown(c.dispose);

      // First "visit".
      expect((await c.read(p.future)).single.title, 'Song 0 (old)');
      // Leave and come back: a second visit is a new build of the same key.
      c.invalidate(p);
      expect((await c.read(p.future)).single.title, 'Song 0 (old)',
          reason: 'still the saved copy, not a wait on the network');
    });

    test('without everyBuild a second build fetches (explicit refresh)',
        () async {
      seed();
      var n = 0;
      final p = provider(() async => _tracks(1, tag: ' (f${++n})'));
      final c = container();
      addTearDown(c.dispose);
      c.listen(p, (_, _) {});
      await c.read(p.future);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      c.invalidate(p);
      expect((await c.read(p.future)).single.title, 'Song 0 (f2)');
    });

    test('an oversized value is shown but not persisted', () async {
      final p = provider(() async => _tracks(400), maxChars: 5000);
      final c = container();
      addTearDown(c.dispose);
      expect((await c.read(p.future)), hasLength(400));
      expect(db.cacheGet('k'), isNull);
    });

    test('a normal value is persisted', () async {
      final p = provider(() async => _tracks(3));
      final c = container();
      addTearDown(c.dispose);
      await c.read(p.future);
      expect(db.cacheGet('k'), isNotNull);
    });
  });
}
