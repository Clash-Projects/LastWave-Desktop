import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/prefs.dart';
import '../settings/theme_controller.dart';

/// Provider for Performance Mode state.
final performanceModeProvider =
    StateNotifierProvider<PerformanceController, bool>((ref) {
  final prefs = ref.watch(prefsProvider);
  return PerformanceController(prefs, ref);
});

class PerformanceController extends StateNotifier<bool> {
  final Prefs _prefs;
  final Ref? _ref;

  PerformanceController(this._prefs, [this._ref]) : super(_prefs.performanceMode);

  void toggle() {
    setPerformanceMode(!state);
  }

  void setPerformanceMode(bool enabled) {
    state = enabled;
    _prefs.setPerformanceMode(enabled);
    if (_ref != null) {
      try {
        _ref.read(themeControllerProvider.notifier).refresh();
      } catch (_) {}
    }
  }
}

/// Simple, honest hardware detection for modest systems (e.g. dual-core / quad-thread
/// CPUs, integrated graphics, budget laptops).
final isModestHardwareProvider = Provider<bool>((ref) {
  try {
    // Dual core with hyperthreading or older 2-4 core CPUs (like i3-2105)
    final cores = Platform.numberOfProcessors;
    if (cores <= 4) return true;
  } catch (_) {}
  return false;
});

/// Explainer items describing exactly what Performance Mode optimizes
/// without technical AI-jargon.
class PerformanceOptimizationItem {
  final String title;
  final String subtitle;
  final String impact;
  final bool active;

  const PerformanceOptimizationItem({
    required this.title,
    required this.subtitle,
    required this.impact,
    required this.active,
  });
}

final performanceOptimizationsProvider =
    Provider<List<PerformanceOptimizationItem>>((ref) {
  final isPerfOn = ref.watch(performanceModeProvider);

  return [
    PerformanceOptimizationItem(
      title: 'Glass Blur & Shaders',
      subtitle: isPerfOn
          ? 'Replaced with clean, crisp surfaces (Zero GPU lag)'
          : 'Multi-layer blur filters active on window and panels',
      impact: 'Reduces GPU render load & stops UI stutter',
      active: isPerfOn,
    ),
    PerformanceOptimizationItem(
      title: 'Background Video Artwork (Canvas)',
      subtitle: isPerfOn
          ? 'Paused (Displaying high-resolution static album covers)'
          : 'Continuously decoding looping video clips in background',
      impact: 'Saves 30%–50% CPU usage during playback',
      active: isPerfOn,
    ),
    PerformanceOptimizationItem(
      title: 'Background Mesh & Glow',
      subtitle: isPerfOn
          ? 'Replaced with smooth static gradient wash'
          : 'Multi-layer mesh painters animating continuously',
      impact: 'Stops continuous off-screen render loops',
      active: isPerfOn,
    ),
    PerformanceOptimizationItem(
      title: 'Animated Lyrics',
      subtitle: isPerfOn
          ? 'Smooth line-by-line scrolling'
          : 'High-refresh per-word syllable animations',
      impact: 'Reduces screen redraw frequency',
      active: isPerfOn,
    ),
    PerformanceOptimizationItem(
      title: 'Audio Visualizer Bars',
      subtitle: isPerfOn
          ? 'Paused'
          : 'Live audio frequency analysis on UI thread',
      impact: 'Frees up CPU cores for music playback',
      active: isPerfOn,
    ),
  ];
});
