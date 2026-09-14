import 'package:flutter/material.dart';

import 'tokens.dart';

/// Editorial Material themes — single primary component system.
///
/// Material is the app foundation; editorial primitives in
/// `components.dart` carry LastWave identity (flat ledger surfaces,
/// precise type, single accent). No second UI kit determines layout.
/// Native window material (Mica) is applied in `app/window.dart` via
/// flutter_acrylic/window_manager, not via a component library.
class ObservatoryTheme {
  ObservatoryTheme._();

  static ThemeData dark({required Color accent, bool amoled = false}) {
    final background = amoled ? Colors.black : LwColors.background;
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
      focusColor: accent.withValues(alpha: 0.22),
      hoverColor: Colors.white.withValues(alpha: 0.05),
      textTheme: const TextTheme(
        displayLarge: LwType.display,
        headlineMedium: LwType.headline,
        titleMedium: LwType.title,
        bodyMedium: LwType.body,
        bodySmall: LwType.caption,
        labelLarge: LwType.label,
        labelSmall: LwType.micro,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(
            Colors.white.withValues(alpha: 0.18)),
        thickness: const WidgetStatePropertyAll(8),
        radius: const Radius.circular(8),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: LwColors.surfaceOverlay,
          borderRadius: BorderRadius.circular(LwRadius.sm),
          border: Border.all(color: LwColors.outline),
        ),
        textStyle:
            LwType.caption.copyWith(color: LwColors.textPrimary),
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
      dialogTheme: const DialogThemeData(
        backgroundColor: LwColors.surfaceRaised,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
          side: BorderSide(color: LwColors.outline),
        ),
      ),
      dividerColor: LwColors.outlineSoft,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: LwColors.surfaceRaised,
        hintStyle:
            LwType.body.copyWith(color: LwColors.textTertiary),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(LwRadius.sm),
          borderSide: const BorderSide(color: LwColors.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(LwRadius.sm),
          borderSide: const BorderSide(color: LwColors.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(LwRadius.sm),
          borderSide: BorderSide(color: accent, width: 1.4),
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: accent,
        inactiveTrackColor: Colors.white.withValues(alpha: 0.12),
        thumbColor: Colors.white,
        overlayColor: accent.withValues(alpha: 0.18),
        trackHeight: 4,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? Colors.white : null),
        trackColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? accent : null),
      ),
    );
  }

  static ThemeData light({required Color accent}) {
    final scheme = ColorScheme.light(
      primary: const Color(0xFF1B6FA8),
      secondary: const Color(0xFF1B6FA8),
      surface: LwColors.lightSurface,
      error: LwColors.danger,
      onPrimary: Colors.white,
      onSurface: LwColors.lightTextPrimary,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: scheme.copyWith(primary: const Color(0xFF1B6FA8)),
      scaffoldBackgroundColor: LwColors.lightBackground,
      splashFactory: InkSparkle.splashFactory,
      focusColor: const Color(0xFF1B6FA8).withValues(alpha: 0.18),
      hoverColor: Colors.black.withValues(alpha: 0.04),
      textTheme: TextTheme(
        displayLarge: LwType.display
            .copyWith(color: LwColors.lightTextPrimary),
        headlineMedium: LwType.headline
            .copyWith(color: LwColors.lightTextPrimary),
        titleMedium:
            LwType.title.copyWith(color: LwColors.lightTextPrimary),
        bodyMedium:
            LwType.body.copyWith(color: LwColors.lightTextPrimary),
        bodySmall: LwType.caption
            .copyWith(color: LwColors.lightTextSecondary),
        labelLarge:
            LwType.label.copyWith(color: LwColors.lightTextPrimary),
        labelSmall: LwType.micro
            .copyWith(color: LwColors.lightTextTertiary),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: LwColors.lightTextPrimary,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(
            Colors.black.withValues(alpha: 0.22)),
        thickness: const WidgetStatePropertyAll(8),
        radius: const Radius.circular(8),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: LwColors.lightTextPrimary,
          borderRadius: BorderRadius.circular(LwRadius.sm),
        ),
        textStyle: LwType.caption.copyWith(color: Colors.white),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: LwColors.lightSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(LwRadius.md),
          side: const BorderSide(color: LwColors.lightOutline),
        ),
        textStyle: LwType.body
            .copyWith(color: LwColors.lightTextPrimary),
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: LwColors.lightSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
          side: BorderSide(color: LwColors.lightOutline),
        ),
      ),
      dividerColor: LwColors.lightOutlineSoft,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: LwColors.lightSurface,
        hintStyle: LwType.body
            .copyWith(color: LwColors.lightTextTertiary),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(LwRadius.sm),
          borderSide:
              const BorderSide(color: LwColors.lightOutline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(LwRadius.sm),
          borderSide:
              const BorderSide(color: LwColors.lightOutline),
        ),
        focusedBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
          borderSide:
              BorderSide(color: Color(0xFF1B6FA8), width: 1.4),
        ),
      ),
    );
  }
}

/// Pass-through scope retained for call-site compatibility.
/// Previously provided Fluent theming; editorial system is
/// Material-only so this simply returns [child].
class FluentScope extends StatelessWidget {
  final bool dark;
  final Color accent;
  final Widget child;
  const FluentScope({
    super.key,
    required this.dark,
    required this.accent,
    required this.child,
  });

  @override
  Widget build(BuildContext context) => child;
}

/// Back-compat shim: previous code imported `shad_theme.dart`.
ThemeData buildMaterialTheme({
  required Color accent,
  bool amoled = false,
}) =>
    ObservatoryTheme.dark(accent: accent, amoled: amoled);
