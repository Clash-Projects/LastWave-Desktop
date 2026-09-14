import 'package:fluent_ui/fluent_ui.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../ui/components/artwork.dart';
import '../ui/theme/tokens.dart';

/// Thin shim over [WaveArtwork]: bounded decode, music-note fallback.
///
/// Keeps the legacy [Artwork] constructor for call-site compatibility;
/// presentation is owned by `lib/ui/components/artwork.dart`.
class Artwork extends StatelessWidget {
  final String url;
  final double size;
  final double radius;
  final IconData fallbackIcon;
  const Artwork({
    super.key,
    required this.url,
    this.size = 48,
    this.radius = WaveRadius.artwork,
    this.fallbackIcon = LucideIcons.disc3,
  });

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty && fallbackIcon != LucideIcons.music) {
      final dark = waveIsDark(context);
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: dark
              ? WaveColors.surfaceRaised
              : WaveColors.lightOverlay,
          borderRadius: BorderRadius.circular(radius),
        ),
        child: Icon(
          fallbackIcon,
          size: size * 0.42,
          color: dark
              ? WaveColors.textTertiary
              : WaveColors.lightTextTertiary,
        ),
      );
    }
    return WaveArtwork(url: url, size: size, radius: radius);
  }
}

/// Thin shim over [WaveArtwork.circle]: round artist avatar.
class ArtistArt extends StatelessWidget {
  final String url;
  final String name;
  final double radius;
  const ArtistArt({
    super.key,
    required this.url,
    required this.name,
    this.radius = 56,
  });

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) {
      final dark = waveIsDark(context);
      return Container(
        width: radius * 2,
        height: radius * 2,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: dark
              ? WaveColors.surfaceRaised
              : WaveColors.lightOverlay,
        ),
        child: Center(
          child: Text(
            name.isNotEmpty ? name[0].toUpperCase() : '?',
            style: WaveType.sectionTitle.copyWith(
              color: dark
                  ? WaveColors.textTertiary
                  : WaveColors.lightTextTertiary,
            ),
          ),
        ),
      );
    }
    return WaveArtwork.circle(url: url, size: radius * 2);
  }
}
