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
  final Color panelTranslucent;
  final Color dockTranslucent;
  final Color railTranslucent;

  const WaveSurfaces({
    required this.background,
    required this.surface,
    required this.surfaceRaised,
    required this.panelTranslucent,
    required this.dockTranslucent,
    required this.railTranslucent,
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
    panelTranslucent: WaveColors.amoledPanelTranslucent,
    dockTranslucent: WaveColors.amoledDockTranslucent,
    railTranslucent: WaveColors.amoledRailTranslucent,
  );

  @override
  WaveSurfaces copyWith({
    Color? background,
    Color? surface,
    Color? surfaceRaised,
    Color? panelTranslucent,
    Color? dockTranslucent,
    Color? railTranslucent,
  }) {
    return WaveSurfaces(
      background: background ?? this.background,
      surface: surface ?? this.surface,
      surfaceRaised: surfaceRaised ?? this.surfaceRaised,
      panelTranslucent: panelTranslucent ?? this.panelTranslucent,
      dockTranslucent: dockTranslucent ?? this.dockTranslucent,
      railTranslucent: railTranslucent ?? this.railTranslucent,
    );
  }

  @override
  WaveSurfaces lerp(ThemeExtension<WaveSurfaces>? other, double t) {
    if (other is! WaveSurfaces) return this;
    return WaveSurfaces(
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceRaised: Color.lerp(surfaceRaised, other.surfaceRaised, t)!,
      panelTranslucent:
          Color.lerp(panelTranslucent, other.panelTranslucent, t)!,
      dockTranslucent:
          Color.lerp(dockTranslucent, other.dockTranslucent, t)!,
      railTranslucent:
          Color.lerp(railTranslucent, other.railTranslucent, t)!,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is WaveSurfaces &&
          other.background == background &&
          other.surface == surface &&
          other.surfaceRaised == surfaceRaised &&
          other.panelTranslucent == panelTranslucent &&
          other.dockTranslucent == dockTranslucent &&
          other.railTranslucent == railTranslucent);

  @override
  int get hashCode => Object.hash(background, surface, surfaceRaised,
      panelTranslucent, dockTranslucent, railTranslucent);
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

/// Active dark base-surface palette (graphite or AMOLED). Falls back to
/// graphite when no theme extension is published (e.g. a widget rendered
/// outside [FluentApp] in a test).
WaveSurfaces waveSurfaces(BuildContext context) =>
    FluentTheme.of(context).extension<WaveSurfaces>() ??
    WaveSurfaces.graphite;

/// Page/scaffold background. AMOLED-aware.
Color waveBackground(BuildContext context) => waveIsDark(context)
    ? waveSurfaces(context).background
    : WaveColors.lightBackground;

Color waveSurface(BuildContext context) => waveIsDark(context)
    ? waveSurfaces(context).surface
    : WaveColors.lightSurface;

Color waveSurfaceRaised(BuildContext context) => waveIsDark(context)
    ? waveSurfaces(context).surfaceRaised
    : WaveColors.lightSurfaceRaised;

Color wavePanelTranslucent(BuildContext context) => waveIsDark(context)
    ? waveSurfaces(context).panelTranslucent
    : WaveColors.lightSurface;

Color waveDockTranslucent(BuildContext context) => waveIsDark(context)
    ? waveSurfaces(context).dockTranslucent
    : WaveColors.lightSurface;

Color waveRailTranslucent(BuildContext context) => waveIsDark(context)
    ? waveSurfaces(context).railTranslucent
    : WaveColors.lightNavBackground;

/// Hairline stroke: dividers, panel edges, control outlines.
///
/// Light mode paints black at 10% instead of a fixed grey. The pearl page
/// is `#F3F3F3` and its cards are white, so any single grey could only
/// ever read on one of the two — `#EDEBE9` read on neither (6/255 against
/// the page: title bar, rail, dock and every section rule had no edge at
/// all in light mode). An alpha stroke lands at `#DBDBDB` on the page and
/// `#E6E6E6` on a card, which is what one hairline has to look like in
/// both.
Color waveDivider(BuildContext context) => waveIsDark(context)
    ? WaveColors.outlineSoft
    : Colors.black.withValues(alpha: 0.10);

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
