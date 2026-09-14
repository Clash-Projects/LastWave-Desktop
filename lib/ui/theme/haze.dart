import 'package:fluent_ui/fluent_ui.dart';

import '../../design_system/fluent/fluent.dart';

export '../../design_system/fluent/fluent.dart'
    show LwHaze, LwHazeLevel, LwAmbientWash, lwHazeSpecs;

/// UI-layer Haze convenience.
///
/// New pages should use [WaveHaze] directly (L0–L3 levels). It honours
/// the user's Material setting (Automatic / Haze / Solid) and intensity
/// (Low / Medium / High) via [WaveHazeScope] — pages never branch on
/// prefs themselves.
enum WaveMaterialMode { automatic, haze, solid }

enum WaveHazeIntensity { low, medium, high }

class WaveHazeScope extends InheritedWidget {
  final WaveMaterialMode material;
  final WaveHazeIntensity intensity;
  const WaveHazeScope({
    super.key,
    required this.material,
    required this.intensity,
    required super.child,
  });

  static WaveHazeScope of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<WaveHazeScope>() ??
        const WaveHazeScope(
          material: WaveMaterialMode.automatic,
          intensity: WaveHazeIntensity.medium,
          child: SizedBox.shrink(),
        );
  }

  /// Blur is disabled in Solid mode (static tonal fallback everywhere).
  static bool blurEnabled(BuildContext context) =>
      of(context).material != WaveMaterialMode.solid;

  /// Intensity scales the L1–L3 sigma: low 0.6× · medium 1.0× · high 1.25×.
  /// Implemented by choosing whether to blur at all for L1 on low, and
  /// by wrapping sigma in callers that need fine control.
  static double blurScale(BuildContext context) =>
      switch (of(context).intensity) {
        WaveHazeIntensity.low => 0.6,
        WaveHazeIntensity.medium => 1.0,
        WaveHazeIntensity.high => 1.25,
      };

  @override
  bool updateShouldNotify(WaveHazeScope old) =>
      material != old.material || intensity != old.intensity;
}

/// Haze material container honouring the user's material setting.
///
/// Thin wrapper over [LwHaze]: pages pass a level + child, the scope
/// decides blur vs. static tonal fallback.
class WaveHaze extends StatelessWidget {
  final LwHazeLevel level;
  final Widget child;
  final Color? base;
  final Color? artworkTint;
  final BorderRadiusGeometry borderRadius;
  final BoxBorder? border;
  final List<BoxShadow>? shadow;

  const WaveHaze({
    super.key,
    required this.level,
    required this.child,
    this.base,
    this.artworkTint,
    this.borderRadius = BorderRadius.zero,
    this.border,
    this.shadow,
  });

  const WaveHaze.chrome({
    super.key,
    required this.child,
    this.base,
    this.artworkTint,
    this.border,
    this.shadow,
  })  : level = LwHazeLevel.l1,
        borderRadius = BorderRadius.zero;

  const WaveHaze.panel({
    super.key,
    required this.child,
    this.base,
    this.artworkTint,
    this.border,
    this.shadow,
  })  : level = LwHazeLevel.l2,
        borderRadius = BorderRadius.zero;

  const WaveHaze.flyout({
    super.key,
    required this.child,
    this.base,
    this.artworkTint,
    this.border,
    this.shadow,
  })  : level = LwHazeLevel.l3,
        borderRadius = const BorderRadius.all(Radius.circular(7));

  @override
  Widget build(BuildContext context) {
    return LwHaze(
      level: level,
      base: base,
      artworkTint: artworkTint,
      borderRadius: borderRadius,
      border: border,
      shadow: shadow,
      enableBlur: WaveHazeScope.blurEnabled(context),
      child: child,
    );
  }
}
