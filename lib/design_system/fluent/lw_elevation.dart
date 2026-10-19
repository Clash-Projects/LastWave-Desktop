import 'package:fluent_ui/fluent_ui.dart';

import '../../ui/theme/tokens.dart';

/// Elevation — restrained Fluent shadows, bridged to [WaveElevation].
///
/// These aliases used to carry their own hardcoded black plates, so the kit
/// and the live UI could disagree about what "panel" meant and the light
/// theme inherited the graphite shadow. They delegate now: one ladder, one
/// theme-aware set of values.
class LwElevation {
  LwElevation._();

  static List<BoxShadow> none(BuildContext context) => const [];

  /// Hover lift for artwork and cards.
  static List<BoxShadow> lift(BuildContext context) =>
      WaveElevation.lift(waveIsDark(context));

  /// Feature artwork at hero size.
  static List<BoxShadow> artwork(BuildContext context) =>
      WaveElevation.artwork(waveIsDark(context));

  /// Full-height side panel, cast inward.
  static List<BoxShadow> panel(BuildContext context) =>
      WaveElevation.panel(waveIsDark(context));

  /// Menu / dialog flyout.
  static List<BoxShadow> flyout(BuildContext context) =>
      WaveElevation.flyout(waveIsDark(context));

  /// Round transport control on the dock.
  static List<BoxShadow> transport(BuildContext context) =>
      WaveElevation.transport(waveIsDark(context));
}
