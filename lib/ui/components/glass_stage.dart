import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/player/playback_service.dart';
import 'ambient.dart';

/// Backdrop for the glassmorphism theme, painted once behind the whole app.
///
/// The playing cover's aura drifts underneath, a veil in the theme's own
/// page colour keeps Midnight dark, Pearl bright and Custom / Artwork in
/// their hue, and every surface above is translucent (WaveSurfaces.glass).
/// Covers cross-fade only once the next one's textures are ready.
class WaveGlassStage extends ConsumerStatefulWidget {
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
  ConsumerState<WaveGlassStage> createState() => _WaveGlassStageState();
}

class _WaveGlassStageState extends ConsumerState<WaveGlassStage> {
  String _shown = '';

  @override
  Widget build(BuildContext context) {
    final url = ref.watch(
        playbackServiceProvider.select((s) => s.current?.artworkUrl ?? ''));
    if (url.isEmpty) {
      _shown = '';
    } else if (ref.watch(auraTexturesProvider(url)).hasValue) {
      _shown = url;
    }
    final veil = widget.veil;
    final accent = widget.accent;
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
            child: _shown.isEmpty
                // Nothing playing: soft accent light instead of a cover.
                ? DecoratedBox(
                    key: const ValueKey(''),
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(-0.9, -1),
                        radius: 1.6,
                        colors: [
                          accent.withValues(alpha: widget.light ? 0.30 : 0.38),
                          accent.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  )
                : RepaintBoundary(
                    key: ValueKey(_shown),
                    child: WaveGlassAura(artworkUrl: _shown),
                  ),
          ),
        ),
        // Theme veil, deeper toward the dock so controls keep contrast.
        IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: widget.light
                    ? [veil.withValues(alpha: 0.52), veil.withValues(alpha: 0.68)]
                    : [veil.withValues(alpha: 0.40), veil.withValues(alpha: 0.60)],
              ),
            ),
          ),
        ),
        widget.child,
      ],
    );
  }
}
