import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/prefs.dart';
import '../feed/feed_repository.dart';
import '../innertube/innertube_api.dart';
import '../lastfm/home_repository.dart';
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
    FutureProvider<List<FriendActivity>>((ref) {
  final home = ref.watch(homeRepositoryProvider);
  return swrLoad<List<FriendActivity>>(
    ref,
    key: homeFriendsSnapshotKey(ref.read(prefsProvider).username),
    codec: friendsActivityCodec,
    fetch: () => _fetchFriendsActivity(home),
  );
});

Future<List<FriendActivity>> _fetchFriendsActivity(
    HomeRepository home) async {
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
}

final friendsActivityCodec = SnapshotCodec<List<FriendActivity>>(
  encode: (list) => jsonEncode({
    'v': 1,
    'items': [
      for (final a in list)
        {
          'f': a.friend,
          'av': a.avatarUrl,
          'n': a.track.name,
          'a': a.track.artist,
          'art': a.track.artworkUrl,
          if (a.track.timestampMillis != null) 't': a.track.timestampMillis,
          'pc': a.track.playCount,
        },
    ],
  }),
  decode: (raw) {
    try {
      final j = jsonDecode(raw);
      if (j is! Map || j['v'] != 1) return null;
      return [
        for (final e in (j['items'] as List? ?? const []))
          if (e is Map)
            FriendActivity(
              friend: e['f']?.toString() ?? '',
              avatarUrl: e['av']?.toString() ?? '',
              track: HomeTrack(
                name: e['n']?.toString() ?? '',
                artist: e['a']?.toString() ?? '',
                artworkUrl: e['art']?.toString() ?? '',
                timestampMillis: (e['t'] as num?)?.toInt(),
                playCount: (e['pc'] as num?)?.toInt() ?? 0,
              ),
            ),
      ];
    } catch (_) {
      return null;
    }
  },
  isEmpty: (list) => list.isEmpty,
);
