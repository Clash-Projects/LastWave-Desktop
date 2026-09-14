import 'package:fluent_ui/fluent_ui.dart';

import '../../../ui/theme/tokens.dart';

/// Semantic Fluent surfaces — single source of truth for every page.
///
/// New code should read surfaces through [LwSurfaces] (context-aware) or
/// the raw [LwColors] constants below. Do NOT scatter hex literals in
/// pages: import this file.
///
/// Mapping to the canonical Wave tokens (`lib/ui/theme/tokens.dart`):
/// - surfaceBase      → scaffold / Mica base
/// - surfaceLayer1/2  → content layering (cards stay flat, layers differ)
/// - surfaceMica      → native Mica base (window.dart paints this)
/// - surfaceAcrylic   → title chrome / suggestion flyout base
/// - surfaceHaze      → Haze Level 1/2 tonal wash (see lw_materials.dart)
/// - surfaceElevated  → player dock / raised controls
/// - surfaceFlyout    → MenuFlyout / ContentDialog / popover (Haze L3)
/// - surfacePlayer    → persistent player dock (Haze L1 + hairline)
/// - surfaceSelection → selected row wash (accent 10%)
///
/// Text + interaction tokens mirror WinUI rest visuals:
/// hover 7% wash · pressed 12% · selected accent wash · focus 2px ring.
class LwColors {
  LwColors._();

  // -- Dark (graphite, zero navy) -----------------------------------------
  static const surfaceBase = WaveColors.background; // #0E0E0E
  static const surfaceBaseDeep = WaveColors.backgroundDeep; // #0A0A0A
  static const surfaceLayer1 = WaveColors.surface; // #161616
  static const surfaceLayer2 = WaveColors.surfaceRaised; // #1E1E1E
  static const surfaceMica = WaveColors.background;
  static const surfaceAcrylic = WaveColors.panelTranslucent; // 0xE6161616
  static const surfaceHaze = WaveColors.panelTranslucent;
  static const surfaceElevated = WaveColors.surfaceOverlay; // #262626
  static const surfaceFlyout = WaveColors.surfaceRaised; // #1E1E1E
  static const surfacePlayer = WaveColors.dockTranslucent; // 0xF2141414
  static const surfaceSelection = WaveColors.accentDim; // ring + wash base

  static const textPrimary = WaveColors.textPrimary;
  static const textSecondary = WaveColors.textSecondary;
  static const textTertiary = WaveColors.textTertiary;

  static const divider = WaveColors.outlineSoft; // #1F1F1F hairline
  static const dividerStrong = WaveColors.outline; // #2B2B2B

  static const accent = WaveColors.defaultAccent; // off-white neutral
  static const success = WaveColors.success;
  static const warn = WaveColors.warn;
  static const danger = WaveColors.danger;

  // -- Light (neutral off-white, not beige / not pure white) ---------------
  static const lightSurfaceBase = WaveColors.lightBackground; // #F3F3F3
  static const lightSurfaceNav = WaveColors.lightNavBackground; // #ECECEC
  static const lightSurfaceLayer1 = WaveColors.lightContent; // #F9F9F9
  static const lightSurfaceLayer2 = WaveColors.lightSurface; // #FFFFFF
  static const lightSurfaceFlyout = WaveColors.lightSurface;
  static const lightSurfacePlayer = WaveColors.lightSurface;
  static const lightTextPrimary = WaveColors.lightTextPrimary;
  static const lightTextSecondary = WaveColors.lightTextSecondary;
  static const lightTextTertiary = WaveColors.lightTextTertiary;
  static const lightDivider = WaveColors.lightOutlineSoft;
  static const lightDividerStrong = WaveColors.lightOutline;
}

/// Context-aware surface resolution (dark ↔ light).
class LwSurfaces {
  LwSurfaces._();

  static bool isDark(BuildContext context) => waveIsDark(context);

  static Color base(BuildContext context) =>
      isDark(context) ? LwColors.surfaceBase : LwColors.lightSurfaceBase;

  static Color layer1(BuildContext context) => isDark(context)
      ? LwColors.surfaceLayer1
      : LwColors.lightSurfaceLayer1;

  static Color layer2(BuildContext context) => isDark(context)
      ? LwColors.surfaceLayer2
      : LwColors.lightSurfaceLayer2;

  static Color flyout(BuildContext context) => isDark(context)
      ? LwColors.surfaceFlyout
      : LwColors.lightSurfaceFlyout;

  static Color player(BuildContext context) => isDark(context)
      ? LwColors.surfacePlayer
      : LwColors.lightSurfacePlayer.withValues(alpha: 0.97);

  static Color textPrimary(BuildContext context) => waveTextPrimary(context);
  static Color textSecondary(BuildContext context) =>
      waveTextSecondary(context);
  static Color textTertiary(BuildContext context) => waveTextTertiary(context);
  static Color divider(BuildContext context) => waveDivider(context);

  /// Artwork accent: runtime tint applied sparingly (Now Playing wash,
  /// hero wash ≤12%). Base surfaces stay neutral — artwork adds
  /// atmosphere, never floods the app.
  static Color artworkAccent(BuildContext context, Color? tint) =>
      tint ?? waveAccent(context);
}
