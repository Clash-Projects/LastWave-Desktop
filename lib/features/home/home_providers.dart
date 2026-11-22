import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/prefs.dart';
import '../feed/feed_repository.dart';
import '../innertube/innertube_api.dart';
import 'home_snapshot.dart';

/// Home data providers: feed sections and new-release records load
/// independently so partial data still renders a rich page.
///
/// The feed is stale-while-revalidate over a per-user disk snapshot (see
/// `home_snapshot.dart`): a cold start paints the last feed at once and the
/// fresh one replaces it in place when it lands.
final feedProvider = FutureProvider<FeedData>((ref) {
  final repo = ref.watch(feedRepositoryProvider);
  return swrLoad<FeedData>(
    ref,
    key: homeFeedSnapshotKey(ref.read(prefsProvider).username),
    codec: feedSnapshotCodec,
    fetch: repo.loadFeed,
  );
});

/// New-release albums. Stale-while-revalidate like the feed; scoped to the
/// YouTube identity because the signed-in browse is personalized.
final newAlbumsProvider =
    FutureProvider<List<YouTubeMusicEntity>>((ref) {
  final repo = ref.watch(feedRepositoryProvider);
  final conn = ref.watch(ytConnectionProvider);
  return swrLoad<List<YouTubeMusicEntity>>(
    ref,
    key: homeNewAlbumsSnapshotKey(
      connected: conn.connected,
      profileEmail: conn.profileEmail,
      activePageId: conn.activePageId,
    ),
    codec: entitiesSnapshotCodec,
    fetch: () => repo.fetchNewReleaseAlbums(limit: 60),
  );
});

/// YouTube Music personal mix (seed + radio list), or null when
/// signed out / empty / stalled. Independent loading so it never
/// blocks the Last.fm feed; the home hero falls back when null.
/// Stale-while-revalidate over a per-channel snapshot.
final personalMixProvider = FutureProvider<PersonalMixData?>((ref) async {
  final repo = ref.watch(feedRepositoryProvider);
  final conn = ref.watch(ytConnectionProvider);
  final mix = await swrLoad<PersonalMixData>(
    ref,
    key: homePersonalMixSnapshotKey(
      connected: conn.connected,
      profileEmail: conn.profileEmail,
      activePageId: conn.activePageId,
    ),
    codec: personalMixSnapshotCodec,
    fetch: () async => await repo.fetchPersonalMix() ?? noPersonalMix,
  );
  return mix.tracks.isEmpty ? null : mix;
});
