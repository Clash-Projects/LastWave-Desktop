import 'package:flutter/material.dart';

import 'tokens.dart';

/// LastWave desktop theme: dark-first, dense, accent-driven.
ThemeData buildLastWaveTheme({
  required Color accent,
  bool amoled = false,
}) {
  final background =
      amoled ? Colors.black : LwColors.background;
  final scheme = ColorScheme.dark(
    primary: accent,
    secondary: accent.withValues(alpha: 0.85),
    surface: LwColors.surface,
    error: LwColors.danger,
    onPrimary: Colors.white,
    onSurface: LwColors.textPrimary,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: background,
    splashFactory: InkSparkle.splashFactory,
    textTheme: const TextTheme(
      displayLarge: LwType.display,
      headlineMedium: LwType.headline,
      titleMedium: LwType.title,
      bodyMedium: LwType.body,
      bodySmall: LwType.caption,
      labelLarge: LwType.label,
      labelSmall: LwType.micro,
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor:
          WidgetStatePropertyAll(Colors.white.withValues(alpha: 0.18)),
      thickness: const WidgetStatePropertyAll(8),
      radius: const Radius.circular(8),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: LwColors.surfaceOverlay,
        borderRadius: BorderRadius.circular(LwRadius.sm),
        border: Border.all(color: LwColors.outline),
      ),
      textStyle: LwType.caption
          .copyWith(color: LwColors.textPrimary),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: LwColors.surfaceRaised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LwRadius.md),
        side: const BorderSide(color: LwColors.outline),
      ),
      textStyle:
          LwType.body.copyWith(color: LwColors.textPrimary),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: LwColors.surfaceRaised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LwRadius.lg),
        side: const BorderSide(color: LwColors.outline),
      ),
    ),
    dividerColor: LwColors.outlineSoft,
    sliderTheme: SliderThemeData(
      activeTrackColor: accent,
      inactiveTrackColor: Colors.white.withValues(alpha: 0.14),
      thumbColor: Colors.white,
      overlayColor: accent.withValues(alpha: 0.15),
      trackHeight: 3,
      thumbShape:
          const RoundSliderThumbShape(enabledThumbRadius: 6),
    ),
  );
}
