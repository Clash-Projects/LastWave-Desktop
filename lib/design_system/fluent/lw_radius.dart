import 'package:fluent_ui/fluent_ui.dart';

import '../../../ui/theme/tokens.dart';

/// Radii — monotonic soft ladder (see [WaveRadius] for the contract).
///
/// tiny 6 · controls 10 · artwork 12 · menu 14 · floating 20 · hero 24 ·
/// structural 0. Pills (999) only for chips + circular transport.
class LwRadius {
  LwRadius._();

  static const double tiny = WaveRadius.tiny;
  static const double controls = WaveRadius.controls;
  static const double artwork = WaveRadius.artwork;
  static const double menu = WaveRadius.menu;
  static const double floating = WaveRadius.floating;
  static const double hero = WaveRadius.hero;
  static const double structural = WaveRadius.structural;

  static BorderRadius get tinyRadius => WaveRadius.tinyRadius;
  static BorderRadius get controlsRadius => WaveRadius.controlsRadius;
  static BorderRadius get artworkRadius => WaveRadius.artworkRadius;
  static BorderRadius get menuRadius => WaveRadius.menuRadius;
  static BorderRadius get floatingRadius => WaveRadius.floatingRadius;
  static BorderRadius get heroRadius => WaveRadius.heroRadius;
}
