import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Edge-to-edge Now Playing: the dock's expand button, pressed while
/// already on Now Playing, hides the title bar, rail, player dock and every
/// side panel (and takes the window full screen). The Now Playing close
/// button (or Esc) leaves it.
final nowPlayingImmersiveProvider = StateProvider<bool>((_) => false);
