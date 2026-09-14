import 'package:flutter/material.dart';

import 'observatory_theme.dart';

/// Back-compat shim — new code should import `observatory_theme.dart`
/// and `components.dart` directly.
ThemeData buildShadTheme({
  required Color accent,
  bool amoled = false,
}) =>
    ObservatoryTheme.dark(accent: accent, amoled: amoled);

/// Old name retained for call sites not yet migrated.
ThemeData buildMaterialTheme({
  required Color accent,
  bool amoled = false,
}) =>
    ObservatoryTheme.dark(accent: accent, amoled: amoled);
