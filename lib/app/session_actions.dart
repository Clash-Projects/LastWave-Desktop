import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/lastfm/auth_repository.dart';
import '../features/lastfm/home_repository.dart';
import '../features/player/playback_service.dart';

/// Sign out of Last.fm without leaving the app shell.
///
/// Playback is paused and Last.fm profile state is cleared, while downloads,
/// local settings, library data, and the current Home destination remain.
Future<void> signOutEverywhere(WidgetRef ref) async {
  try {
    await ref.read(playbackServiceProvider.notifier).pause();
  } catch (_) {}
  try {
    ref.read(viewingProfileProvider.notifier).clear();
  } catch (_) {}
  await ref.read(authRepositoryProvider.notifier).signOut();
}
