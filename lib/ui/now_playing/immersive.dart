import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/prefs.dart';
import '../theme/tokens.dart';

/// Edge-to-edge Now Playing: the dock's expand button, pressed while
/// already on Now Playing, hides the title bar, rail, player dock and every
/// side panel (and takes the window full screen). F11 toggles it from
/// anywhere. The Now Playing close button (or Esc) leaves it.
final nowPlayingImmersiveProvider = StateProvider<bool>((_) => false);

/// Mirror of Now Playing's idle auto-hide, so the shell and all Now Playing
/// views can fade controls together. Owned by WaveNowPlayingPage; false
/// whenever the page is not mounted or auto-hide is Off.
final nowPlayingControlsIdleProvider = StateProvider<bool>((_) => false);

/// True while the Now Playing overflow menu flyout is open, pausing idle
/// auto-hide so controls and cursor do not vanish underneath an open menu.
final nowPlayingMenuOpenProvider = StateProvider<bool>((_) => false);

/// User-configured idle auto-hide timeout in seconds (`3`, `4`, `5`, or `0` for Off).
final nowPlayingAutoHideSecondsProvider =
    StateNotifierProvider<NowPlayingAutoHideNotifier, int>((ref) {
  return NowPlayingAutoHideNotifier(ref.watch(prefsProvider));
});

class NowPlayingAutoHideNotifier extends StateNotifier<int> {
  final Prefs _prefs;
  NowPlayingAutoHideNotifier(this._prefs)
      : super(_prefs.nowPlayingAutoHideSeconds);

  void set(int seconds) {
    final normalized =
        Prefs.nowPlayingAutoHideOptions.contains(seconds) ? seconds : 3;
    if (state == normalized) return;
    state = normalized;
    _prefs.setNowPlayingAutoHideSeconds(normalized);
  }
}

/// Bumped by the overlay dock while the pointer is over it. The page's
/// MouseRegion does not see hovers on the dock (it is a sibling above the
/// page, not a child), so without this the idle timer would run out under a
/// pointer that is busy on the seek bar.
final nowPlayingActivityProvider = StateProvider<int>((_) => 0);

/// The player dock as a floating overlay along the bottom edge of the
/// immersive Now Playing stage. Fades out with the page's other controls
/// and ignores pointer and focus while hidden, so a hidden dock can't eat
/// clicks meant for the lyrics.
class WaveImmersiveDockOverlay extends ConsumerWidget {
  final Widget child;
  const WaveImmersiveDockOverlay({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final idle = ref.watch(nowPlayingControlsIdleProvider);
    return MouseRegion(
      onHover: (_) =>
          ref.read(nowPlayingActivityProvider.notifier).state++,
      child: AnimatedOpacity(
        duration: waveMotion(context, const Duration(milliseconds: 350)),
        opacity: idle ? 0.0 : 1.0,
        child: ExcludeFocus(
          excluding: idle,
          child: IgnorePointer(ignoring: idle, child: child),
        ),
      ),
    );
  }
}
