import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/storage/prefs.dart';
import '../features/lastfm/auth_repository.dart';
import '../features/lastfm/home_repository.dart';
import '../features/player/playback_service.dart';

/// Startup authentication gate.
///
/// Last.fm authentication is optional (guest mode): the main shell is
/// built for signed-in users AND keyless guests, and never for anyone
/// else. The gate holds the current "inside" state and drives
/// go_router's `refreshListenable` + `redirect`, so:
///
/// - outsider + anywhere except /welcome → /welcome
/// - insider (signed in or guest) + on /welcome → /home
///
/// The initial value comes from synchronously-loaded [Prefs] (awaited
/// in main() before runApp), and [AuthRepository] restores the same
/// state synchronously in its constructor — so the very first frame
/// already routes correctly and Home never flashes before auth.
class AuthGate extends ChangeNotifier {
  bool _inside;
  AuthGate({required bool initialInside}) : _inside = initialInside;

  /// Signed in OR guest — allowed inside the shell.
  bool get signedIn => _inside;

  void update(bool value) {
    if (value == _inside) return;
    _inside = value;
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
