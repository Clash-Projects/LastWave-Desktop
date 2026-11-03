import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lastwave_desktop/core/storage/app_database.dart';
import 'package:lastwave_desktop/features/feed/feed_repository.dart';
import 'package:lastwave_desktop/features/home/home_snapshot.dart';
import 'package:lastwave_desktop/features/innertube/innertube_api.dart';
import 'package:lastwave_desktop/features/search/shared_providers.dart';

FeedData _feed(String tag) => FeedData(
      quickPicks: [
        GeneratedTrack(
          name: 'Song $tag',
          artist: 'Artist $tag',
          album: 'Album',
          artworkUrl: 'https://img/$tag.jpg',
          videoId: 'vid$tag',
          listeners: '1.2M',
          match: '0.9',
          durationSeconds: 201,
        ),
      ],
      charts: [GeneratedTrack(name: 'Chart $tag', artist: 'C')],
      tasteTags: ['pop', tag],
      becauseSeed: 'Seed $tag',
      tasteAffinities: {'artist $tag': 3.5},
    );

void main() {
  group('codecs', () {
    test('feed round-trips every field the page reads', () {
      final raw = feedSnapshotCodec.encode(_feed('a'));
      final f = feedSnapshotCodec.decode(raw)!;
      expect(f.quickPicks.single.name, 'Song a');
      expect(f.quickPicks.single.videoId, 'vida');
      expect(f.quickPicks.single.durationSeconds, 201);
      expect(f.charts.single.name, 'Chart a');
      expect(f.tasteTags, ['pop', 'a']);
      expect(f.becauseSeed, 'Seed a');
      expect(f.tasteAffinities['artist a'], 3.5);
    });

    test('shelves round-trip tracks, cards and entities', () {
      final shelves = [
        const YtHomeShelf(
          title: 'Listen again',
          subtitle: 'Your history',
          tracks: [
            YouTubeMusicTrack(videoId: 'v1', title: 'T', artist: 'A'),
          ],
          trackCards: [
            YouTubeMusicTrack(
              videoId: 'v2',
              title: 'T2',
              artist: 'A2',
              albumBrowseId: 'MPRE1',
            ),
          ],
          entities: [
            YouTubeMusicEntity(
              kind: YouTubeEntityKind.playlist,
              name: 'Mix',
              playlistId: 'RDx',
              artworkUrl: 'https://img/m.jpg',
            ),
          ],
        ),
      ];
      final raw = shelvesSnapshotCodec.encode(shelves);
      final s = shelvesSnapshotCodec.decode(raw)!.single;
      expect(s.title, 'Listen again');
      expect(s.tracks.single.videoId, 'v1');
      expect(s.trackCards.single.albumBrowseId, 'MPRE1');
      expect(s.entities.single.kind, YouTubeEntityKind.playlist);
      expect(s.entities.single.playlistId, 'RDx');
    });

    test('garbage and other versions decode to null, never throw', () {
      expect(feedSnapshotCodec.decode('not json'), isNull);
      expect(feedSnapshotCodec.decode('{"v":99}'), isNull);
      expect(shelvesSnapshotCodec.decode('[]'), isNull);
    });
  });

  group('snapshot keys', () {
    test('are per account and absent without one', () {
      expect(homeFeedSnapshotKey(''), isNull);
      expect(homeFeedSnapshotKey(' Bob '), homeFeedSnapshotKey('bob'));
      expect(homeFeedSnapshotKey('bob'), isNot(homeFeedSnapshotKey('amy')));
      expect(
        homeShelvesSnapshotKey(
            connected: false, profileEmail: 'a@b.c', activePageId: ''),
        isNull,
      );
      expect(
        homeShelvesSnapshotKey(
            connected: true, profileEmail: 'a@b.c', activePageId: '1'),
        isNot(homeShelvesSnapshotKey(
            connected: true, profileEmail: 'a@b.c', activePageId: '2')),
      );
    });
  });

  group('swrLoad', () {
    late AppDatabase db;
    DateTime now = DateTime(2026, 11, 4, 12);

    setUp(() {
      db = AppDatabase.inMemory();
      now = DateTime(2026, 11, 4, 12);
    });

    ProviderContainer container() => ProviderContainer(
          overrides: [databaseProvider.overrideWithValue(db)],
        );

    FutureProvider<FeedData> provider(
      Future<FeedData> Function() fetch, {
      String? key = 'k',
    }) =>
        FutureProvider<FeedData>((ref) => swrLoad<FeedData>(
              ref,
              key: key,
              codec: feedSnapshotCodec,
              fetch: fetch,
              clock: () => now,
            ));

    String songOf(ProviderContainer c, FutureProvider<FeedData> p) =>
        c.read(p).requireValue.quickPicks.single.name;

    test('cold start with no snapshot waits for the fetch and stores it',
        () async {
      final p = provider(() async => _feed('1'));
      final c = container();
      addTearDown(c.dispose);
      expect((await c.read(p.future)).quickPicks.single.name, 'Song 1');
      expect(db.cacheGet('k'), isNotNull);
    });

    test('snapshot paints at once, fresh data replaces it in place',
        () async {
      db.cachePut('k', 'home', feedSnapshotCodec.encode(_feed('old')), now: now);
      final gate = Completer<FeedData>();
      final p = provider(() => gate.future);
      final c = container();
      addTearDown(c.dispose);
      c.listen(p, (_, _) {});

      // Resolves without the (still pending) network fetch.
      expect((await c.read(p.future)).quickPicks.single.name, 'Song old');

      gate.complete(_feed('new'));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(songOf(c, p), 'Song new');
      // ...and the next launch starts from the fresh one.
      expect(
        feedSnapshotCodec.decode(db.cacheGet('k')!.value)!.quickPicks.single.name,
        'Song new',
      );
    });

    test('a failed or empty refresh leaves the snapshot on screen', () async {
      for (final fetch in <Future<FeedData> Function()>[
        () async => throw Exception('offline'),
        () async => const FeedData(),
      ]) {
        db.cachePut('k', 'home', feedSnapshotCodec.encode(_feed('old')), now: now);
        final c = container();
        final p = provider(fetch);
        c.listen(p, (_, _) {});
        expect((await c.read(p.future)).quickPicks.single.name, 'Song old');
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(songOf(c, p), 'Song old');
        expect(
          feedSnapshotCodec.decode(db.cacheGet('k')!.value)!.quickPicks.single.name,
          'Song old',
          reason: 'an empty refresh must not overwrite the good snapshot',
        );
        c.dispose();
      }
    });

    test('an explicit refresh in the same session fetches, not the snapshot',
        () async {
      db.cachePut('k', 'home', feedSnapshotCodec.encode(_feed('old')), now: now);
      var calls = 0;
      final p = provider(() async => _feed('f${++calls}'));
      final c = container();
      addTearDown(c.dispose);
      c.listen(p, (_, _) {});
      await c.read(p.future); // snapshot + background refresh
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(songOf(c, p), 'Song f1');

      c.invalidate(p); // e.g. the refresh button
      expect((await c.read(p.future)).quickPicks.single.name, 'Song f2');
    });

    test('a snapshot older than a week is not shown', () async {
      db.cachePut(
        'k',
        'home',
        feedSnapshotCodec.encode(_feed('old')),
        now: now.subtract(homeSnapshotMaxAge + const Duration(hours: 1)),
      );
      final p = provider(() async => _feed('fresh'));
      final c = container();
      addTearDown(c.dispose);
      expect((await c.read(p.future)).quickPicks.single.name, 'Song fresh');
    });

    test('another account never sees this snapshot', () async {
      db.cachePut('bob', 'home', feedSnapshotCodec.encode(_feed('bobs')), now: now);
      final p = provider(() async => _feed('amys'), key: 'amy');
      final c = container();
      addTearDown(c.dispose);
      expect((await c.read(p.future)).quickPicks.single.name, 'Song amys');
    });

    test('no account means no snapshot is read or written', () async {
      final p = provider(() async => _feed('x'), key: null);
      final c = container();
      addTearDown(c.dispose);
      await c.read(p.future);
      expect(db.cacheStats(), isEmpty);
    });
  });
}
