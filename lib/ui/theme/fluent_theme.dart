import 'package:fluent_ui/fluent_ui.dart';

import 'tokens.dart';

/// Single Fluent component system factory.
///
/// - Dark: charcoal smoked surfaces over native Mica (set in app/window.dart).
/// - Light: pearl surfaces.
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
  return ContentDialogThemeData(
    decoration: BoxDecoration(
      color: surface,
      borderRadius:
          BorderRadius.circular(WaveRadius.floating), // 10px max.
    ),
    actionsDecoration: BoxDecoration(
      color: surface,
      borderRadius: const BorderRadius.vertical(
        bottom: Radius.circular(WaveRadius.floating),
      ),
    ),
  );
}

const _waveTooltipTheme = TooltipThemeData(
  waitDuration: WaveState.tooltipDelay, // 400ms.
);

FluentThemeData buildWaveFluentTheme({
  required Color accent,
  required bool isLight,
}) {
  final safeAccent =
      accent.a == 0 ? WaveColors.defaultAccent : accent;
  final accentColor = _accentFrom(safeAccent);
  final buttonTheme = _waveButtonTheme();
  if (isLight) {
    return FluentThemeData(
      brightness: Brightness.light,
      accentColor: accentColor,
      scaffoldBackgroundColor: WaveColors.lightBackground,
      micaBackgroundColor: WaveColors.lightBackground,
      cardColor: WaveColors.lightSurface,
      menuColor: WaveColors.lightSurface,
      activeColor: WaveColors.lightTextPrimary,
      inactiveColor: WaveColors.lightTextSecondary,
      selectionColor: safeAccent.withValues(alpha: 0.25),
      visualDensity: VisualDensity.standard,
      focusTheme: const FocusThemeData(
        glowFactor: 2.0,
      ),
      buttonTheme: buttonTheme,
      dialogTheme:
          _waveDialogTheme(surface: WaveColors.lightSurface),
      tooltipTheme: _waveTooltipTheme,
    );
  }
  return FluentThemeData(
    brightness: Brightness.dark,
    accentColor: accentColor,
    scaffoldBackgroundColor: WaveColors.background,
    micaBackgroundColor: WaveColors.background,
    acrylicBackgroundColor: WaveColors.panelTranslucent,
    cardColor: WaveColors.surface,
    menuColor: WaveColors.surfaceRaised,
    activeColor: WaveColors.textPrimary,
    inactiveColor: WaveColors.textSecondary,
    selectionColor: safeAccent.withValues(alpha: 0.3),
    visualDensity: VisualDensity.standard,
    focusTheme: const FocusThemeData(
      glowFactor: 2.0,
    ),
    buttonTheme: buttonTheme,
    dialogTheme: _waveDialogTheme(surface: WaveColors.surfaceRaised),
    tooltipTheme: _waveTooltipTheme,
  );
}
