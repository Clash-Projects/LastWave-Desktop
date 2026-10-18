import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/ui/theme/tokens.dart';

/// Neutral-ladder invariants for the graphite / pearl palettes.
///
/// These are the properties the UI depends on but nothing else asserts:
/// text tiers stay legible on every surface they are painted over, and the
/// surface ladder keeps its direction (the meta tier once sat at 2.9:1 and
/// the AMOLED glass sat *lighter* than its own base).
double _luminance(Color color) {
  double channel(double c) =>
      c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  final a = color.toARGB32();
  return 0.2126 * channel(((a >> 16) & 0xFF) / 255) +
      0.7152 * channel(((a >> 8) & 0xFF) / 255) +
      0.0722 * channel((a & 0xFF) / 255);
}

double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('dark text ladder', () {
    const surfaces = {
      'background': WaveColors.background,
      'surface': WaveColors.surface,
      'raised': WaveColors.surfaceRaised,
      'overlay': WaveColors.surfaceOverlay,
      'AMOLED surface': WaveColors.amoledSurface,
    };

    test('every tier clears its floor on every surface', () {
      for (final entry in surfaces.entries) {
        expect(
          _contrast(WaveColors.textPrimary, entry.value),
          greaterThan(7.0),
          reason: 'primary on ${entry.key}',
        );
        expect(
          _contrast(WaveColors.textSecondary, entry.value),
          greaterThan(4.5),
          reason: 'secondary on ${entry.key}',
        );
        expect(
          _contrast(WaveColors.textTertiary, entry.value),
          greaterThan(4.0),
          reason: 'meta tier on ${entry.key}',
        );
      }
    });

    test('tiers stay ordered primary > secondary > meta', () {
      for (final entry in surfaces.entries) {
        final primary = _contrast(WaveColors.textPrimary, entry.value);
        final secondary =
            _contrast(WaveColors.textSecondary, entry.value);
        final meta = _contrast(WaveColors.textTertiary, entry.value);
        expect(primary, greaterThan(secondary), reason: entry.key);
        expect(secondary, greaterThan(meta), reason: entry.key);
      }
    });
  });

  group('light text ladder', () {
    const surfaces = {
      'background': WaveColors.lightBackground,
      'content': WaveColors.lightContent,
      'surface': WaveColors.lightSurface,
      'overlay': WaveColors.lightOverlay,
    };

    test('every tier clears its floor on every surface', () {
      for (final entry in surfaces.entries) {
        expect(
          _contrast(WaveColors.lightTextPrimary, entry.value),
          greaterThan(7.0),
          reason: 'primary on ${entry.key}',
        );
        expect(
          _contrast(WaveColors.lightTextSecondary, entry.value),
          greaterThan(4.5),
          reason: 'secondary on ${entry.key}',
        );
        expect(
          _contrast(WaveColors.lightTextTertiary, entry.value),
          greaterThan(4.0),
          reason: 'meta tier on ${entry.key}',
        );
      }
    });
  });

  group('surface ladders', () {
    test('graphite and AMOLED both step up monotonically', () {
      for (final ladder in [
        (
          'graphite',
          [WaveColors.background, WaveColors.surface, WaveColors.surfaceRaised],
        ),
        (
          'AMOLED',
          [
            WaveColors.amoledBackground,
            WaveColors.amoledSurface,
            WaveColors.amoledSurfaceRaised,
          ],
        ),
      ]) {
        final (name, steps) = ladder;
        for (var i = 1; i < steps.length; i++) {
          expect(
            _luminance(steps[i]),
            greaterThan(_luminance(steps[i - 1])),
            reason: '$name step $i',
          );
        }
      }
    });

    test('AMOLED only ever collapses the dark base', () {
      expect(
        _luminance(WaveColors.amoledBackground),
        lessThan(_luminance(WaveColors.background)),
      );
      expect(
        _luminance(WaveColors.amoledSurface),
        lessThan(_luminance(WaveColors.surface)),
      );
      // Text tokens are shared, so contrast only improves on black.
      expect(
        _contrast(WaveColors.textPrimary, WaveColors.amoledBackground),
        greaterThan(_contrast(WaveColors.textPrimary, WaveColors.background)),
      );
    });
  });
}
