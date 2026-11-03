import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/ui/theme/tokens.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  group('WaveSurfaces.fromCustomBase', () {
    test('every random base keeps body text readable on every surface', () {
      final rnd = math.Random(3);
      for (var i = 0; i < 500; i++) {
        final base = Color(0xFF000000 | rnd.nextInt(0xFFFFFF));
        final s = WaveSurfaces.fromCustomBase(base);
        final light = WaveSurfaces.isLightBase(base);
        final text =
            light ? WaveColors.lightTextPrimary : WaveColors.textPrimary;
        final text2 =
            light ? WaveColors.lightTextSecondary : WaveColors.textSecondary;
        for (final surface in [
          s.background,
          s.surface,
          s.surfaceRaised,
          s.surfaceOverlay,
        ]) {
          expect(_contrast(text, surface), greaterThanOrEqualTo(7.0),
              reason: 'primary text on $surface from $base');
          expect(_contrast(text2, surface), greaterThanOrEqualTo(4.45),
              reason: 'secondary text on $surface from $base');
        }
        expect(s.isCustom, isTrue);
      }
    });

    test('dark ladder steps get lighter, light pages sit under their cards',
        () {
      final dark = WaveSurfaces.fromCustomBase(const Color(0xFF1A2A44));
      expect(dark.surface.computeLuminance(),
          greaterThan(dark.background.computeLuminance()));
      expect(dark.surfaceRaised.computeLuminance(),
          greaterThan(dark.surface.computeLuminance()));
      expect(dark.surfaceOverlay.computeLuminance(),
          greaterThan(dark.surfaceRaised.computeLuminance()));

      final light = WaveSurfaces.fromCustomBase(const Color(0xFFEFE7DA));
      expect(WaveSurfaces.isLightBase(const Color(0xFFEFE7DA)), isTrue);
      expect(light.surface.computeLuminance(),
          greaterThan(light.background.computeLuminance()));
      expect(light.surfaceOverlay.computeLuminance(),
          lessThan(light.background.computeLuminance()));
    });

    test('stock palettes are untouched', () {
      expect(WaveSurfaces.graphite.isCustom, isFalse);
      expect(WaveSurfaces.graphite.surfaceOverlay, WaveColors.surfaceOverlay);
      expect(WaveSurfaces.graphite.outlineSoft, WaveColors.outlineSoft);
      expect(WaveSurfaces.amoled.isCustom, isFalse);
    });
  });
}
