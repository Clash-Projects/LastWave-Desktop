import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/ui/components/ambient.dart';
import 'package:lastwave_desktop/ui/components/glass_stage.dart';
import 'package:lastwave_desktop/ui/theme/tokens.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  // Worst cases: neon, white, black and saturated primaries from covers.
  const covers = [
    Color(0xFFFFFF00),
    Color(0xFFFFFFFF),
    Color(0xFF000000),
    Color(0xFF00FF66),
    Color(0xFFFF0040),
    Color(0xFF2040FF),
  ];

  test('glass gradient keeps body text at WCAG AA in dark themes', () {
    for (final c in covers) {
      final bg = glassTone(c, WaveColors.background, false);
      expect(_contrast(WaveColors.textSecondary, bg), greaterThan(4.5),
          reason: '$c');
    }
  });

  test('glass gradient keeps body text at WCAG AA in Pearl', () {
    for (final c in covers) {
      final bg = glassTone(c, WaveColors.lightBackground, true);
      expect(_contrast(WaveColors.lightTextSecondary, bg), greaterThan(4.5),
          reason: '$c');
    }
  });

  test('cover wash dims pale covers enough for primary text', () {
    for (final c in covers) {
      final p = ArtworkPalette(
        primary: c, vibrant: c, darkMuted: c, lightVibrant: c, cream: c, shadow: c);
      final dim = glassDim(p);
      // Brightest part of the wash: the cover's lightest tone, dimmed,
      // under the 6% shade at the top (veil and vignette only darken).
      final lum = c.computeLuminance() * dim * 0.94;
      final contrast = (WaveColors.textPrimary.computeLuminance() + 0.05) /
          (lum + 0.05);
      expect(contrast, greaterThan(4.5), reason: '$c dim=$dim');
    }
  });
}
