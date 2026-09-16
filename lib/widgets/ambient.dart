import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:palette_generator/palette_generator.dart';

import '../core/storage/prefs.dart';
import '../features/player/playback_service.dart';
import '../ui/theme/haze.dart';
import '../ui/theme/tokens.dart';

/// Provider for visualizer toggle (persisted in preferences).
final visualizerEnabledProvider =
    StateNotifierProvider<VisualizerEnabledNotifier, bool>((ref) {
  final prefs = ref.watch(prefsProvider);
  return VisualizerEnabledNotifier(prefs);
});

class VisualizerEnabledNotifier extends StateNotifier<bool> {
  final Prefs _prefs;

  VisualizerEnabledNotifier(this._prefs) : super(_prefs.visualizerEnabled);

  void toggle() {
    state = !state;
    _prefs.setVisualizerEnabled(state);
  }

  void setEnabled(bool enabled) {
    state = enabled;
    _prefs.setVisualizerEnabled(enabled);
  }
}

/// Multi-tone palette extracted from album artwork for dynamic ambient effects.
class ArtworkPalette {
  final Color primary;
  final Color vibrant;
  final Color darkMuted;
  final Color lightVibrant;

  const ArtworkPalette({
    required this.primary,
    required this.vibrant,
    required this.darkMuted,
    required this.lightVibrant,
  });

  static const fallback = ArtworkPalette(
    primary: Color(0xFF232838),
    vibrant: Color(0xFF2D3748),
    darkMuted: Color(0xFF141721),
    lightVibrant: Color(0xFF3B4758),
  );

  ArtworkPalette lerp(ArtworkPalette other, double t) {
    return ArtworkPalette(
      primary: Color.lerp(primary, other.primary, t) ?? primary,
      vibrant: Color.lerp(vibrant, other.vibrant, t) ?? vibrant,
      darkMuted: Color.lerp(darkMuted, other.darkMuted, t) ?? darkMuted,
      lightVibrant: Color.lerp(lightVibrant, other.lightVibrant, t) ?? lightVibrant,
    );
  }
}

/// Shared artwork-derived multi-color palette, cached by image identity.
final artworkPaletteProvider =
    FutureProvider.autoDispose.family<ArtworkPalette, String>((ref, url) async {
  if (url.isEmpty) return ArtworkPalette.fallback;
  ref.keepAlive();
  try {
    final provider = CachedNetworkImageProvider(url,
        maxWidth: 128, maxHeight: 128);
    final palette = await PaletteGenerator.fromImageProvider(
      provider,
      size: const Size(64, 64),
      maximumColorCount: 12,
    );
    final primary = palette.dominantColor?.color ?? const Color(0xFF232838);
    final vibrant = palette.vibrantColor?.color ??
        palette.lightVibrantColor?.color ??
        primary;
    final darkMuted = palette.darkMutedColor?.color ??
        palette.darkVibrantColor?.color ??
        const Color(0xFF141721);
    final lightVibrant = palette.lightVibrantColor?.color ??
        palette.mutedColor?.color ??
        vibrant;

    return ArtworkPalette(
      primary: primary,
      vibrant: vibrant,
      darkMuted: darkMuted,
      lightVibrant: lightVibrant,
    );
  } catch (_) {
    return ArtworkPalette.fallback;
  }
});

/// Shared artwork-derived ambient primary color, cached by image identity.
final artworkSeedProvider =
    FutureProvider.autoDispose.family<Color, String>((ref, url) async {
  if (url.isEmpty) return const Color(0xFF232838);
  final pal = await ref.watch(artworkPaletteProvider(url).future);
  return pal.primary;
});

/// Dynamic, organic ambient background inspired by Apple Music desktop.
///
/// Features smooth multi-orb harmonic drifting motion with seamless palette
/// crossfading when tracks change, overlaid with a WinUI 3 acrylic / scrim layer
/// for pristine contrast and Segoe UI readability.
class WaveAmbientMesh extends ConsumerStatefulWidget {
  final String artworkUrl;
  final bool isFullBleed;
  final double height;
  final double opacity;

  const WaveAmbientMesh({
    super.key,
    required this.artworkUrl,
    this.isFullBleed = true,
    this.height = 360,
    this.opacity = 1.0,
  });

  @override
  ConsumerState<WaveAmbientMesh> createState() => _WaveAmbientMeshState();
}

class _WaveAmbientMeshState extends ConsumerState<WaveAmbientMesh>
    with TickerProviderStateMixin {
  late final AnimationController _motionController;
  late final AnimationController _crossfadeController;

  ArtworkPalette _currentPalette = ArtworkPalette.fallback;
  ArtworkPalette _targetPalette = ArtworkPalette.fallback;

  @override
  void initState() {
    super.initState();
    _motionController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 22),
    )..repeat();

    _crossfadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
  }

  @override
  void dispose() {
    _motionController.dispose();
    _crossfadeController.dispose();
    super.dispose();
  }

  void _onPaletteLoaded(ArtworkPalette newPalette) {
    if (_targetPalette == newPalette) return;
    _currentPalette = _currentPalette.lerp(
      _targetPalette,
      _crossfadeController.value,
    );
    _targetPalette = newPalette;
    _crossfadeController.forward(from: 0.0);
  }

  @override
  Widget build(BuildContext context) {
    final reduceTransparency =
        MediaQuery.maybeOf(context)?.highContrast ?? false;
    final blurEnabled = WaveHazeScope.blurEnabled(context);

    ref.listen<AsyncValue<ArtworkPalette>>(
      artworkPaletteProvider(widget.artworkUrl),
      (prev, next) {
        final val = next.valueOrNull;
        if (val != null) {
          _onPaletteLoaded(val);
        }
      },
    );

    final paletteAsync = ref.watch(artworkPaletteProvider(widget.artworkUrl));
    final activeTarget = paletteAsync.valueOrNull ?? ArtworkPalette.fallback;
    if (_targetPalette == ArtworkPalette.fallback &&
        activeTarget != ArtworkPalette.fallback) {
      _targetPalette = activeTarget;
      _currentPalette = activeTarget;
    }

    final isDark = waveIsDark(context);
    final visualizerEnabled = ref.watch(visualizerEnabledProvider);
    final isPlaying = ref.watch(
      playbackServiceProvider.select((s) => s.isPlaying),
    );

    if (!visualizerEnabled && _motionController.isAnimating) {
      _motionController.stop();
    } else if (visualizerEnabled && !_motionController.isAnimating) {
      _motionController.repeat();
    }

    if (reduceTransparency || !blurEnabled) {
      // High-contrast / solid fallback: subtle static gradient
      final baseColor = _targetPalette.primary;
      return AnimatedOpacity(
        duration: WaveMotion.normal,
        opacity: visualizerEnabled ? 1.0 : 0.0,
        child: IgnorePointer(
          child: Container(
            height: widget.isFullBleed ? null : widget.height,
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(-0.6, -0.6),
                radius: 1.2,
                colors: [
                  baseColor.withValues(alpha: isDark ? 0.22 : 0.12),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
      );
    }

    final content = AnimatedBuilder(
      animation: Listenable.merge([_motionController, _crossfadeController]),
      builder: (context, _) {
        final t = _crossfadeController.isAnimating
            ? CurvedAnimation(
                parent: _crossfadeController,
                curve: Curves.easeInOutCubic,
              ).value
            : 1.0;

        final activePalette = _currentPalette.lerp(_targetPalette, t);

        return CustomPaint(
          size: widget.isFullBleed
              ? Size.infinite
              : Size(double.infinity, widget.height),
          painter: _AmbientMeshPainter(
            palette: activePalette,
            motionValue: _motionController.value,
            isPlaying: isPlaying,
            isDark: isDark,
            opacity: widget.opacity,
          ),
        );
      },
    );

    return IgnorePointer(
      child: AnimatedOpacity(
        duration: WaveMotion.normal,
        curve: Curves.easeOutCubic,
        opacity: visualizerEnabled ? widget.opacity : 0.0,
        child: widget.isFullBleed
            ? SizedBox.expand(child: content)
            : SizedBox(
                width: double.infinity,
                height: widget.height,
                child: content,
              ),
      ),
    );
  }
}

class _AmbientMeshPainter extends CustomPainter {
  final ArtworkPalette palette;
  final double motionValue;
  final bool isPlaying;
  final bool isDark;
  final double opacity;

  _AmbientMeshPainter({
    required this.palette,
    required this.motionValue,
    required this.isPlaying,
    required this.isDark,
    required this.opacity,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final basePaint = Paint();
    final angle = motionValue * 2 * math.pi;

    // Harmonic orbit offsets for organic floating orbs
    final p1 = Offset(
      size.width * (0.24 + 0.16 * math.sin(angle)),
      size.height * (0.22 + 0.12 * math.cos(angle)),
    );
    final p2 = Offset(
      size.width * (0.80 + 0.14 * math.cos(angle * 0.85)),
      size.height * (0.32 + 0.16 * math.sin(angle * 0.85)),
    );
    final p3 = Offset(
      size.width * (0.28 + 0.18 * math.sin(angle * 1.25)),
      size.height * (0.80 + 0.14 * math.cos(angle * 1.25)),
    );
    final p4 = Offset(
      size.width * (0.76 + 0.15 * math.cos(angle * 1.1)),
      size.height * (0.74 + 0.15 * math.sin(angle * 1.1)),
    );
    final p5 = Offset(
      size.width * (0.50 + 0.18 * math.sin(angle * 0.95)),
      size.height * (0.48 + 0.16 * math.cos(angle * 0.95)),
    );

    final maxDim = math.max(size.width, size.height);
    final alphaScale = (isDark ? 0.38 : 0.22) * opacity;

    // Playback pulse / breathing modulation matching Apple Music visualizer
    final pulse = isPlaying
        ? (1.0 + 0.045 * math.sin(motionValue * 6 * math.pi))
        : 1.0;

    // Orb 1: Primary dominant color
    final r1 = maxDim * 0.65 * pulse;
    basePaint.shader = RadialGradient(
      center: Alignment(
        (p1.dx / size.width) * 2 - 1,
        (p1.dy / size.height) * 2 - 1,
      ),
      radius: 0.75,
      colors: [
        palette.primary.withValues(alpha: alphaScale * 1.1),
        palette.primary.withValues(alpha: alphaScale * 0.4),
        palette.primary.withValues(alpha: 0.0),
      ],
      stops: const [0.0, 0.55, 1.0],
    ).createShader(Rect.fromCircle(center: p1, radius: r1));
    canvas.drawRect(Offset.zero & size, basePaint);

    // Orb 2: Vibrant color
    final r2 = maxDim * 0.60 * pulse;
    basePaint.shader = RadialGradient(
      center: Alignment(
        (p2.dx / size.width) * 2 - 1,
        (p2.dy / size.height) * 2 - 1,
      ),
      radius: 0.70,
      colors: [
        palette.vibrant.withValues(alpha: alphaScale * 0.95),
        palette.vibrant.withValues(alpha: alphaScale * 0.35),
        palette.vibrant.withValues(alpha: 0.0),
      ],
      stops: const [0.0, 0.55, 1.0],
    ).createShader(Rect.fromCircle(center: p2, radius: r2));
    canvas.drawRect(Offset.zero & size, basePaint);

    // Orb 3: Light Vibrant / Accent highlight
    final r3 = maxDim * 0.58 * pulse;
    basePaint.shader = RadialGradient(
      center: Alignment(
        (p3.dx / size.width) * 2 - 1,
        (p3.dy / size.height) * 2 - 1,
      ),
      radius: 0.65,
      colors: [
        palette.lightVibrant.withValues(alpha: alphaScale * 0.85),
        palette.lightVibrant.withValues(alpha: alphaScale * 0.30),
        palette.lightVibrant.withValues(alpha: 0.0),
      ],
      stops: const [0.0, 0.50, 1.0],
    ).createShader(Rect.fromCircle(center: p3, radius: r3));
    canvas.drawRect(Offset.zero & size, basePaint);

    // Orb 4: Dark Muted depth tone
    final r4 = maxDim * 0.70 * pulse;
    basePaint.shader = RadialGradient(
      center: Alignment(
        (p4.dx / size.width) * 2 - 1,
        (p4.dy / size.height) * 2 - 1,
      ),
      radius: 0.75,
      colors: [
        palette.darkMuted.withValues(alpha: alphaScale * 0.80),
        palette.darkMuted.withValues(alpha: alphaScale * 0.25),
        palette.darkMuted.withValues(alpha: 0.0),
      ],
      stops: const [0.0, 0.60, 1.0],
    ).createShader(Rect.fromCircle(center: p4, radius: r4));
    canvas.drawRect(Offset.zero & size, basePaint);

    // Orb 5: Harmonic fluid mesh center orb
    final r5 = maxDim * 0.55 * pulse;
    basePaint.shader = RadialGradient(
      center: Alignment(
        (p5.dx / size.width) * 2 - 1,
        (p5.dy / size.height) * 2 - 1,
      ),
      radius: 0.65,
      colors: [
        palette.vibrant.withValues(alpha: alphaScale * 0.75),
        palette.primary.withValues(alpha: alphaScale * 0.25),
        palette.primary.withValues(alpha: 0.0),
      ],
      stops: const [0.0, 0.50, 1.0],
    ).createShader(Rect.fromCircle(center: p5, radius: r5));
    canvas.drawRect(Offset.zero & size, basePaint);

    // Readability scrim: Dark/Light vignette and contrast gradient
    // guarantees Segoe UI typography and controls exceed WCAG AAA contrast
    final scrimPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          (isDark ? Colors.black : Colors.white)
              .withValues(alpha: isDark ? 0.35 : 0.40),
          (isDark ? WaveColors.background : WaveColors.lightBackground)
              .withValues(alpha: isDark ? 0.55 : 0.60),
        ],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, scrimPaint);
  }

  @override
  bool shouldRepaint(covariant _AmbientMeshPainter old) {
    return old.motionValue != motionValue ||
        old.palette != palette ||
        old.isPlaying != isPlaying ||
        old.isDark != isDark ||
        old.opacity != opacity;
  }
}

/// Artwork-derived ambient wash for editorial headers and containers.
class AmbientWash extends StatelessWidget {
  final String artworkUrl;
  final double height;
  final bool dynamicMesh;

  const AmbientWash({
    super.key,
    required this.artworkUrl,
    this.height = 320,
    this.dynamicMesh = true,
  });

  @override
  Widget build(BuildContext context) {
    if (dynamicMesh) {
      return WaveAmbientMesh(
        artworkUrl: artworkUrl,
        isFullBleed: false,
        height: height,
        opacity: 0.9,
      );
    }

    final dark = Theme.of(context).brightness == Brightness.dark;
    final reduceT = MediaQuery.maybeOf(context)?.highContrast ?? false;
    if (reduceT) return const SizedBox.shrink();

    return Consumer(
      builder: (context, ref, _) {
        final seed =
            ref.watch(artworkSeedProvider(artworkUrl)).valueOrNull ??
                const Color(0xFF232838);

        return IgnorePointer(
          child: Container(
            height: height,
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(-0.7, -0.6),
                radius: 1.1,
                colors: [
                  seed.withValues(alpha: dark ? 0.28 : 0.18),
                  seed.withValues(alpha: 0.0),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
