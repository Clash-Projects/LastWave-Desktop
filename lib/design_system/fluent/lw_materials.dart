import 'dart:ui';

import 'package:fluent_ui/fluent_ui.dart';

import '../../../ui/theme/tokens.dart';
import 'lw_colors.dart';

/// Haze material system — depth without blur soup.
///
/// Levels (spec §5):
/// - L0 crisp: track tables, dense library, album grids, reading surfaces.
///   No blur, fully opaque base.
/// - L1 subtle tonal: navigation pane, title chrome, player dock,
///   secondary page surfaces. Translucent wash, optional 12px blur only
///   over static chrome (never over scrolling content).
/// - L2 apparent: queue panel, lyrics controls, suggestion panel,
///   floating clusters. Translucent + 20px blur in a bounded 320-380px
///   region; rows stay crisp (no per-row blur).
/// - L3 transient: context menus, flyouts, popovers, dialogs,
///   mini-player overlays. Strongest translucency + 28px blur, small
///   radius, excellent shadow. Never full-screen.
///
/// Performance contract (spec §51):
/// - Blur regions are bounded (chrome / 360px panel / flyout).
/// - Never blur continuously-changing content (progress, lyrics ticks).
/// - Prefer static tonal materials; BackdropFilter only where the
///   backdrop is largely static.
/// - Artwork tint ≤12% alpha, low saturation, cached per media ID.
enum LwHazeLevel { l0, l1, l2, l3 }

/// Per-level blur + tint configuration.
class LwHazeSpec {
  final double blurSigma;
  final double darkAlpha;
  final double lightAlpha;
  final double tintCap;
  const LwHazeSpec({
    required this.blurSigma,
    required this.darkAlpha,
    required this.lightAlpha,
    this.tintCap = 0.12,
  });
}

const lwHazeSpecs = <LwHazeLevel, LwHazeSpec>{
  LwHazeLevel.l0: LwHazeSpec(blurSigma: 0, darkAlpha: 1.0, lightAlpha: 1.0),
  LwHazeLevel.l1: LwHazeSpec(blurSigma: 12, darkAlpha: 0.88, lightAlpha: 0.90),
  LwHazeLevel.l2: LwHazeSpec(blurSigma: 20, darkAlpha: 0.82, lightAlpha: 0.88),
  LwHazeLevel.l3: LwHazeSpec(blurSigma: 28, darkAlpha: 0.86, lightAlpha: 0.94),
};

/// Haze material container.
///
/// - L0: plain opaque surface (no filter — cheapest, used for lists).
/// - L1–L3: tonal wash + optional bounded [BackdropFilter]. Set
///   [enableBlur] false to force the static tonal fallback (low-end /
///   `reduceTransparency` / Haze=Solid setting).
/// - [artworkTint]: optional cached palette color; mixed at ≤12% so the
///   base stays neutral.
/// - [borderRadius]/[border]/[shadow] follow [LwElevation]-style values.
class LwHaze extends StatelessWidget {
  final LwHazeLevel level;
  final Widget child;
  final Color? base;
  final Color? artworkTint;
  final BorderRadiusGeometry borderRadius;
  final BoxBorder? border;
  final List<BoxShadow>? shadow;
  final bool enableBlur;
  final Alignment alignment;

  const LwHaze({
    super.key,
    required this.level,
    required this.child,
    this.base,
    this.artworkTint,
    this.borderRadius = BorderRadius.zero,
    this.border,
    this.shadow,
    this.enableBlur = true,
    this.alignment = Alignment.center,
  });

  /// L1 chrome (rail / title / dock).
  const LwHaze.chrome({
    super.key,
    required this.child,
    this.base,
    this.artworkTint,
    this.border,
    this.shadow,
    this.enableBlur = true,
  })  : level = LwHazeLevel.l1,
        borderRadius = BorderRadius.zero,
        alignment = Alignment.center;

  /// L2 panel (queue / suggestion / floating cluster).
  const LwHaze.panel({
    super.key,
    required this.child,
    this.base,
    this.artworkTint,
    this.border,
    this.shadow,
    this.enableBlur = true,
  })  : level = LwHazeLevel.l2,
        borderRadius = BorderRadius.zero,
        alignment = Alignment.center;

  /// L3 flyout (menu / dialog / popover).
  const LwHaze.flyout({
    super.key,
    required this.child,
    this.base,
    this.artworkTint,
    this.border,
    this.shadow,
    this.enableBlur = true,
  })  : level = LwHazeLevel.l3,
        borderRadius = const BorderRadius.all(Radius.circular(7)),
        alignment = Alignment.center;

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final spec = lwHazeSpecs[level]!;
    final resolvedBase = base ??
        (dark ? LwColors.surfaceLayer1 : LwColors.lightSurfaceLayer1);
    final alpha = dark ? spec.darkAlpha : spec.lightAlpha;
    var fill = resolvedBase.withValues(alpha: alpha);
    if (artworkTint != null && level != LwHazeLevel.l0) {
      // Low-saturation atmosphere: mix tint at ≤12%, never flood.
      final tint = artworkTint!.withValues(alpha: spec.tintCap);
      fill = Color.alphaBlend(tint, fill);
    }
    final reduceT =
        MediaQuery.maybeOf(context)?.highContrast ?? false;
    final useBlur =
        enableBlur && !reduceT && spec.blurSigma > 0 && level != LwHazeLevel.l0;
    final content = Container(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: borderRadius,
        border: border,
        boxShadow: shadow,
      ),
      child: child,
    );
    if (!useBlur) return content;
    return ClipRRect(
      borderRadius: borderRadius is BorderRadius
          ? borderRadius as BorderRadius
          : BorderRadius.zero,
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: spec.blurSigma,
          sigmaY: spec.blurSigma,
        ),
        child: content,
      ),
    );
  }
}

/// Ambient artwork wash (Now Playing / hero backdrops).
///
/// Static radial glow, no animation, no fullscreen blur. Saturation is
/// kept low by blending the seed at 18–28% over the neutral base.
class LwAmbientWash extends StatelessWidget {
  final Color? seed;
  final double height;
  final Alignment center;
  const LwAmbientWash({
    super.key,
    required this.seed,
    this.height = 320,
    this.center = const Alignment(-0.7, -0.6),
  });

  @override
  Widget build(BuildContext context) {
    if (seed == null) return const SizedBox.shrink();
    final dark = waveIsDark(context);
    final reduceT =
        MediaQuery.maybeOf(context)?.highContrast ?? false;
    if (reduceT) return const SizedBox.shrink();
    return IgnorePointer(
      child: Container(
        height: height,
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: center,
            radius: 1.1,
            colors: [
              seed!.withValues(alpha: dark ? 0.28 : 0.18),
              seed!.withValues(alpha: 0.0),
            ],
          ),
        ),
      ),
    );
  }
}
