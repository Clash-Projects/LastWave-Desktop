import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/prefs.dart';
import '../home/home_snapshot.dart';
import '../innertube/yt_library_providers.dart';
import '../scrobblers/scrobbler_session.dart';
import 'home_repository.dart';
import 'lastfm_snapshot.dart';

/// SWR-cached scrobbler profile stats for a user (scrobbles, counts, avatarUrl).
final userProfileStatsProvider =
    FutureProvider.autoDispose.family<HomeStats, String?>((ref, viewing) async {
  final home = ref.watch(homeRepositoryProvider);
  final session = ref.watch(activeScrobblerSessionProvider);
  final scope = session.cacheScope;
  if (scope.isEmpty && viewing == null) return const HomeStats();
  try {
    return await swrLoad<HomeStats>(
      ref,
      key: lastFmCacheKey('stats', scope, viewing: viewing),
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
/// 1. Active scrobbler profile avatar URL (if connected and has avatar)
/// 2. YouTube Music channel photo URL (if connected to YouTube and has photo)
/// 3. Empty string (UI falls back to user initial)
final userAvatarUrlProvider = Provider.autoDispose<String>((ref) {
  final session = ref.watch(activeScrobblerSessionProvider);
  if (session.connected) {
    final stats = ref.watch(userProfileStatsProvider(null)).valueOrNull;
    final scrobblerAvatar = stats?.avatarUrl ?? '';
    if (scrobblerAvatar.isNotEmpty) return scrobblerAvatar;
  }

  // Fallback: YouTube connected profile photo if available
  final ytAccount = ref.watch(ytAccountProvider).valueOrNull;
  if (ytAccount != null && ytAccount.photoUrl.isNotEmpty) {
    return ytAccount.photoUrl;
  }

  return '';
});

/// User-selected local image path for the title-bar avatar.
final localProfilePictureProvider = StateProvider<String>((ref) {
  return ref.watch(prefsProvider).profilePicturePath;
});

/// User-configured local display name (e.g. for Home greeting and avatar).
final localDisplayNameProvider = StateProvider<String>((ref) {
  return ref.watch(prefsProvider).displayName;
});

/// Title-bar avatar source: local picture first, then connected YouTube
/// channel photo. Never tied to Last.fm or other scrobblers.
final titleBarAvatarUrlProvider = Provider.autoDispose<String>((ref) {
  final localPath = ref.watch(localProfilePictureProvider).trim();
  if (localPath.isNotEmpty) return localPath;

  final ytAccount = ref.watch(ytAccountProvider).valueOrNull;
  if (ytAccount != null && ytAccount.photoUrl.isNotEmpty) {
    return ytAccount.photoUrl;
  }

  return '';
});

/// Title-bar display name: local display name first, then connected YouTube
/// channel name. Never tied to Last.fm or other scrobblers.
final titleBarDisplayNameProvider = Provider.autoDispose<String>((ref) {
  final custom = ref.watch(localDisplayNameProvider).trim();
  if (custom.isNotEmpty) return custom;

  final ytAccount = ref.watch(ytAccountProvider).valueOrNull;
  if (ytAccount != null && ytAccount.name.isNotEmpty) {
    return ytAccount.name;
  }

  return '';
});

/// Greeting name on Home: custom display name first, then YouTube channel
/// name, then active scrobbler username.
final homeDisplayNameProvider = Provider.autoDispose<String>((ref) {
  final titleBarName = ref.watch(titleBarDisplayNameProvider);
  if (titleBarName.isNotEmpty) return titleBarName;

  final session = ref.watch(activeScrobblerSessionProvider);
  return session.connected ? session.username : '';
});
