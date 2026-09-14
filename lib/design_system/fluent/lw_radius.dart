import 'package:fluent_ui/fluent_ui.dart';

import '../../../ui/theme/tokens.dart';

/// Radii — sharp system. Max 10px for floating surfaces.
///
/// tiny 3 · controls 5 · menu 7 · artwork 6 · floating 10 · structural 0.
/// No 20–30px cards. Pills only for chips + circular transport.
class LwRadius {
  LwRadius._();

  static const double tiny = WaveRadius.tiny;
  static const double controls = WaveRadius.controls;
  static const double menu = WaveRadius.menu;
  static const double artwork = WaveRadius.artwork;
  static const double floating = WaveRadius.floating;
  static const double structural = WaveRadius.structural;

  static BorderRadius get tinyRadius => WaveRadius.tinyRadius;
  static BorderRadius get controlsRadius => WaveRadius.controlsRadius;
  static BorderRadius get menuRadius => WaveRadius.menuRadius;
  static BorderRadius get artworkRadius => WaveRadius.artworkRadius;
  static BorderRadius get floatingRadius => WaveRadius.floatingRadius;
}
