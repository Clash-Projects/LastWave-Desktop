import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/prefs.dart';
import '../../ui/theme/tokens.dart';

/// App theme state (accent + Dark appearance + Haze preferences).
class ThemeState {
  final Color accent;
  final bool amoled;

  /// Retained for compatibility with existing UI consumers; Dark is the
  /// only available appearance, so this is always false.
  final bool isLight;

  /// The Custom theme is selected; surfaces come from [customBase].
  final bool isCustom;
  final Color customBase;
  final String hazeMaterial;
  final String hazeIntensity;
  final String accentSource;

  /// Whether the dock timeline uses the optional wave styling.
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
    this.wavySeekbar = false,
  });

  /// Legacy palette slot; Dark uses the graphite surface set.
  WaveSurfaces? get customSurfaces => null;

  /// Brightness of the two supported base themes.
  bool get effectiveLight => isLight;
}

class ThemeController extends StateNotifier<ThemeState> {
  final Prefs _prefs;

  /// iPad gets a neutral white accent by default. Explicitly saved accent
  /// choices are always respected, and iPhone keeps its existing default.
  static int _defaultAccent(Prefs prefs) {
    if (prefs.hasAccentColor) return prefs.accentColor;
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final views = WidgetsBinding.instance.platformDispatcher.views;
      final isIPad = views.any(
        (view) =>
            view.physicalSize.shortestSide / view.devicePixelRatio >= 600,
      );
      if (isIPad) return WaveColors.defaultAccent.toARGB32();
    }
    return prefs.accentColor;
  }
  ThemeController(this._prefs)
      : super(ThemeState(
          accent: Color(_defaultAccent(_prefs)),
          amoled: false,
          isLight: false,
          isCustom: false,
          customBase: Color(_prefs.customThemeBase),
          hazeMaterial: _prefs.hazeMaterial,
          hazeIntensity: _prefs.hazeIntensity,
          accentSource: _prefs.accentSource,
          wavySeekbar: _prefs.wavySeekbar,
        ));

  void refresh() {
    state = ThemeState(
      accent: Color(_defaultAccent(_prefs)),
      amoled: false,
      isLight: false,
      isCustom: false,
      customBase: Color(_prefs.customThemeBase),
      hazeMaterial: _prefs.hazeMaterial,
      hazeIntensity: _prefs.hazeIntensity,
      accentSource: _prefs.accentSource,
      wavySeekbar: _prefs.wavySeekbar,
    );
  }

  /// Dark is the only supported base appearance. Legacy light/custom
  /// preference values are ignored.
  Future<void> setThemeMode(String _) async {
    await _prefs.setThemeMode('dark');
    refresh();
  }
}

final themeControllerProvider =
    StateNotifierProvider<ThemeController, ThemeState>((ref) {
  return ThemeController(ref.watch(prefsProvider));
});
