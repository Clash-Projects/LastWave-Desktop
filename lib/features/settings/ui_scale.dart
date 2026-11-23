import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/prefs.dart';

/// Available interface zoom presets.
class UiScalePresets {
  static const double min = 0.75;
  static const double max = 1.50;
  static const double step = 0.10;
  static const double standard = 1.0;

  static const List<double> values = [
    0.75,
    0.80,
    0.90,
    1.00,
    1.10,
    1.25,
    1.50,
  ];

  static String label(double scale) {
    final pct = (scale * 100).round();
    if ((scale - standard).abs() < 0.001) return '$pct% (Standard)';
    return '$pct%';
  }
}

class UiScaleNotifier extends StateNotifier<double> {
  final Prefs _prefs;

  UiScaleNotifier(this._prefs) : super(_clampScale(_prefs.uiScale));

  static double _clampScale(double val) {
    if (val < UiScalePresets.min) return UiScalePresets.min;
    if (val > UiScalePresets.max) return UiScalePresets.max;
    return (val * 100).round() / 100.0;
  }

  Future<void> setScale(double newScale) async {
    final clamped = _clampScale(newScale);
    if ((state - clamped).abs() < 0.001) return;
    state = clamped;
    await _prefs.setUiScale(clamped);
  }

  Future<void> zoomIn() async {
    for (final v in UiScalePresets.values) {
      if (v - state > 0.001) {
        await setScale(v);
        return;
      }
    }
    await setScale(UiScalePresets.values.last);
  }

  Future<void> zoomOut() async {
    for (final v in UiScalePresets.values.reversed) {
      if (state - v > 0.001) {
        await setScale(v);
        return;
      }
    }
    await setScale(UiScalePresets.values.first);
  }

  Future<void> reset() async {
    await setScale(UiScalePresets.standard);
  }
}

final uiScaleProvider = StateNotifierProvider<UiScaleNotifier, double>((ref) {
  final prefs = ref.watch(prefsProvider);
  return UiScaleNotifier(prefs);
});
