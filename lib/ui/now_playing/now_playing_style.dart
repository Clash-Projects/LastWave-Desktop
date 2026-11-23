import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/storage/prefs.dart';

/// Now Playing layout style.
enum NowPlayingStyle {
  fullBleed('fullBleed', 'Full Bleed', 'Edge-to-edge canvas & seamless lyrics'),
  minimal('minimal', 'Minimal', 'Sharp cover art & distraction-free duet'),
  standard('standard', 'Old', 'Classic dual pane, audio info & up next');

  final String id;
  final String label;
  final String subtitle;
  const NowPlayingStyle(this.id, this.label, this.subtitle);

  static NowPlayingStyle fromId(String? id) => switch (id) {
    'minimal' => minimal,
    'standard' => standard,
    _ => fullBleed,
  };
}

final nowPlayingStyleProvider =
    StateNotifierProvider<NowPlayingStyleNotifier, NowPlayingStyle>((ref) {
  return NowPlayingStyleNotifier(ref.watch(prefsProvider));
});

class NowPlayingStyleNotifier extends StateNotifier<NowPlayingStyle> {
  final Prefs _prefs;
  NowPlayingStyleNotifier(this._prefs)
      : super(NowPlayingStyle.fromId(_prefs.nowPlayingStyle));

  void set(NowPlayingStyle style) {
    if (state == style) return;
    state = style;
    _prefs.setNowPlayingStyle(style.id);
  }
}
