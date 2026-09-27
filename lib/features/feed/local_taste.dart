import '../lastfm/home_repository.dart';

/// On-device taste snapshot for keyless guests (no Last.fm account).
///
/// Aggregates purely local signals — play log, liked songs, downloads —
/// into the [HomeTrack] shapes the feed engine already scores, so the
/// same affinity/seeding machinery personalizes without any account.
/// Signed-in users get these blended in too (own collection outweighs
/// third-party signals), but guests run on them exclusively.
class LocalTaste {
  /// Newest-first play log rows (cap ~100).
  final List<HomeTrack> recentPlays;

  /// Local Liked Songs playlist contents.
  final List<HomeTrack> likedTracks;

  /// Downloaded tracks (owned collection).
  final List<HomeTrack> downloadedTracks;

  const LocalTaste({
    this.recentPlays = const [],
    this.likedTracks = const [],
    this.downloadedTracks = const [],
  });

  bool get isEmpty =>
      recentPlays.isEmpty &&
      likedTracks.isEmpty &&
      downloadedTracks.isEmpty;

  /// Seed pool for discovery/personal-mix: recents first (current
  /// taste), then liked, then downloads — deduped, artists capped
  /// downstream by the diversifier.
  List<HomeTrack> seedPool({int limit = 12}) {
    final out = <HomeTrack>[];
    final seen = <String>{};
    for (final t in [
      ...recentPlays,
      ...likedTracks,
      ...downloadedTracks,
    ]) {
      if (t.name.isEmpty || !seen.add(t.key)) continue;
      out.add(t);
      if (out.length >= limit) break;
    }
    return out;
  }
}
