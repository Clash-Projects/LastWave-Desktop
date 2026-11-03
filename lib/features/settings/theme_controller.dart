import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/prefs.dart';
import '../../ui/theme/tokens.dart';

/// App theme state (accent + AMOLED + pearl/midnight/custom mode + Haze
/// prefs).
class ThemeState {
  final Color accent;
  final bool amoled;

  /// Pearl is selected. False for Midnight and for Custom (see
  /// [effectiveLight] for the brightness actually rendered).
  final bool isLight;

  /// The Custom theme is selected; surfaces come from [customBase].
  final bool isCustom;
  final Color customBase;
  final String hazeMaterial;
  final String hazeIntensity;
  final String accentSource;

  /// Experimental: panels sit further off the surface — thinner fill, wider
  /// blur. Threaded into [WaveHazeScope], so every WaveHaze / WaveGlass
  /// follows the switch without reading prefs itself.
  final bool liquidGlass;

  /// Experimental: the dock timeline is drawn as a wave instead of a bar.
  final bool wavySeekbar;

  const ThemeState({
    required this.accent,
    required this.amoled,
    this.isLight = false,
    this.isCustom = false,
    this.customBase = const Color(0xFF1A2A44),
    this.hazeMaterial = 'automatic',
    this.hazeIntensity = 'medium',
    this.accentSource = 'custom',
    this.liquidGlass = false,
    this.wavySeekbar = false,
  });

  /// The palette for the Custom theme, or null for Midnight / Pearl.
  WaveSurfaces? get customSurfaces =>
      isCustom ? WaveSurfaces.fromCustomBase(customBase) : null;

  /// Brightness actually rendered: Pearl, or a Custom theme on a light
  /// base.
  bool get effectiveLight =>
      isLight || (isCustom && WaveSurfaces.isLightBase(customBase));
}

class ThemeController extends StateNotifier<ThemeState> {
  final Prefs _prefs;
  ThemeController(this._prefs)
      : super(ThemeState(
          accent: Color(_prefs.accentColor),
          amoled: _prefs.amoled,
          isLight: _prefs.isLight,
          isCustom: _prefs.isCustomTheme,
          customBase: Color(_prefs.customThemeBase),
          hazeMaterial: _prefs.hazeMaterial,
          hazeIntensity: _prefs.hazeIntensity,
          accentSource: _prefs.accentSource,
          liquidGlass: _prefs.liquidGlass,
          wavySeekbar: _prefs.wavySeekbar,
        ));

  void refresh() {
    state = ThemeState(
      accent: Color(_prefs.accentColor),
      amoled: _prefs.amoled,
      isLight: _prefs.isLight,
      isCustom: _prefs.isCustomTheme,
      customBase: Color(_prefs.customThemeBase),
      hazeMaterial: _prefs.hazeMaterial,
      hazeIntensity: _prefs.hazeIntensity,
      accentSource: _prefs.accentSource,
      liquidGlass: _prefs.liquidGlass,
      wavySeekbar: _prefs.wavySeekbar,
    );
  }

  /// 'dark' (Midnight), 'light' (Pearl) or 'custom'.
  Future<void> setThemeMode(String mode) async {
    await _prefs.setThemeMode(mode);
    refresh();
  }

  /// Picks the Custom theme's base colour and switches to it.
  Future<void> setCustomBase(Color base) async {
    await _prefs.setCustomThemeBase(base.withValues(alpha: 1).toARGB32());
    await _prefs.setThemeMode('custom');
    refresh();
  }
}

final themeControllerProvider =
    StateNotifierProvider<ThemeController, ThemeState>((ref) {
  return ThemeController(ref.watch(prefsProvider));
});
