import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../home/home_snapshot.dart';
import 'innertube_api.dart';

/// YouTube Music account surfaces.
///
/// Each watches [ytConnectionProvider], so connect/disconnect (and the
/// async persisted-restore at startup) automatically refetch. Empty
/// when signed out or on any failure — callers render their normal
/// empty state, never an error.
///
/// The three account lists below are stale-while-revalidate over a
/// per-channel disk snapshot: the first load of a session paints the last
/// copy at once and refreshes behind it. Later invalidations (a like, a
/// sync, the session keeper) fetch for real — callers that invalidate want
/// the new truth, not the snapshot.
final ytLikedSongsProvider =
    FutureProvider<List<YouTubeMusicTrack>>((ref) async {
  final conn = ref.watch(ytConnectionProvider);
  if (!conn.connected) {
    return const [];
  }
  final tube = ref.watch(innerTubeProvider);
  return swrLoad<List<YouTubeMusicTrack>>(
    ref,
    key: libraryCacheKey('liked', conn),
    codec: ytTracksSnapshotCodec,
    group: cacheGroupLibrary,
    maxAge: libraryCacheMaxAge,
    fetch: tube.fetchLikedSongs,
  );
});

final ytHistoryProvider =
    FutureProvider<List<YouTubeMusicTrack>>((ref) async {
  final conn = ref.watch(ytConnectionProvider);
  if (!conn.connected) {
    return const [];
  }
  final tube = ref.watch(innerTubeProvider);
  return swrLoad<List<YouTubeMusicTrack>>(
    ref,
    key: libraryCacheKey('history', conn),
    codec: ytTracksSnapshotCodec,
    group: cacheGroupLibrary,
    maxAge: libraryCacheMaxAge,
    fetch: tube.fetchYtHistory,
  );
});

final ytAccountPlaylistsProvider =
    FutureProvider<List<YouTubePlaylistSummary>>((ref) async {
  final conn = ref.watch(ytConnectionProvider);
  if (!conn.connected) {
    return const [];
  }
  final tube = ref.watch(innerTubeProvider);
  return swrLoad<List<YouTubePlaylistSummary>>(
    ref,
    key: libraryCacheKey('playlists', conn),
    codec: ytPlaylistSummariesSnapshotCodec,
    group: cacheGroupLibrary,
    maxAge: libraryCacheMaxAge,
    fetch: tube.fetchAccountPlaylists,
  );
});

/// Signed-in account identity, scoped to the ACTIVE channel: the
/// brand page ID rides along so switching channels swaps the card
/// (previously it always fetched the main channel, freezing the
/// avatar on switch).
final ytAccountProvider = FutureProvider<YtAccount?>((ref) async {
  final conn = ref.watch(ytConnectionProvider);
  if (!conn.connected) return null;
  return ref
      .watch(innerTubeProvider)
      .fetchAccountInfo(pageId: conn.activePageId);
});

/// Titled shelves from the YouTube Music home browse.
///
/// Only fetched when connected: the whole point of the home browse is
/// the personalized "For you" surface, and an anonymous call returns
/// generic trending shelves that would just duplicate Discover. Empty
/// on any failure, so the Home page simply omits the section.
final ytHomeShelvesProvider =
    FutureProvider<List<YtHomeShelf>>((ref) async {
  final conn = ref.watch(ytConnectionProvider);
  if (!conn.connected) {
    return const [];
  }
  final tube = ref.watch(innerTubeProvider);
  // Stale-while-revalidate over a per-channel disk snapshot, so the Home
  // shelves are there on launch instead of after the browse round trips.
  return swrLoad<List<YtHomeShelf>>(
    ref,
    key: homeShelvesSnapshotKey(
      connected: conn.connected,
      profileEmail: conn.profileEmail,
      activePageId: conn.activePageId,
    ),
    codec: shelvesSnapshotCodec,
    fetch: tube.fetchHomeShelves,
  );
});



/// Full track list for one YouTube Music playlist (own, liked, or
/// public). Null when the fetch fails — the page renders an error.
///
/// Stale-while-revalidate over a per-identity snapshot, so reopening a
/// playlist from an earlier session shows its tracks straight away.
final ytPlaylistDetailProvider =
    FutureProvider.family<YouTubePlaylistResult?, String>(
        (ref, id) async {
  if (id.isEmpty) return null;
  final tube = ref.watch(innerTubeProvider);
  final conn = ref.watch(ytConnectionProvider);
  final result = await swrLoad<YouTubePlaylistResult>(
    ref,
    key: playlistCacheKey(id, conn),
    codec: ytPlaylistResultSnapshotCodec,
    group: cacheGroupPlaylist,
    maxAge: libraryCacheMaxAge,
    fetch: () async => await tube.fetchPlaylist(id) ?? noPlaylistResult,
  );
  return result.tracks.isEmpty && result.id.isEmpty ? null : result;
});
