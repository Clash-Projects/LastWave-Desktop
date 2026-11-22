import 'dart:math' as math;
import 'dart:ui' as ui;

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
        widget.child,
      ],
    );
  }
}

/// The shader is compiled once per process; widgets wait on this.
final Future<ui.FragmentProgram> _stageProgram =
    ui.FragmentProgram.fromAsset('shaders/glass_stage.frag');

class _CoverWash extends StatefulWidget {
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
  State<_CoverWash> createState() => _CoverWashState();
}

class _CoverWashState extends State<_CoverWash> {
  ui.FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    _stageProgram.then((program) {
      if (mounted) setState(() => _shader = program.fragmentShader());
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shader = _shader;
    // The page colour for the few frames before the shader is ready.
    if (shader == null) return ColoredBox(color: widget.veil);
    return CustomPaint(
      painter: _StagePainter(
        shader: shader,
        image: widget.image,
        saturation: widget.saturation,
        dim: widget.dim,
        veil: widget.veil,
        tint: widget.tint,
        light: widget.light,
      ),
    );
  }
}

/// Feeds [WaveGlassStage]'s grade to `shaders/glass_stage.frag` and fills
/// the canvas with it: one draw call, repainted only when an input changes.
class _StagePainter extends CustomPainter {
  final ui.FragmentShader shader;
  final ui.Image image;
  final double saturation;
  final double dim;
  final Color veil;
  final double tint;
  final bool light;
  const _StagePainter({
    required this.shader,
    required this.image,
    required this.saturation,
    required this.dim,
    required this.veil,
    required this.tint,
    required this.light,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, saturation)
      ..setFloat(3, dim)
      ..setFloat(4, veil.r)
      ..setFloat(5, veil.g)
      ..setFloat(6, veil.b)
      ..setFloat(7, tint)
      ..setFloat(8, light ? 1 : 0)
      ..setFloat(9, light ? 0.35 : 0.07)
      ..setFloat(10, 1.2)
      // Bilinear: the texture is pre-blurred, so plain filtering is smooth.
      ..setImageSampler(0, image, filterQuality: FilterQuality.low);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_StagePainter old) =>
      !identical(old.image, image) ||
      old.saturation != saturation ||
      old.dim != dim ||
      old.veil != veil ||
      old.tint != tint ||
      old.light != light;
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
      // Breaks the gradient's 8-bit banding.
      child: const RepaintBoundary(child: WaveDither()),
    );
  }
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
