import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ui/components/ambient.dart';
import '../../ui/theme/tokens.dart';
import '../player/playback_service.dart';
import 'system_accent.dart';
import 'theme_controller.dart';

/// Accent sources offered in Settings → Appearance.
///
/// Stored in prefs as a string ([Prefs.accentSource]); `manual` (legacy) is
/// read as [custom].
enum AccentSource {
  /// The colour picked in Settings ([Prefs.accentColor]).
  custom('custom', 'Custom colour'),

  /// The brand-neutral off-white ([WaveColors.defaultAccent]) — a
  /// monochrome chrome where only artwork carries hue.
  lastwave('lastwave', 'LastWave neutral'),

  /// The desktop environment's accent ([SystemAccent]).
  system('system', 'System accent'),

  /// Tinted from the currently playing cover.
  artwork('artwork', 'Artwork tint');

  const AccentSource(this.id, this.label);

  final String id;
  final String label;

  static AccentSource fromId(String? id) => switch (id) {
        'lastwave' => AccentSource.lastwave,
        'system' => AccentSource.system,
        'artwork' => AccentSource.artwork,
        _ => AccentSource.custom,
      };
}

/// The accent the app paints with, plus how it was obtained — the Settings
/// caption reports the resolution so an inert-looking source ("system" on a
/// desktop that exposes none) is visible instead of silent.
@immutable
class AccentResolution {
  final AccentSource source;

  /// Colour handed to [buildWaveFluentTheme].
  final Color color;

  /// False when [source] could not supply a colour and [color] is the
  /// custom pick instead (system accent unavailable, cover palette too
  /// grey, no track playing yet).
  final bool resolved;

  const AccentResolution({
    required this.source,
    required this.color,
    required this.resolved,
  });

  static const fallback = AccentResolution(
    source: AccentSource.custom,
    color: WaveColors.defaultAccent,
    resolved: true,
  );
}

/// Derives a usable accent from a cover's ambient palette.
///
/// The palette colours are picked for large soft washes, not for accent
/// duty: they can be near-black, near-white or nearly grey. Candidates are
/// normalised into a readable accent band (saturation 0.45–0.85, lightness
/// 0.45–0.62) and `null` is returned when the cover has no hue to give —
/// the caller then keeps the custom accent rather than tinting the whole
/// chrome with a mud colour.
Color? accentFromPalette(ArtworkPalette palette) {
  for (final candidate in [palette.vibrant, palette.primary, palette.lightVibrant]) {
    final hsl = HSLColor.fromColor(candidate);
    if (hsl.saturation < 0.18) continue;
    if (hsl.lightness < 0.12 || hsl.lightness > 0.9) continue;
    return hsl
        .withSaturation(hsl.saturation.clamp(0.45, 0.85))
        .withLightness(hsl.lightness.clamp(0.45, 0.62))
        .toColor();
  }
  return null;
}

/// Desktop accent, read only while the source is [AccentSource.system] —
/// no shell-out on any other setting.
///
/// Re-probes whenever it builds (i.e. when the source changes, or when
/// Settings invalidates it on a re-selection): the user may have just
/// changed the accent in their OS settings.
final systemAccentProvider = FutureProvider<Color?>((ref) {
  final source = ref.watch(
    themeControllerProvider.select((t) => AccentSource.fromId(t.accentSource)),
  );
  if (source != AccentSource.system) return null;
  return SystemAccent.read(refresh: true);
});

/// Accent tinted from the currently playing cover, resolved through the
/// same palette pipeline the Now Playing ambient stage uses (isolate-backed
/// quantiser + LRU, so this costs nothing the page isn't already paying).
final artworkAccentProvider = Provider<Color?>((ref) {
  final source = ref.watch(
    themeControllerProvider.select((t) => AccentSource.fromId(t.accentSource)),
  );
  if (source != AccentSource.artwork) return null;
  final track = ref.watch(playbackServiceProvider.select((s) => s.current));
  final url = track?.artworkUrl ?? '';
  if (url.isEmpty) return null;
  final palette = ref.watch(artworkPaletteProvider(url)).valueOrNull;
  // `.fallback` is what the palette provider hands back on a failed
  // extraction; treating it as a real palette would tint the chrome brown.
  if (palette == null || palette == ArtworkPalette.fallback) return null;
  return accentFromPalette(palette);
});

/// Single place the effective accent is resolved. Every source that cannot
/// answer degrades to the custom pick, so the theme is never left without
/// a colour and never flashes an unthemed default.
final accentResolutionProvider = Provider<AccentResolution>((ref) {
  final theme = ref.watch(themeControllerProvider);
  final custom = theme.accent;
  final source = AccentSource.fromId(theme.accentSource);
  switch (source) {
    case AccentSource.custom:
      return AccentResolution(
        source: source,
        color: custom,
        resolved: true,
      );
    case AccentSource.lastwave:
      return const AccentResolution(
        source: AccentSource.lastwave,
        color: WaveColors.defaultAccent,
        resolved: true,
      );
    case AccentSource.system:
      final system = ref.watch(systemAccentProvider).valueOrNull;
      return AccentResolution(
        source: source,
        color: system ?? custom,
        resolved: system != null,
      );
    case AccentSource.artwork:
      final artwork = ref.watch(artworkAccentProvider);
      return AccentResolution(
        source: source,
        color: artwork ?? custom,
        resolved: artwork != null,
      );
  }
});
