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

  /// The Artwork theme is selected; surfaces follow the playing cover
  /// (resolved outside this state, see `artworkSurfacesProvider`).
  final bool isArtwork;
  final String hazeMaterial;
  final String hazeIntensity;
  final String accentSource;

  /// Experimental: panels sit further off the surface — thinner fill, wider
  /// blur. Threaded into [WaveHazeScope], so every WaveHaze / WaveGlass
  /// follows the switch without reading prefs itself.
  final bool liquidGlass;

  /// Experimental: the dock timeline is drawn as a wave instead of a bar.
  final bool wavySeekbar;

  /// Glassmorphism: every surface goes translucent over an app-wide
  /// artwork aura (see `WaveGlassStage`). Works with every theme mode.
  final bool glass;

  /// App font id (see `appFonts`); '' = Windows default.
  final String font;

  const ThemeState({
    required this.accent,
    required this.amoled,
    this.isLight = false,
    this.isCustom = false,
    this.customBase = const Color(0xFF1A2A44),
    this.isArtwork = false,
    this.hazeMaterial = 'automatic',
    this.hazeIntensity = 'medium',
    this.accentSource = 'custom',
    this.liquidGlass = false,
    this.wavySeekbar = false,
    this.glass = false,
    this.font = '',
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
          isArtwork: _prefs.isArtworkTheme,
          hazeMaterial: _prefs.hazeMaterial,
          hazeIntensity: _prefs.hazeIntensity,
          accentSource: _prefs.accentSource,
          liquidGlass: _prefs.liquidGlass,
          wavySeekbar: _prefs.wavySeekbar,
          glass: _prefs.glassmorphism,
          font: _prefs.appFont,
        ));

  void refresh() {
    state = ThemeState(
      accent: Color(_prefs.accentColor),
      amoled: _prefs.amoled,
      isLight: _prefs.isLight,
      isCustom: _prefs.isCustomTheme,
      customBase: Color(_prefs.customThemeBase),
      isArtwork: _prefs.isArtworkTheme,
      hazeMaterial: _prefs.hazeMaterial,
      hazeIntensity: _prefs.hazeIntensity,
      accentSource: _prefs.accentSource,
      liquidGlass: _prefs.liquidGlass,
      wavySeekbar: _prefs.wavySeekbar,
      glass: _prefs.glassmorphism,
      font: _prefs.appFont,
    );
  }

  /// 'dark' (Midnight), 'light' (Pearl), 'custom' or 'artwork'.
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
