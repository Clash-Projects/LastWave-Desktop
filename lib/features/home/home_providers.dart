import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../feed/feed_repository.dart';
import '../innertube/innertube_api.dart';
import '../lastfm/home_repository.dart';

/// Home data providers: feed sections and new-release records load
/// independently so partial data still renders a rich page.
final feedProvider = FutureProvider<FeedData>((ref) {
  return ref.watch(feedRepositoryProvider).loadFeed();
});

final newAlbumsProvider =
    FutureProvider<List<YouTubeMusicEntity>>((ref) {
  return ref
      .watch(feedRepositoryProvider)
      .fetchNewReleaseAlbums();
});

/// YouTube Music personal mix (seed + radio list), or null when
/// signed out / empty / stalled. Independent loading so it never
/// blocks the Last.fm feed; the home hero falls back when null.
final personalMixProvider = FutureProvider<
    ({GeneratedTrack seed, List<GeneratedTrack> tracks})?>((ref) {
  return ref.watch(feedRepositoryProvider).fetchPersonalMix();
});

/// One friend's latest scrobble for the Friends Listening strip.
class FriendActivity {
  final String friend;
  final String avatarUrl;
  final HomeTrack track;
  const FriendActivity({
    required this.friend,
    required this.avatarUrl,
    required this.track,
  });
}

/// Real friend activity: own friends list × each friend's latest
/// scrobble (bounded parallelism, fail-soft per friend). Empty when
/// signed out, friendless, or stalled — the Home section hides
/// itself instead of rendering placeholder data.
final friendsActivityProvider =
    FutureProvider<List<FriendActivity>>((ref) async {
  final home = ref.watch(homeRepositoryProvider);
  late final List<FriendEntry> friends;
  try {
    friends = await home
        .fetchFriends()
        .timeout(const Duration(seconds: 10));
  } catch (_) {
    return const [];
  }
  if (friends.isEmpty) return const [];
  final acts = await Future.wait(friends.take(6).map((f) async {
    try {
      final recents = await home
          .fetchRecentTracks(viewingAs: f.name, limit: 3)
          .timeout(const Duration(seconds: 8));
      if (recents.isEmpty) return null;
      return FriendActivity(
        friend: f.name,
        avatarUrl: f.avatarUrl,
        track: recents.first,
      );
    } catch (_) {
      return null;
    }
  }));
  return acts.whereType<FriendActivity>().toList();
});
