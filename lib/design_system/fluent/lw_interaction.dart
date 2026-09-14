import 'package:fluent_ui/fluent_ui.dart';

import '../../../ui/theme/tokens.dart';

/// Interaction — hover / pressed / focus / cursor contract.
///
/// hover 7% wash over 110ms · pressed 12% · focus 2px ring ·
/// clickable targets use click cursor · tooltip 400ms wait.
class LwInteraction {
  LwInteraction._();

  static const double hoverAlpha = WaveState.hoverAlpha; // 0.07
  static const double pressedAlpha = WaveState.pressedAlpha; // 0.12
  static const double focusRing = WaveState.focusRing; // 2
  static const Duration tooltipDelay = WaveState.tooltipDelay; // 400ms

  static Color hoverWash(BuildContext context) {
    final dark = waveIsDark(context);
    return (dark ? Colors.white : Colors.black)
        .withValues(alpha: hoverAlpha);
  }

  static Color pressedWash(BuildContext context) {
    final dark = waveIsDark(context);
    return (dark ? Colors.white : Colors.black)
        .withValues(alpha: pressedAlpha);
  }
}
