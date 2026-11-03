import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';

/// CANONICAL — all agents must import this, do NOT use LwColors/LwRadius.
///
/// `lib/ui/theme/tokens.dart` is the single source of truth for the
/// LastWave "Wave" design system. The legacy `lib/design_system/tokens.dart`
/// (`LwColors` / `LwRadius` — ice-blue accent, 12–24px radii) was retired
/// and DELETED (with `components.dart` / `icons.dart` and the orphaned
/// `features/lyrics/lyrics_view.dart` that was their only importer):
/// do not recreate it, and do not copy values out of it.
///
/// Wave direction:
/// - Neutral graphite base (#0E0E0E / #161616 / #1E1E1E), off-white text.
/// - NO blue/navy theme, NO giant pills (pill shapes are allowed ONLY for
///   [WaveChip]-style chips and circular transport buttons). Radii come
///   from the [WaveRadius] ladder — never a loose numeric literal.
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

  static const textPrimary = Color(0xFFF5F4F0);
  static const textSecondary = Color(0xFFA8A6A0);

  /// Meta tier (timestamps, captions, column sub-headers).
  ///
  /// Sits at 4.7:1 on the raised surface — it used to be `#6E6C66` (3.2:1
  /// raised, 2.9:1 overlay), which is squinty for 11–12px text. Still
  /// clearly quieter than [textSecondary].
  static const textTertiary = Color(0xFF8A8880);

  // Neutral accent — off-white. Play / progress / selected use this
  // by default; artwork tint may override sparingly at runtime.
  static const defaultAccent = Color(0xFFF5F4F0);
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

  /// Meta tier — 4.8:1 on white (was `#8A8886`, 3.5:1). See [textTertiary].
  static const lightTextTertiary = Color(0xFF74726F);

  // AMOLED — pure-black Midnight variant (user pref `lw_amoled`). Only
  // the base/shell surfaces collapse to black; text, outline and accent
  // tokens are shared with the graphite theme so contrast is unchanged.
  static const amoledBackground = Color(0xFF000000);
  static const amoledSurface = Color(0xFF0A0A0A);
  static const amoledSurfaceRaised = Color(0xFF111111);
  static const amoledPanelTranslucent = Color(0xE6000000);
  static const amoledDockTranslucent = Color(0xF2000000);
  static const amoledRailTranslucent = Color(0xE6000000);

  /// Fourth step of the AMOLED ladder (0A → 11 → 1A). Hover tiles and
  /// skeletons used the graphite `#262626` here and showed as grey
  /// patches on the black page.
  static const amoledSurfaceOverlay = Color(0xFF1A1A1A);
}

/// Resolved base-surface palette for the active dark theme.
///
/// Published through [FluentThemeData.extensions] by
/// [buildWaveFluentTheme] so AMOLED black reaches the shell chrome
/// (rail, dock, title bar, panels) without every widget branching on
/// prefs. Read it through [waveBackground] / [waveRailTranslucent] / ….
/// Light themes never consult this — they use the `light*` constants.
@immutable
class WaveSurfaces extends ThemeExtension<WaveSurfaces> {
  final Color background;
  final Color surface;
  final Color surfaceRaised;

  /// Fourth step: hover tiles, skeletons, pressed fills on cards.
  final Color surfaceOverlay;
  final Color panelTranslucent;
  final Color dockTranslucent;
  final Color railTranslucent;

  /// Control outlines (inputs, chips, focus-less borders).
  final Color outline;

  /// Hairlines: dividers and panel edges.
  final Color outlineSoft;

  /// True for a palette generated from the user's Custom theme colour. The
  /// helpers below then read every surface from here in BOTH brightnesses
  /// (a light custom base would otherwise fall back to the pearl
  /// constants).
  final bool isCustom;

  const WaveSurfaces({
    required this.background,
    required this.surface,
    required this.surfaceRaised,
    required this.panelTranslucent,
    required this.dockTranslucent,
    required this.railTranslucent,
    this.surfaceOverlay = WaveColors.surfaceOverlay,
    this.outline = WaveColors.outline,
    this.outlineSoft = WaveColors.outlineSoft,
    this.isCustom = false,
  });

  /// Default graphite Midnight palette.
  static const graphite = WaveSurfaces(
    background: WaveColors.background,
    surface: WaveColors.surface,
    surfaceRaised: WaveColors.surfaceRaised,
    panelTranslucent: WaveColors.panelTranslucent,
    dockTranslucent: WaveColors.dockTranslucent,
    railTranslucent: WaveColors.railTranslucent,
  );

  /// Pure-black AMOLED palette.
  static const amoled = WaveSurfaces(
    background: WaveColors.amoledBackground,
    surface: WaveColors.amoledSurface,
    surfaceRaised: WaveColors.amoledSurfaceRaised,
    surfaceOverlay: WaveColors.amoledSurfaceOverlay,
    panelTranslucent: WaveColors.amoledPanelTranslucent,
    dockTranslucent: WaveColors.amoledDockTranslucent,
    railTranslucent: WaveColors.amoledRailTranslucent,
  );

  /// Preset bases offered by the Custom theme picker (any colour works).
  static const customPresets = <(String, Color)>[
    ('Ocean', Color(0xFF1A2A44)),
    ('Forest', Color(0xFF13261C)),
    ('Plum', Color(0xFF2A1838)),
    ('Wine', Color(0xFF3A1622)),
    ('Espresso', Color(0xFF2B2018)),
    ('Slate', Color(0xFF1E242C)),
    ('Teal', Color(0xFF0B3D3A)),
    ('Sand', Color(0xFFEFE7DA)),
    ('Mint', Color(0xFFE4F1E9)),
    ('Lavender', Color(0xFFECE6F6)),
    ('Sky', Color(0xFFE3ECF7)),
  ];

  /// Whether [base] produces a light Custom theme (dark text). Mid tones
  /// resolve to dark: the generator clamps the page to a readable value.
  static bool isLightBase(Color base) => base.computeLuminance() > 0.35;

  /// A full surface ladder from one user colour.
  ///
  /// The hue is kept; saturation and lightness are clamped, and the steps
  /// mirror the graphite ladder (0E → 16 → 1E → 26): each one a little
  /// lighter and a little less saturated, so raised layers never turn neon
  /// on vivid bases. Light bases mirror the pearl layout: cards lighter
  /// than the page, the rail and hover tiles slightly darker.
  ///
  /// HSL lightness doesn't track perceived brightness (a vivid green is
  /// far brighter than a blue at the same value), so the page is then
  /// nudged darker (or lighter) until secondary text keeps WCAG AA (4.5:1)
  /// on the brightest (or darkest) step. Primary text then clears ~10:1.
  factory WaveSurfaces.fromCustomBase(Color base) {
    final hsl = HSLColor.fromColor(base.withValues(alpha: 1));
    Color tone(double lightness, double saturation) => hsl
        .withLightness(lightness.clamp(0.0, 1.0))
        .withSaturation(saturation.clamp(0.0, 1.0))
        .toColor();
    if (isLightBase(base)) {
      final sat = hsl.saturation.clamp(0.0, 0.45);
      var l = hsl.lightness.clamp(0.88, 0.96);
      for (var i = 0;
          i < 40 &&
              _contrast(WaveColors.lightTextSecondary, tone(l - 0.04, sat)) <
                  4.5;
          i++) {
        l += 0.005;
      }
      final card = tone(math.min(l + 0.035, 0.99), sat);
      return WaveSurfaces(
        background: tone(l, sat),
        surface: card,
        surfaceRaised: card,
        surfaceOverlay: tone(l - 0.04, sat),
        panelTranslucent: card,
        dockTranslucent: card,
        railTranslucent: tone(l - 0.025, sat),
        outline: tone(l - 0.10, sat * 0.7),
        outlineSoft: tone(l - 0.06, sat * 0.7),
        isCustom: true,
      );
    }
    final sat = hsl.saturation.clamp(0.0, 0.55);
    var l = hsl.lightness.clamp(0.04, 0.16);
    for (var i = 0;
        i < 40 &&
            l > 0 &&
            _contrast(WaveColors.textSecondary, tone(l + 0.105, sat * 0.8)) <
                4.5;
        i++) {
      l -= 0.005;
    }
    final background = tone(l, sat);
    final surface = tone(l + 0.035, sat * 0.9);
    return WaveSurfaces(
      background: background,
      surface: surface,
      surfaceRaised: tone(l + 0.07, sat * 0.85),
      surfaceOverlay: tone(l + 0.105, sat * 0.8),
      // Same alphas as the graphite translucents (E6 / F2 / E6).
      panelTranslucent: surface.withValues(alpha: 0.90),
      dockTranslucent:
          Color.lerp(background, surface, 0.5)!.withValues(alpha: 0.95),
      railTranslucent: background.withValues(alpha: 0.90),
      outline: tone(l + 0.10, sat * 0.6),
      outlineSoft: tone(l + 0.06, sat * 0.6),
      isCustom: true,
    );
  }

  /// WCAG contrast ratio between two opaque colours.
  static double _contrast(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
  }

  @override
  WaveSurfaces copyWith({
    Color? background,
    Color? surface,
    Color? surfaceRaised,
    Color? surfaceOverlay,
    Color? panelTranslucent,
    Color? dockTranslucent,
    Color? railTranslucent,
    Color? outline,
    Color? outlineSoft,
    bool? isCustom,
  }) {
    return WaveSurfaces(
      background: background ?? this.background,
      surface: surface ?? this.surface,
      surfaceRaised: surfaceRaised ?? this.surfaceRaised,
      surfaceOverlay: surfaceOverlay ?? this.surfaceOverlay,
      panelTranslucent: panelTranslucent ?? this.panelTranslucent,
      dockTranslucent: dockTranslucent ?? this.dockTranslucent,
      railTranslucent: railTranslucent ?? this.railTranslucent,
      outline: outline ?? this.outline,
      outlineSoft: outlineSoft ?? this.outlineSoft,
      isCustom: isCustom ?? this.isCustom,
    );
  }

  @override
  WaveSurfaces lerp(ThemeExtension<WaveSurfaces>? other, double t) {
    if (other is! WaveSurfaces) return this;
    return WaveSurfaces(
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceRaised: Color.lerp(surfaceRaised, other.surfaceRaised, t)!,
      surfaceOverlay: Color.lerp(surfaceOverlay, other.surfaceOverlay, t)!,
      panelTranslucent:
          Color.lerp(panelTranslucent, other.panelTranslucent, t)!,
      dockTranslucent:
          Color.lerp(dockTranslucent, other.dockTranslucent, t)!,
      railTranslucent:
          Color.lerp(railTranslucent, other.railTranslucent, t)!,
      outline: Color.lerp(outline, other.outline, t)!,
      outlineSoft: Color.lerp(outlineSoft, other.outlineSoft, t)!,
      isCustom: t < 0.5 ? isCustom : other.isCustom,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is WaveSurfaces &&
          other.background == background &&
          other.surface == surface &&
          other.surfaceRaised == surfaceRaised &&
          other.surfaceOverlay == surfaceOverlay &&
          other.panelTranslucent == panelTranslucent &&
          other.dockTranslucent == dockTranslucent &&
          other.railTranslucent == railTranslucent &&
          other.outline == outline &&
          other.outlineSoft == outlineSoft &&
          other.isCustom == isCustom);

  @override
  int get hashCode => Object.hash(
      background,
      surface,
      surfaceRaised,
      surfaceOverlay,
      panelTranslucent,
      dockTranslucent,
      railTranslucent,
      outline,
      outlineSoft,
      isCustom);
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

/// Radii (px) — one step per surface class, monotonic ladder.
///
/// - tiny 6: hairline chips, skeleton bars, status badges, indicator bars.
/// - controls 10: buttons, text fields, nav items, icon-button hover wells.
/// - artwork 12: cover art, thumbs, plus the scrims/overlays that wrap them.
/// - menu 14: menus, popovers, flyouts, tooltips.
/// - floating 20: dialogs, cards, panels, shelves.
/// - hero 24: large cinematic covers and lyric pills.
/// - structural 0: rails, docks, title bars, page scaffolds stay square.
///
/// The ladder is deliberately monotonic (6 → 10 → 12 → 14 → 20 → 24) so a
/// surface's radius reads as its "size class". Pill/circle shapes (`999`)
/// are still reserved for meta chips and the circular transport (play)
/// button — never for cards or controls.
///
/// Rule of thumb: a container that tightly wraps artwork shares the
/// artwork radius, so covers and their hover scrims never mismatch.
class WaveRadius {
  WaveRadius._();
  static const double tiny = 6;
  static const double controls = 10;
  static const double artwork = 12;
  static const double menu = 14;
  static const double floating = 20;
  static const double hero = 24;
  static const double structural = 0;

  static BorderRadius get tinyRadius =>
      BorderRadius.circular(tiny);
  static BorderRadius get controlsRadius =>
      BorderRadius.circular(controls);
  static BorderRadius get artworkRadius =>
      BorderRadius.circular(artwork);
  static BorderRadius get menuRadius => BorderRadius.circular(menu);
  static BorderRadius get floatingRadius =>
      BorderRadius.circular(floating);
  static BorderRadius get heroRadius => BorderRadius.circular(hero);
}

/// Compact density — real desktop music player zones.
class WaveDensity {
  WaveDensity._();
  static const double railCollapsed = 60;
  static const double railExpanded = 200;
  static const double titleBar = 44;
  static const double dock = 68;
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

/// The OS "reduce motion" switch — KDE's animation speed, GNOME's
/// animations toggle, Windows "Show animations", macOS Reduce Motion.
///
/// Only [WaveBranchSwitcher] honoured it before: every entrance, press dip
/// and hover lift ran regardless, because each one reached for
/// [WaveMotion.fast] straight instead of asking. Route `duration:` through
/// [waveMotion] and the switch reaches all of them.
bool waveReduceMotion(BuildContext context) =>
    MediaQuery.maybeDisableAnimationsOf(context) ?? false;

/// Collapses an implicit-animation [duration] under reduce motion.
///
/// The switch means "arrive, don't travel": a hover wash, a press dip or a
/// selection change still happens, it just doesn't interpolate. Motion that
/// is the whole affordance — entrances ([WaveEntrance]), repeating tickers,
/// route scale flights — is skipped outright instead of landing at zero ms.
Duration waveMotion(BuildContext context, Duration duration) =>
    waveReduceMotion(context) ? Duration.zero : duration;

/// Hover / focus / cursor contract.
///
/// - hover: 7% wash (`0.07`) over [WaveMotion.fast] (~120ms) — use
///   [waveHoverWash] so the wash flips with the theme.
/// - pressed: 12% wash (`0.12`) — [wavePressedWash].
/// - focus: 2px [waveFocusRing] outline (see Fluent `focusTheme`).
/// - on-accent glyphs: [waveOnAccent] (never a hardcoded white).
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

  /// Focus ring width (2px, [waveFocusRing]).
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

/// Foreground for a glyph sitting on accent-filled chrome.
///
/// The accent is user-chosen — brand red, the off-white "LastWave
/// neutral" source, a pale artwork tint — so an on-accent glyph can never
/// be a hardcoded white: with the off-white accent the play glyphs used to
/// disappear into their own disc.
Color onAccentFor(Color accent) =>
    accent.computeLuminance() > 0.5 ? Colors.black : Colors.white;

/// [onAccentFor] for the current theme accent.
Color waveOnAccent(BuildContext context) => onAccentFor(waveAccent(context));

/// Wash base: white on dark chrome, black on pearl. Every hover / pressed
/// fill goes through [waveWash], so a hardcoded white wash (invisible in
/// light mode) can't creep back in.
Color waveWash(BuildContext context, double alpha) =>
    (waveIsDark(context) ? Colors.white : Colors.black)
        .withValues(alpha: alpha);

/// Hover fill over a neutral surface (7%, [WaveState.hoverAlpha]).
Color waveHoverWash(BuildContext context) =>
    waveWash(context, WaveState.hoverAlpha);

/// Pressed fill over a neutral surface (12%, [WaveState.pressedAlpha]).
Color wavePressedWash(BuildContext context) =>
    waveWash(context, WaveState.pressedAlpha);

/// Focus ring colour (2px, [WaveState.focusRing]).
///
/// The accent at near-full strength: the fixed dark grey it used to be
/// was invisible against the graphite base, and the accent already means
/// "this is the thing you selected" everywhere else.
Color waveFocusRing(BuildContext context) =>
    waveAccent(context).withValues(alpha: 0.85);

Color waveTextPrimary(BuildContext context) => waveIsDark(context)
    ? WaveColors.textPrimary
    : WaveColors.lightTextPrimary;

Color waveTextSecondary(BuildContext context) => waveIsDark(context)
    ? WaveColors.textSecondary
    : WaveColors.lightTextSecondary;

Color waveTextTertiary(BuildContext context) => waveIsDark(context)
    ? WaveColors.textTertiary
    : WaveColors.lightTextTertiary;

/// Active base-surface palette: graphite, AMOLED, or the user's Custom
/// theme. Falls back to graphite when no theme extension is published
/// (e.g. a widget rendered outside [FluentApp] in a test).
WaveSurfaces waveSurfaces(BuildContext context) =>
    FluentTheme.of(context).extension<WaveSurfaces>() ??
    WaveSurfaces.graphite;

/// Resolves one surface role. A Custom palette answers in both
/// brightnesses; otherwise dark reads the published palette (graphite or
/// AMOLED) and light uses the pearl constant.
Color _surfaceRole(
  BuildContext context,
  Color Function(WaveSurfaces s) pick,
  Color pearl,
) {
  final s = waveSurfaces(context);
  if (s.isCustom || waveIsDark(context)) return pick(s);
  return pearl;
}

/// Page/scaffold background. AMOLED- and Custom-aware.
Color waveBackground(BuildContext context) =>
    _surfaceRole(context, (s) => s.background, WaveColors.lightBackground);

Color waveSurface(BuildContext context) =>
    _surfaceRole(context, (s) => s.surface, WaveColors.lightSurface);

Color waveSurfaceRaised(BuildContext context) => _surfaceRole(
    context, (s) => s.surfaceRaised, WaveColors.lightSurfaceRaised);

/// Fourth surface step: hover tiles, skeletons, inset wells.
Color waveSurfaceOverlay(BuildContext context) =>
    _surfaceRole(context, (s) => s.surfaceOverlay, WaveColors.lightOverlay);

Color wavePanelTranslucent(BuildContext context) =>
    _surfaceRole(context, (s) => s.panelTranslucent, WaveColors.lightSurface);

Color waveDockTranslucent(BuildContext context) =>
    _surfaceRole(context, (s) => s.dockTranslucent, WaveColors.lightSurface);

Color waveRailTranslucent(BuildContext context) => _surfaceRole(
    context, (s) => s.railTranslucent, WaveColors.lightNavBackground);

/// Control outline (inputs, chips, bordered tiles).
Color waveOutline(BuildContext context) =>
    _surfaceRole(context, (s) => s.outline, WaveColors.lightOutline);

/// Softer outline for quiet edges.
Color waveOutlineSoft(BuildContext context) =>
    _surfaceRole(context, (s) => s.outlineSoft, WaveColors.lightOutlineSoft);

/// Hairline stroke: dividers, panel edges, control outlines.
///
/// Light mode paints black at 10% instead of a fixed grey. The pearl page
/// is `#F3F3F3` and its cards are white, so any single grey could only
/// ever read on one of the two. A Custom palette uses its own hue-matched
/// hairline, so dividers don't show as neutral grey lines on a tinted page.
Color waveDivider(BuildContext context) {
  final s = waveSurfaces(context);
  if (s.isCustom) return s.outlineSoft;
  return waveIsDark(context)
      ? s.outlineSoft
      : Colors.black.withValues(alpha: 0.10);
}

/// Elevation ladder for surfaces that float over the page.
///
/// Dark mode leans on value — three distinct surface tones — and a deep
/// black shadow. The pearl page is `#F3F3F3` with `#FFFFFF` cards, and
/// `lightSurface == lightSurfaceRaised`, so a light float has to separate
/// by stroke ([waveDivider]) and shadow instead; the same 45% black 32px
/// plate that reads as depth on graphite reads as a dirty smear on white.
/// Light therefore keeps the dark shapes at roughly a third of the
/// strength — Windows 11 flyout weight.
///
/// Every floating surface goes through here so a shadow cannot drift back
/// into a hardcoded literal that only ever suited one theme.
class WaveElevation {
  WaveElevation._();

  /// Artwork hover lift: the cover rises off the grid.
  static List<BoxShadow> lift(bool dark) => [
        BoxShadow(
          color: Colors.black.withValues(alpha: dark ? 0.45 : 0.18),
          blurRadius: 16,
          offset: const Offset(0, 6),
        ),
      ];

  /// Feature artwork at hero size — a deeper drop than [lift].
  static List<BoxShadow> artwork(bool dark) => [
        BoxShadow(
          color: Colors.black.withValues(alpha: dark ? 0.45 : 0.16),
          blurRadius: 24,
          offset: const Offset(0, 10),
        ),
      ];

  /// Full-height side panel (queue, lyrics, side sheets), cast inward.
  static List<BoxShadow> panel(bool dark) => [
        BoxShadow(
          color: Colors.black.withValues(alpha: dark ? 0.45 : 0.16),
          blurRadius: dark ? 32 : 28,
          offset: const Offset(-10, 0),
        ),
      ];

  /// Menu / dialog flyout: two layers, the tight one giving the edge.
  static List<BoxShadow> flyout(bool dark) => const [
        BoxShadow(
          color: Color(0x21000000),
          blurRadius: 7.2,
          offset: Offset(0, 3.2),
        ),
        BoxShadow(
          color: Color(0x1C000000),
          blurRadius: 1.8,
          offset: Offset(0, 0.68),
        ),
      ];

  /// Round transport control sitting on the dock.
  static List<BoxShadow> transport(bool dark) => [
        BoxShadow(
          color: Colors.black.withValues(alpha: dark ? 0.45 : 0.18),
          blurRadius: 8,
          offset: const Offset(0, 2),
        ),
      ];
}
