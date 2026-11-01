import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/prefs.dart';

/// Seconds of inactivity before Now Playing hides its controls (1–10),
/// or 0 when auto-hide is off. Default 3.
final nowPlayingAutoHideProvider =
    StateNotifierProvider<NowPlayingAutoHideNotifier, int>((ref) {
      return NowPlayingAutoHideNotifier(ref.watch(prefsProvider));
    });

class NowPlayingAutoHideNotifier extends StateNotifier<int> {
  NowPlayingAutoHideNotifier(this._prefs)
    : super(_prefs.nowPlayingAutoHideSeconds);
  final Prefs _prefs;

  void set(int seconds) {
    state = seconds <= 0 ? 0 : seconds.clamp(1, 10);
    _prefs.setNowPlayingAutoHideSeconds(state);
  }
}

/// True while Now Playing has hidden its controls. The page owns it; the
/// app shell reads it to fade the side rail with the rest of the chrome.
final nowPlayingChromeHiddenProvider = StateProvider<bool>((ref) => false);

/// True while the Now Playing page is on screen. The dock reads it to say
/// what its expand button does here.
final nowPlayingOpenProvider = StateProvider<bool>((ref) => false);

/// Full-screen Now Playing: the video fills the whole window, with no
/// title bar, side rail or player dock. Esc or the X at the top leaves.
final nowPlayingFullscreenProvider = StateProvider<bool>((ref) => false);
