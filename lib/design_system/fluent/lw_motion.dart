import 'package:fluent_ui/fluent_ui.dart';

import '../../../ui/theme/tokens.dart';

/// Motion — Fluent-restrained, no bounce/elastic/giant zoom.
///
/// hover 80–120ms · press 70–100ms · selection 120–160ms ·
/// flyout 140–190ms · panel 180–240ms · page 200–280ms.
/// fade / small translation / crossfade / subtle scale / size interp.
class LwMotion {
  LwMotion._();

  static const fast = WaveMotion.fast; // 110ms hover/press
  static const normal = WaveMotion.normal; // 180ms selection/flyout
  static const slow = WaveMotion.slow; // 260ms panel/page
  static const Curve standard = WaveMotion.standard; // easeOutCubic

  static const pageTransition = WaveMotion.normal;
  static const panelTransition = Duration(milliseconds: 220);
  static const flyoutTransition = Duration(milliseconds: 160);
}
