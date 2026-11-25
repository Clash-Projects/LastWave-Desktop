import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/prefs.dart';
import '../home/home_snapshot.dart';
import '../innertube/yt_library_providers.dart';
import 'auth_repository.dart';
import 'home_repository.dart';
import 'lastfm_snapshot.dart';

/// SWR-cached Last.fm profile stats for a user (scrobbles, counts, avatarUrl).
final userProfileStatsProvider =
    FutureProvider.autoDispose.family<HomeStats, String?>((ref, viewing) async {
  final home = ref.watch(homeRepositoryProvider);
  final username = ref.watch(prefsProvider.select((p) => p.username));
  if (username.isEmpty && viewing == null) return const HomeStats();
  try {
    return await swrLoad<HomeStats>(
      ref,
      key: lastFmCacheKey('stats', username, viewing: viewing),
      codec: homeStatsSnapshotCodec,
      group: cacheGroupLastFm,
      maxAge: lastFmCacheMaxAge,
      everyBuild: true,
      fetch: () => home.fetchStats(viewingAs: viewing),
    );
  } catch (err) {
    // If the initial fetch fails while pinned by persistent subscribers (like the title bar),
    // schedule auto-invalidation after a backoff so transient network errors are retried automatically.
    final timer = Timer(const Duration(seconds: 30), () {
      ref.invalidateSelf();
    });
    ref.onDispose(timer.cancel);
    rethrow;
  }
});

/// Reactive user avatar URL provider.
///
/// Priority:
/// 1. Last.fm profile avatar URL (if signed in and has avatar)
/// 2. YouTube Music channel photo URL (if connected to YouTube and has photo)
/// 3. Empty string (UI falls back to user initial)
final userAvatarUrlProvider = Provider.autoDispose<String>((ref) {
  final auth = ref.watch(authRepositoryProvider);
  if (auth.status == AuthStatus.signedIn && auth.username.isNotEmpty) {
    final stats = ref.watch(userProfileStatsProvider(null)).valueOrNull;
    final lastFmAvatar = stats?.avatarUrl ?? '';
    if (lastFmAvatar.isNotEmpty) return lastFmAvatar;
  }

  // Fallback: YouTube connected profile photo if available
  final ytAccount = ref.watch(ytAccountProvider).valueOrNull;
  if (ytAccount != null && ytAccount.photoUrl.isNotEmpty) {
    return ytAccount.photoUrl;
  }

  return '';
});
