import 'package:fluent_ui/fluent_ui.dart';

/// CANONICAL — all agents must import this, do NOT use LwColors/LwRadius.
///
/// `lib/ui/theme/tokens.dart` is the single source of truth for the
/// LastWave "Wave" design system. The legacy `lib/design_system/tokens.dart`
/// (`LwColors` / `LwRadius` — ice-blue accent, 12–24px radii) is retired:
/// do not import it from new code, do not copy values out of it.
///
/// Wave direction:
/// - Neutral graphite base (#0E0E0E / #161616 / #1E1E1E), off-white text.
/// - NO blue/navy theme, NO 20–30px radii, NO giant pills (pill shapes are
///   allowed ONLY for [WaveChip]-style chips and circular transport
///   buttons).
/// - The base stays neutral; artwork drives personality. The off-white
///   accent is used sparingly (play affordance, progress fill, selection),
///   never as large tinted surfaces.
class WaveColors {
  WaveColors._();

  // Neutral base — true graphite, zero blue.
  static const background = Color(0xFF0E0E0E);
  static const backgroundDeep = Color(0xFF0A0A0A);
  static const surface = Color(0xFF161616);
  static const surfaceRaised = Color(0xFF1E1E1E);
  static const surfaceOverlay = Color(0xFF262626);

  // Translucent shells painted over Mica.
  static const panelTranslucent = Color(0xE6161616);
  static const dockTranslucent = Color(0xF2141414);
  static const railTranslucent = Color(0xE60E0E0E);

  static const outline = Color(0xFF2B2B2B);
  static const outlineSoft = Color(0xFF1F1F1F);

  /// Soft hairline / wash surface (#1F1F1F). Alias of [outlineSoft].
  static const soft = outlineSoft;

  static const textPrimary = Color(0xFFF5F4F0);
  static const textSecondary = Color(0xFFA8A6A0);
  static const textTertiary = Color(0xFF6E6C66);

  // Neutral accent — off-white. Play / progress / selected use this
  // by default; artwork tint may override sparingly at runtime.
  static const defaultAccent = Color(0xFFF5F4F0);
  static const accentDim = Color(0xFF3A3A38);
  static const success = Color(0xFF7BE3A8);
  static const warn = Color(0xFFE0A030);
  static const danger = Color(0xFFE0506A);

  // Light — Windows 11 neutral, NOT beige.
  // Base app: #F3F3F3 Mica-like · nav: #ECECEC tinted · content: #F9F9F9
  // clean · player: #FFFFFF elevated · flyouts: white acrylic.
  static const lightBackground = Color(0xFFF3F3F3);
  static const lightNavBackground = Color(0xFFECECEC);
  static const lightContent = Color(0xFFF9F9F9);
  static const lightSurface = Color(0xFFFFFFFF);
  static const lightSurfaceRaised = Color(0xFFFFFFFF);
  static const lightOverlay = Color(0xFFEDEBE9);
  static const lightOutline = Color(0xFFE1DFDD);
  static const lightOutlineSoft = Color(0xFFEDEBE9);
  static const lightTextPrimary = Color(0xFF1B1A19);
  static const lightTextSecondary = Color(0xFF605E5C);
  static const lightTextTertiary = Color(0xFF8A8886);
}

/// Spacing scale (px): 4 / 8 / 12 / 16 / 20 / 24 / 32 / 40.
///
/// Field names are historic (`x2` = 4 … `x32` = 40); values are canonical.
class WaveSpacing {
  WaveSpacing._();
  static const double x2 = 4;
  static const double x4 = 8;
  static const double x8 = 12;
  static const double x12 = 16;
  static const double x16 = 20;
  static const double x20 = 24;
  static const double x28 = 32;
  static const double x32 = 40;
}

/// Radii (px) — sharp system.
///
/// - tiny 3: hairline chips, thumbs, dividers that need a cap.
/// - controls 5: buttons, text fields, icon-button hover wells.
/// - menu 7: menus, popovers, flyouts, tooltips.
/// - artwork 6: cover art, tiles.
/// - floating 10: MAX for floating surfaces (dialogs, cards, shelves).
/// - structural 0: rails, docks, title bars, page scaffolds.
///
/// Do NOT use radii >= 16 anywhere. No 20–30px "soft" cards, no giant
/// pills — pill/circle shapes are reserved for meta chips and the
/// circular transport (play) button only.
class WaveRadius {
  WaveRadius._();
  static const double tiny = 3;
  static const double controls = 5;
  static const double menu = 7;
  static const double artwork = 6;
  static const double floating = 10;
  static const double structural = 0;

  static BorderRadius get tinyRadius =>
      BorderRadius.circular(tiny);
  static BorderRadius get controlsRadius =>
      BorderRadius.circular(controls);
  static BorderRadius get menuRadius => BorderRadius.circular(menu);
  static BorderRadius get artworkRadius =>
      BorderRadius.circular(artwork);
  static BorderRadius get floatingRadius =>
      BorderRadius.circular(floating);
}

/// Compact density — real desktop music player zones.
class WaveDensity {
  WaveDensity._();
  static const double railCollapsed = 60;
  static const double railExpanded = 200;
  static const double titleBar = 44;
  static const double dock = 80;
  static const double trackRow = 54;
  static const double trackArt = 40;
  static const double contextPanel = 360;
  static const double contextPanelWide = 380;
  static const double contentMax = 1280;
  static const double lyricMax = 620;
  static const double hitArea = 36;
  static const double iconPrimary = 18;
  static const double iconSecondary = 15;
}

/// Typography: artwork + type carry hierarchy, not boxes.
///
/// - pageTitle 22/700/-0.4 · sectionTitle 15/700 · trackTitle 13.5/600
/// - body 13 · meta 12 · label 12/600/0.2 · overline 10.5/700/1.0
/// - numeral: tabular figures for times/counts.
/// - lyricActive 21/700 · lyricIdle 16/500.
class WaveType {
  WaveType._();
  static const pageTitle = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.4,
    height: 1.15,
  );
  static const sectionTitle = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.2,
    height: 1.25,
  );
  static const trackTitle = TextStyle(
    fontSize: 13.5,
    fontWeight: FontWeight.w600,
    height: 1.3,
  );
  static const body = TextStyle(fontSize: 13, height: 1.5);
  static const meta = TextStyle(fontSize: 12, height: 1.45);
  static const label = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.2,
  );
  static const overline = TextStyle(
    fontSize: 10.5,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.0,
  );

  /// Tabular numeral for durations, counts, ranks.
  static const numeral = TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.5,
    height: 1.0,
    fontFeatures: [FontFeature.tabularFigures()],
  );
  static const lyricActive = TextStyle(
    fontSize: 21,
    fontWeight: FontWeight.w700,
    height: 1.55,
    letterSpacing: -0.2,
  );
  static const lyricIdle = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w500,
    height: 1.6,
  );
}

/// Motion: fast 110ms, normal 180ms, slow 260ms, easeOutCubic standard.
class WaveMotion {
  WaveMotion._();
  static const fast = Duration(milliseconds: 110);
  static const normal = Duration(milliseconds: 180);
  static const slow = Duration(milliseconds: 260);

  /// Standard easing for all hover / reveal / layout animation.
  static const Curve standard = Curves.easeOutCubic;
}

/// Hover / focus / cursor contract.
///
/// - hover: 7% white wash (`0.07`) over [WaveMotion.fast] (~120ms).
/// - pressed: 12% wash (`0.12`).
/// - focus: 2px [WaveColors.accentDim] outline (see Fluent `focusTheme`).
/// - cursor: clickable targets wrap in `MouseRegion(cursor:
///   SystemMouseCursors.click)`.
/// - tooltip: 400ms wait (see [WaveState.tooltipDelay], `LWTooltip`,
///   and the Fluent `tooltipTheme`).
class WaveState {
  WaveState._();

  /// White-wash alpha for hover fills (7%).
  static const double hoverAlpha = 0.07;

  /// Wash alpha for pressed fills (12%).
  static const double pressedAlpha = 0.12;

  /// Focus ring width (2px, [WaveColors.accentDim]).
  static const double focusRing = 2;

  /// Tooltip hover delay (400ms).
  static const Duration tooltipDelay = Duration(milliseconds: 400);
}

/// Responsive breakpoints (window width, px).
///
/// - compact < 900 · normal 900–1300 · expanded 1300–1700 · ultrawide 1700+.
enum WaveBreakpoint { compact, normal, expanded, ultrawide }

WaveBreakpoint waveBreakpointFor(double width) {
  if (width >= 1700) return WaveBreakpoint.ultrawide;
  if (width >= 1300) return WaveBreakpoint.expanded;
  if (width >= 900) return WaveBreakpoint.normal;
  return WaveBreakpoint.compact;
}

bool waveIsDark(BuildContext context) =>
    FluentTheme.of(context).brightness == Brightness.dark;

Color waveAccent(BuildContext context) =>
    FluentTheme.of(context).accentColor.normal;

Color waveTextPrimary(BuildContext context) => waveIsDark(context)
    ? WaveColors.textPrimary
    : WaveColors.lightTextPrimary;

Color waveTextSecondary(BuildContext context) => waveIsDark(context)
    ? WaveColors.textSecondary
    : WaveColors.lightTextSecondary;

Color waveTextTertiary(BuildContext context) => waveIsDark(context)
    ? WaveColors.textTertiary
    : WaveColors.lightTextTertiary;

Color waveSurface(BuildContext context) =>
    waveIsDark(context) ? WaveColors.surface : WaveColors.lightSurface;

Color waveDivider(BuildContext context) => waveIsDark(context)
    ? WaveColors.outlineSoft
    : WaveColors.lightOutlineSoft;
