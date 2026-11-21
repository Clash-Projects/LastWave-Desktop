import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/player/playback_service.dart';
import '../theme/tokens.dart';
import 'ambient.dart';

/// Backdrop for the glassmorphism theme, painted once behind the whole app.
///
/// A calm gradient from the playing cover's colours, toned so text always
/// reads on it: dark themes keep every stop dark, Pearl keeps them pale,
/// and each stop leans toward the theme's page colour so Midnight, Pearl,
/// Custom and Artwork keep their identity. Pages and the title bar are
/// clear over it, the rail and dock are frosted (WaveSurfaces.glass).
/// Static: it repaints only when the song changes, cross-fading then.
class WaveGlassStage extends ConsumerWidget {
  /// The theme's opaque page colour.
  final Color veil;
  final bool light;
  final Color accent;
  final Widget child;

  const WaveGlassStage({
    super.key,
    required this.veil,
    required this.light,
    required this.accent,
    required this.child,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = ref.watch(
        playbackServiceProvider.select((s) => s.current?.artworkUrl ?? ''));
    final palette = url.isEmpty
        ? null
        : ref.watch(artworkPaletteProvider(url)).valueOrNull;
    final stops = palette == null
        ? [accent, veil, veil]
        : [palette.vibrant, palette.primary, palette.darkMuted];
    final glow = palette?.lightVibrant ?? accent;

    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: veil),
        IgnorePointer(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 1600),
            switchInCurve: Curves.easeInOut,
            switchOutCurve: Curves.easeInOut,
            layoutBuilder: (current, previous) => Stack(
              fit: StackFit.expand,
              children: [...previous, ?current],
            ),
            child: DecoratedBox(
              key: ValueKey(palette == null ? '' : url),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [for (final c in stops) glassTone(c, veil, light)],
                  stops: const [0.0, 0.55, 1.0],
                ),
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0.8, -1.0),
                    radius: 1.3,
                    colors: [
                      glassTone(glow, veil, light).withValues(alpha: 0.7),
                      glassTone(glow, veil, light).withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        // Sheen: a faint light falling from the top-left, the glossy part.
        IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: const Alignment(0.2, 0.4),
                colors: [
                  const Color(0xFFFFFFFF).withValues(alpha: light ? 0.30 : 0.06),
                  const Color(0x00FFFFFF),
                ],
              ),
            ),
          ),
        ),
        // Breaks the gradient's 8-bit banding: smooth, not textured.
        const IgnorePointer(child: RepaintBoundary(child: WaveDither())),
        child,
      ],
    );
  }
}

/// A cover colour made safe to put text on: saturation capped, lightness
/// held in a band (dark themes 10–26%, Pearl 84–93%) and nudged toward the
/// theme's page colour, then stepped darker (or lighter) until secondary
/// text keeps WCAG AA (4.5:1). HSL lightness alone lets yellows through.
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
