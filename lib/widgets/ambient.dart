import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:palette_generator/palette_generator.dart';

/// Shared artwork-derived ambient color, cached by image identity.
///
/// One provider per URL: Home hero + Now Playing share the same cache
/// entry, deduplicating palette work. Bounded to a 64px probe image;
/// failures fall back to a graphite seed — never blocks the frame.
final artworkSeedProvider =
    FutureProvider.autoDispose.family<Color, String>((ref, url) async {
  if (url.isEmpty) return const Color(0xFF232838);
  ref.keepAlive();
  try {
    final provider = CachedNetworkImageProvider(url,
        maxWidth: 128, maxHeight: 128);
    final palette = await PaletteGenerator.fromImageProvider(
      provider,
      size: const Size(64, 64),
      maximumColorCount: 8,
    );
    return palette.dominantColor?.color ?? const Color(0xFF232838);
  } catch (_) {
    return const Color(0xFF232838);
  }
});

/// Subtle artwork-derived ambient wash for editorial headers.
///
/// Static gradient (no continuous animation, no shader): a soft radial
/// glow at 20–30% alpha over the scaffold, plus a readability scrim.
/// Honors reduced-transparency (renders flat) and reduced-motion
/// (no animation — this widget never animates anyway).
class AmbientWash extends ConsumerWidget {
  final String artworkUrl;
  final double height;
  const AmbientWash({
    super.key,
    required this.artworkUrl,
    this.height = 320,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final reduceT = MediaQuery.maybeOf(context)?.highContrast ?? false;
    final seed =
        ref.watch(artworkSeedProvider(artworkUrl)).valueOrNull ??
            const Color(0xFF232838);
    if (reduceT) return const SizedBox.shrink();
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
  }
}
