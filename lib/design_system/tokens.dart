import 'package:flutter/material.dart';

/// LastWave editorial design tokens — single source of spacing, radius,
/// type, motion, density and breakpoint values.
///
/// Direction: premium editorial desktop music experience with restrained
/// futuristic details. Composition carries richness (rail + ledger +
/// dock + contextual panel), not decorative glass. Translucency is
/// selective (shell, dock, overlays); content stays readable.
///
/// Replaces the previous "observatory" boxed dashboard values:
/// - rail replaces 232px sidebar (now 76px icon ledger)
/// - header 52px unifies identity + history + compact search
/// - dock 76px three-zone replaces 96px bar
/// - ledger rows 52px replace 60px boxed rows
class LwColors {
  LwColors._();

  // -- Midnight (dark) ------------------------------------------------------
  static const background = Color(0xFF070A12);
  static const surface = Color(0xFF0D1119);
  static const surfaceRaised = Color(0xFF131824);
  static const surfaceOverlay = Color(0xFF1A2130);
  static const outline = Color(0xFF26304A);
  static const outlineSoft = Color(0xFF151C2C);

  /// Fine luminous top edge used on floating docks / panels (8-10% white).
  static const luminousEdge = Color(0x1AFFFFFF);

  /// Smoked translucent panel tints (paint over Mica, never full-window).
  static const scrim = Color(0xB3070A12);
  static const panelTranslucent = Color(0xE60D1119);
  static const dockTranslucent = Color(0xE9131824);

  static const textPrimary = Color(0xFFF2F4F9);
  static const textSecondary = Color(0xFFA7AEC0);
  static const textTertiary = Color(0xFF6B7386);

  static const defaultAccent = Color(0xFF7CC4FF);
  static const hiRes = Color(0xFF7CC4FF);
  static const losslessGreen = Color(0xFFC6F100);
  static const warn = Color(0xFFE0A030);
  static const danger = Color(0xFFE0506A);

  static const List<Color> accentChoices = [
    Color(0xFF7CC4FF), // ice blue (default)
    Color(0xFFE03030), // crimson
    Color(0xFF7C4DFF), // violet
    Color(0xFF2196C6), // ocean
    Color(0xFF6B9E6B), // sage
    Color(0xFFE0A030), // amber
    Color(0xFFE0507A), // rose
  ];

  // -- Pearl white (light) ---------------------------------------------------
  static const lightBackground = Color(0xFFF4F6FA);
  static const lightSurface = Color(0xFFFFFFFF);
  static const lightSurfaceRaised = Color(0xFFFFFFFF);
  static const lightSurfaceOverlay = Color(0xFFE9EDF4);
  static const lightOutline = Color(0xFFDDE3EE);
  static const lightOutlineSoft = Color(0xFFEAEEF5);
  static const lightTextPrimary = Color(0xFF0E131C);
  static const lightTextSecondary = Color(0xFF4A5468);
  static const lightTextTertiary = Color(0xFF8A94A8);
  static const lightScrim = Color(0xB3F4F6FA);
  static const lightPanelTranslucent = Color(0xF2FFFFFF);
  static const lightDockTranslucent = Color(0xF5FFFFFF);
}

class LwSpacing {
  LwSpacing._();
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 40;
  static const double huge = 48;
}

class LwRadius {
  LwRadius._();
  static const double xs = 6;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double pill = 999;
}

class LwMotion {
  LwMotion._();
  static const fast = Duration(milliseconds: 120);
  static const normal = Duration(milliseconds: 200);
  static const slow = Duration(milliseconds: 300);
  static const Curve standard = Curves.easeOutCubic;
  static const Curve emphasized = Curves.easeInOutCubic;
}

/// Global motion/transparency kill-switches (accessibility + perf).
class LwMotionScope extends InheritedWidget {
  final bool reduceMotion;
  final bool reduceTransparency;
  const LwMotionScope({
    super.key,
    required this.reduceMotion,
    required this.reduceTransparency,
    required super.child,
  });

  static LwMotionScope of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<LwMotionScope>() ??
        const LwMotionScope(
          reduceMotion: false,
          reduceTransparency: false,
          child: SizedBox.shrink(),
        );
  }

  static bool motionOK(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<LwMotionScope>();
    return !(scope?.reduceMotion ?? false);
  }

  static bool transparencyOK(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<LwMotionScope>();
    return !(scope?.reduceTransparency ?? false);
  }

  @override
  bool updateShouldNotify(LwMotionScope old) =>
      reduceMotion != old.reduceMotion ||
      reduceTransparency != old.reduceTransparency;
}

/// Editorial type: display leads pages, headline leads sections, micro
/// kickers label hierarchy. Tabular figures for times/counts.
class LwType {
  LwType._();

  static const display = TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.6,
    height: 1.1,
  );
  static const headline = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.2,
    height: 1.25,
  );
  static const title = TextStyle(
    fontSize: 13.5,
    fontWeight: FontWeight.w600,
    height: 1.3,
  );
  static const body = TextStyle(fontSize: 13, height: 1.5);
  static const label = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.2,
  );
  static const caption = TextStyle(fontSize: 12, height: 1.45);
  static const micro = TextStyle(
    fontSize: 10.5,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.9,
  );

  /// Large editorial numeral (charts, counts).
  static const numeral = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.4,
    height: 1.0,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// Lyrics reading styles.
  static const lyricActive = TextStyle(
    fontSize: 21,
    fontWeight: FontWeight.w700,
    height: 1.55,
    letterSpacing: -0.2,
  );
  static const lyricIdle = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w500,
    height: 1.55,
  );
}

/// Desktop breakpoints — editorial responsive rules.
///
/// - compact (<900): mini rail + single column, dock condenses,
///   Now Playing becomes tabbed single column.
/// - normal (900–1300): rail + content, dock full three-zone.
/// - expanded (1300–1700): + contextual queue/lyrics panel 320px.
/// - ultrawide (1700+): content max-width centers, panel 360px.
enum LwBreakpoint { compact, normal, expanded, ultrawide }

LwBreakpoint breakpointFor(double width) {
  if (width >= 1700) return LwBreakpoint.ultrawide;
  if (width >= 1300) return LwBreakpoint.expanded;
  if (width >= 900) return LwBreakpoint.normal;
  return LwBreakpoint.compact;
}

/// Editorial density targets (px).
///
/// Old boxed values retired: sidebar 232, player 96, track 60.
/// New ledger values enforce the replacement composition even in
/// monochrome (no decoration needed to tell them apart).
class LwDensity {
  LwDensity._();

  // Legacy names kept for any lingering call sites — now rail values.
  static const double sidebarExpanded = 76;
  static const double sidebarCollapsed = 56;
  static const double topBar = 52;
  static const double trackRow = 52;
  static const double playerBar = 76;

  // Editorial canonicals.
  static const double rail = 76;
  static const double railMini = 56;
  static const double header = 52;
  static const double dock = 76;
  static const double ledgerRow = 52;
  static const double ledgerArt = 40;
  static const double queueRow = 52;
  static const double collectionArt = 160;
  static const double featureArt = 272;
  static const double panel = 320;
  static const double panelWide = 360;
  static const double contentMax = 1160;
  static const double lyricMax = 640;

  static const double navIcon = 18;
  static const double icon = 16;
  static const double controlIcon = 20;
  static const double cardMin = 150;
  static const double cardMax = 210;
}

/// Bounded blur radii — only these surfaces may use backdrop blur.
/// Never blur rows, lists, or full windows.
class LwBlur {
  LwBlur._();
  static const double dock = 18;
  static const double panel = 14;
  static const double dialog = 12;
}
