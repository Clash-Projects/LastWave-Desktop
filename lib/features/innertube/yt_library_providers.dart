import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'innertube_api.dart';

/// YouTube Music account surfaces.
///
/// Each watches [ytConnectionProvider], so connect/disconnect (and the
/// async persisted-restore at startup) automatically refetch. Empty
/// when signed out or on any failure — callers render their normal
/// empty state, never an error.
final ytLikedSongsProvider =
    FutureProvider<List<YouTubeMusicTrack>>((ref) async {
  if (!ref.watch(ytConnectionProvider).connected) {
    return const [];
  }
  return ref.watch(innerTubeProvider).fetchLikedSongs();
});

final ytHistoryProvider =
    FutureProvider<List<YouTubeMusicTrack>>((ref) async {
  if (!ref.watch(ytConnectionProvider).connected) {
    return const [];
  }
  return ref.watch(innerTubeProvider).fetchYtHistory();
});

final ytAccountPlaylistsProvider =
    FutureProvider<List<YouTubePlaylistSummary>>((ref) async {
  if (!ref.watch(ytConnectionProvider).connected) {
    return const [];
  }
  return ref.watch(innerTubeProvider).fetchAccountPlaylists();
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



/// Full track list for one YouTube Music playlist (own, liked, or
/// public). Null when the fetch fails — the page renders an error.
final ytPlaylistDetailProvider =
    FutureProvider.family<YouTubePlaylistResult?, String>(
        (ref, id) async {
  if (id.isEmpty) return null;
  return ref.watch(innerTubeProvider).fetchPlaylist(id);
});
