import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/player/playback_service.dart';
import '../theme/tokens.dart';
import 'ambient.dart';

/// Backdrop for the glassmorphism theme, painted once behind the whole app.
///
/// The playing cover itself, as a soft wash: the pre-blurred 256px aura
/// texture stretched over the window (a tiny image scaled up has no detail
/// left to show, which is what makes it smooth), colour-boosted, dimmed so
/// text reads, darkened toward the dock and vignetted, then dithered so the
/// gradients never band. Pearl gets the cover under a white wash instead.
/// Each theme reads differently over the same cover ([GlassFlavor]).
/// Surfaces above are white (or black) at a few percent opacity
/// (WaveSurfaces.glass), never a tinted fill. Static: it only repaints
/// when the cover changes, cross-fading then.
/// How a theme treats the cover: (saturation, theme tint over it, extra
/// dimming). Pearl, the light theme, always takes the white wash instead.
enum GlassFlavor {
  /// Calm and neutral: softened colour under a graphite tint.
  midnight(0.95, 0.22, 0.92),

  /// The cover at full strength, no tint.
  artwork(1.5, 0.0, 1.0),

  /// The user's colour leads: muted cover under a strong custom tint.
  custom(0.6, 0.42, 1.0);

  final double saturation;
  final double tint;
  final double dim;
  const GlassFlavor(this.saturation, this.tint, this.dim);
}

class WaveGlassStage extends ConsumerStatefulWidget {
  /// The theme's opaque page colour.
  final Color veil;
  final bool light;
  final Color accent;
  final GlassFlavor flavor;
  final Widget child;

  const WaveGlassStage({
    super.key,
    required this.veil,
    required this.light,
    required this.accent,
    this.flavor = GlassFlavor.midnight,
    required this.child,
  });

  @override
  ConsumerState<WaveGlassStage> createState() => _WaveGlassStageState();
}

class _WaveGlassStageState extends ConsumerState<WaveGlassStage> {
  /// Cover on screen. The next one replaces it only once its texture is
  /// baked, so a track change cross-fades instead of flashing empty.
  String _shown = '';

  @override
  Widget build(BuildContext context) {
    final url = ref.watch(
        playbackServiceProvider.select((s) => s.current?.artworkUrl ?? ''));
    if (url.isEmpty) {
      _shown = '';
    } else if (ref.watch(auraImageProvider(url)).hasValue) {
      _shown = url;
    }
    final image =
        _shown.isEmpty ? null : ref.watch(auraImageProvider(_shown)).valueOrNull;
    final palette = _shown.isEmpty
        ? null
        : ref.watch(artworkPaletteProvider(_shown)).valueOrNull;
    final veil = widget.veil;
    final light = widget.light;

    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: veil),
        IgnorePointer(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 1400),
            switchInCurve: Curves.easeInOut,
            switchOutCurve: Curves.easeInOut,
            layoutBuilder: (current, previous) => Stack(
              fit: StackFit.expand,
              children: [...previous, ?current],
            ),
            child: image == null
                ? _AccentWash(
                    key: const ValueKey(''),
                    accent: widget.accent,
                    veil: veil,
                    light: light,
                  )
                : RepaintBoundary(
                    key: ValueKey(_shown),
                    child: _CoverWash(
                      image: image,
                      dim: light ? 1.0 : glassDim(palette) * widget.flavor.dim,
                      saturation: light ? 1.2 : widget.flavor.saturation,
                      tint: widget.flavor.tint,
                      light: light,
                      veil: veil,
                    ),
                  ),
          ),
        ),
        // Sheen: light falling from the top-left, the glossy part.
        IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: const Alignment(0.3, 0.3),
                colors: [
                  const Color(0xFFFFFFFF).withValues(alpha: light ? 0.35 : 0.07),
                  const Color(0x00FFFFFF),
                ],
              ),
            ),
          ),
        ),
        // Breaks the 8-bit banding of the large soft gradients.
        const IgnorePointer(child: RepaintBoundary(child: WaveDither())),
        widget.child,
      ],
    );
  }
}

class _CoverWash extends StatelessWidget {
  final ui.Image image;
  final double dim;
  final double saturation;
  final double tint;
  final bool light;
  final Color veil;
  const _CoverWash({
    required this.image,
    required this.dim,
    required this.saturation,
    required this.tint,
    required this.light,
    required this.veil,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // One cached drawing, no layers: a full-window blur or colour
        // filter layer is recomputed on every frame the window paints,
        // which made the whole app feel slow. The 256px aura texture is
        // already blurred; scaled up with high-quality filtering it stays
        // smooth, and the grade rides on the paint.
        CustomPaint(
          painter: _CoverPainter(image, _grade(saturation, dim)),
        ),
        if (light)
          // Pearl: a pale tint of the cover under the page colour.
          ColoredBox(color: veil.withValues(alpha: 0.74))
        else ...[
          // The theme's own colour over the cover (none for Artwork).
          if (tint > 0) ColoredBox(color: veil.withValues(alpha: tint)),
          // Darker toward the dock, where the controls sit.
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  const Color(0xFF000000).withValues(alpha: 0.06),
                  const Color(0xFF000000).withValues(alpha: 0.40),
                ],
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                radius: 1.1,
                colors: [
                  const Color(0x00000000),
                  const Color(0xFF000000).withValues(alpha: 0.18),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Nothing playing: a soft light in the accent colour.
class _AccentWash extends StatelessWidget {
  final Color accent;
  final Color veil;
  final bool light;
  const _AccentWash({
    super.key,
    required this.accent,
    required this.veil,
    required this.light,
  });

  @override
  Widget build(BuildContext context) {
    final glow = glassTone(accent, veil, light);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [glow, veil],
        ),
      ),
    );
  }
}

/// Saturation [s] and brightness [dim] as one colour matrix.
List<double> _grade(double s, double dim) {
  const r = 0.2126, g = 0.7152, b = 0.0722;
  final i = 1 - s;
  return [
    (i * r + s) * dim, i * g * dim, i * b * dim, 0, 0, //
    i * r * dim, (i * g + s) * dim, i * b * dim, 0, 0, //
    i * r * dim, i * g * dim, (i * b + s) * dim, 0, 0, //
    0, 0, 0, 1, 0, //
  ];
}

/// How far to dim the cover in dark themes: 62% brightness by default,
/// lower for pale covers, so the brightest part of the wash (the top,
/// under 6% shade) stays dark enough for primary text at WCAG AA.
double glassDim(ArtworkPalette? p) {
  if (p == null) return 0.62;
  final brightest = [p.cream, p.lightVibrant, p.vibrant, p.primary]
      .map((c) => c.computeLuminance())
      .reduce(math.max);
  return (0.13 / (brightest * 0.94 + 1e-6)).clamp(0.15, 0.62);
}

/// A colour made safe to put text on: saturation capped, lightness held
/// in a band (dark themes 10–26%, Pearl 84–93%) and nudged toward the
/// theme's page colour, then stepped darker (or lighter) until secondary
/// text keeps WCAG AA (4.5:1). Used for the accent wash when nothing plays.
Color glassTone(Color c, Color veil, bool light) {
  final hsl = HSLColor.fromColor(c.withValues(alpha: 1));
  final text = light ? WaveColors.lightTextSecondary : WaveColors.textSecondary;
  var l = light ? hsl.lightness.clamp(0.84, 0.93) : hsl.lightness.clamp(0.10, 0.26);
  Color tone() => Color.lerp(
      hsl.withSaturation(hsl.saturation.clamp(0.0, 0.55)).withLightness(l).toColor(),
      veil,
      0.22)!;
  for (var i = 0; i < 40 && _contrast(text, tone()) < 4.6; i++) {
    l = (l + (light ? 0.01 : -0.01)).clamp(0.0, 1.0);
  }
  return tone();
}

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// The cover stretched (zoomed 1.2x past the edges) and graded in one
/// draw call. Repaints only when the image or grade changes.
class _CoverPainter extends CustomPainter {
  final ui.Image image;
  final List<double> grade;
  const _CoverPainter(this.image, this.grade);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final src =
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    // Cover-fit, then zoom so the soft edges never show.
    final scale =
        math.max(size.width / src.width, size.height / src.height) * 1.2;
    final dst = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: src.width * scale,
      height: src.height * scale,
    );
    canvas.clipRect(Offset.zero & size);
    canvas.drawImageRect(
      image,
      src,
      dst,
      Paint()
        ..filterQuality = FilterQuality.high
        ..colorFilter = ColorFilter.matrix(grade),
    );
  }

  @override
  bool shouldRepaint(_CoverPainter old) =>
      !identical(old.image, image) || !listEquals(old.grade, grade);
}
