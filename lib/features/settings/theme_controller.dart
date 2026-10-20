import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/prefs.dart';

/// App theme state (accent + AMOLED + pearl/midnight mode + Haze prefs).
class ThemeState {
  final Color accent;
  final bool amoled;
  final bool isLight;
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
    this.hazeMaterial = 'automatic',
    this.hazeIntensity = 'medium',
    this.accentSource = 'custom',
    this.liquidGlass = false,
    this.wavySeekbar = false,
  });
}

class ThemeController extends StateNotifier<ThemeState> {
  final Prefs _prefs;
  ThemeController(this._prefs)
      : super(ThemeState(
          accent: Color(_prefs.accentColor),
          amoled: _prefs.amoled,
          isLight: _prefs.isLight,
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
      hazeMaterial: _prefs.hazeMaterial,
      hazeIntensity: _prefs.hazeIntensity,
      accentSource: _prefs.accentSource,
      liquidGlass: _prefs.liquidGlass,
      wavySeekbar: _prefs.wavySeekbar,
    );
  }

  Future<void> setThemeMode(bool light) async {
    await _prefs.setThemeMode(light ? 'light' : 'dark');
    refresh();
  }
}

final themeControllerProvider =
    StateNotifierProvider<ThemeController, ThemeState>((ref) {
  return ThemeController(ref.watch(prefsProvider));
});
