import 'dart:io' show Platform;

import 'package:fluent_ui/fluent_ui.dart';

import 'tokens.dart';

/// Single Fluent component system factory.
///
/// - Dark: charcoal smoked surfaces over native Mica (set in app/window.dart).
/// - Light: white surfaces.
/// - Accent: user accent from prefs, defaulting to neutral off-white
///   ([WaveColors.defaultAccent]). No blue accent defaults anywhere.
/// - Component radii follow [WaveRadius]: menus/popovers 7px, dialogs 10px
///   max, buttons/controls 5px. No pill buttons — pill shapes are reserved
///   for meta chips and the circular transport button.
/// - Tooltips use a 400ms wait ([WaveState.tooltipDelay]).
/// - No competing Material/ledger theming inside lib/ui/.
AccentColor _accentFrom(Color color) {
  // Build a minimal swatch around the user accent so Fluent hover/press
  // states stay coherent for any chosen color.
  final hsl = HSLColor.fromColor(color);
  final darker = hsl.withLightness((hsl.lightness - 0.12).clamp(0.0, 1.0));
  final lighter = hsl.withLightness((hsl.lightness + 0.14).clamp(0.0, 1.0));
  return AccentColor.swatch({
    'darkest': darker.withLightness((darker.lightness - 0.1).clamp(0.0, 1.0)).toColor(),
    'darker': darker.toColor(),
    'dark': darker.withLightness((darker.lightness + 0.05).clamp(0.0, 1.0)).toColor(),
    'normal': color,
    'light': lighter.withLightness((lighter.lightness - 0.05).clamp(0.0, 1.0)).toColor(),
    'lighter': lighter.toColor(),
    'lightest': lighter.withLightness((lighter.lightness + 0.1).clamp(0.0, 1.0)).toColor(),
  });
}

/// Shape shared by every button/control: 5px, never a pill.
const _controlShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(WaveRadius.controls)),
);

ButtonThemeData _waveButtonTheme() {
  ButtonStyle control(ButtonStyle base) => base.copyWith(
        shape: const WidgetStatePropertyAll(_controlShape),
      );
  // Fluent exposes default/constructor styles; keep them rectangular.
  return ButtonThemeData(
    defaultButtonStyle: control(ButtonStyle()),
    filledButtonStyle: control(ButtonStyle()),
    outlinedButtonStyle: control(ButtonStyle()),
    iconButtonStyle: const ButtonStyle(
      shape: WidgetStatePropertyAll(_controlShape),
    ),
  );
}

ContentDialogThemeData _waveDialogTheme({required Color surface}) {
  // Touch dialogs share the floating-chrome radius (tab bar, mini-player,
  // sheets) so a dialog reads as part of the same family; desktop keeps the
  // 10px Fluent corner.
  final radius = Platform.isIOS ? WaveRadius.hero : WaveRadius.floating;
  return ContentDialogThemeData(
    decoration: BoxDecoration(
      color: surface,
      borderRadius: BorderRadius.circular(radius),
    ),
    actionsDecoration: BoxDecoration(
      color: surface,
      borderRadius: BorderRadius.vertical(
        bottom: Radius.circular(radius),
      ),
    ),
  );
}

const _waveTooltipTheme = TooltipThemeData(
  waitDuration: WaveState.tooltipDelay, // 400ms.
);

/// [custom] is the user's Custom theme palette
/// ([WaveSurfaces.fromCustomBase]). When set it replaces the graphite /
/// AMOLED / pearl surfaces; [isLight] must match
/// [WaveSurfaces.isLightBase] for its base so the text tokens contrast.
FluentThemeData buildWaveFluentTheme({
  required Color accent,
  required bool isLight,
  bool amoled = false,
  WaveSurfaces? custom,
}) {
  final safeAccent =
      accent.a == 0 ? WaveColors.defaultAccent : accent;
  final accentColor = _accentFrom(safeAccent);
  final buttonTheme = _waveButtonTheme();
  // AMOLED only ever collapses the *dark* base — light ignores it.
  final surfaces = custom ??
      ((!isLight && amoled) ? WaveSurfaces.amoled : WaveSurfaces.graphite);
  if (isLight) {
    final page = custom?.background ?? WaveColors.lightBackground;
    final card = custom?.surface ?? WaveColors.lightSurface;
    return FluentThemeData(
      brightness: Brightness.light,
      accentColor: accentColor,
      scaffoldBackgroundColor: page,
      micaBackgroundColor: page,
      cardColor: card,
      menuColor: custom?.surface ?? WaveColors.lightSurfaceRaised,
      activeColor: WaveColors.lightTextPrimary,
      inactiveColor: WaveColors.lightTextSecondary,
      selectionColor: safeAccent.withValues(alpha: 0.25),
      visualDensity: VisualDensity.standard,
      focusTheme: const FocusThemeData(
        glowFactor: 2.0,
      ),
      buttonTheme: buttonTheme,
      dialogTheme: _waveDialogTheme(surface: card),
      tooltipTheme: _waveTooltipTheme,
    );
  }
  return FluentThemeData(
    brightness: Brightness.dark,
    accentColor: accentColor,
    scaffoldBackgroundColor: surfaces.background,
    micaBackgroundColor: surfaces.background,
    acrylicBackgroundColor: surfaces.panelTranslucent,
    cardColor: surfaces.surface,
    menuColor: surfaces.surfaceRaised,
    activeColor: WaveColors.textPrimary,
    inactiveColor: WaveColors.textSecondary,
    selectionColor: safeAccent.withValues(alpha: 0.3),
    visualDensity: VisualDensity.standard,
    focusTheme: const FocusThemeData(
      glowFactor: 2.0,
    ),
    buttonTheme: buttonTheme,
    dialogTheme: _waveDialogTheme(surface: surfaces.surfaceRaised),
    tooltipTheme: _waveTooltipTheme,
  );
}
