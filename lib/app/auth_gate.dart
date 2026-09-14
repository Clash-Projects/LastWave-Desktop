import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/storage/prefs.dart';
import '../features/lastfm/auth_repository.dart';
import '../features/lastfm/home_repository.dart';
import '../features/player/playback_service.dart';

/// Startup authentication gate.
///
/// Last.fm authentication is compulsory: the main shell is never built
/// for an unauthenticated user. The gate holds the current signed-in
/// state and drives go_router's `refreshListenable` + `redirect`, so:
///
/// - unauthenticated + anywhere except /welcome → /welcome
/// - authenticated + on /welcome → /home
///
/// The initial value comes from synchronously-loaded [Prefs] (awaited
/// in main() before runApp), and [AuthRepository] restores the same
/// state synchronously in its constructor — so the very first frame
/// already routes correctly and Home never flashes before auth.
class AuthGate extends ChangeNotifier {
  bool _signedIn;
  AuthGate({required bool initialSignedIn})
      : _signedIn = initialSignedIn;

  bool get signedIn => _signedIn;

  void update(bool value) {
    if (value == _signedIn) return;
    _signedIn = value;
    notifyListeners();
  }
}

/// Full logout: clear the Last.fm session (prefs + OS secure store),
/// drop auth-cached profile state, and pause playback — then the gate
/// redirect returns straight to the welcome screen.
///
/// Downloads, local settings, and library data are left untouched.
Future<void> signOutEverywhere(WidgetRef ref) async {
  try {
    await ref.read(playbackServiceProvider.notifier).pause();
  } catch (_) {}
  try {
    ref.read(viewingProfileProvider.notifier).clear();
  } catch (_) {}
  await ref.read(authRepositoryProvider.notifier).signOut();
}
