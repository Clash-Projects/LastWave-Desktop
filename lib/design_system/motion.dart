import 'package:flutter/widgets.dart';
import 'package:flutter_animate/flutter_animate.dart';

import 'tokens.dart';

/// Shared motion presets (flutter_animate). All transitions stay in
/// the 120–300 ms band; no bounce/spring gimmicks.
extension LwMotionPresets on Animate {
  /// Lists, rails and page content entrance.
  Animate fadeSlideIn({int delayMs = 0}) => fadeIn(
        duration: LwMotion.normal,
        delay: Duration(milliseconds: delayMs),
        curve: LwMotion.standard,
      ).slideY(
        begin: 0.06,
        end: 0,
        duration: LwMotion.normal,
        delay: Duration(milliseconds: delayMs),
        curve: LwMotion.standard,
      );

  /// Cards and tiles entrance with stagger support.
  Animate cardIn({int delayMs = 0}) => fadeIn(
        duration: LwMotion.fast,
        delay: Duration(milliseconds: delayMs),
        curve: LwMotion.standard,
      ).scale(
        begin: const Offset(0.97, 0.97),
        end: const Offset(1, 1),
        duration: LwMotion.fast,
        delay: Duration(milliseconds: delayMs),
        curve: LwMotion.standard,
      );

  /// Skeleton shimmer loop.
  Animate shimmerLoop() => shimmer(
        duration: const Duration(milliseconds: 1400),
        curve: LwMotion.emphasized,
      ).animate(onComplete: (c) => c.repeat());
}

/// Stagger delay helper for grid/rail entrances (capped).
Duration staggerFor(int index, {int stepMs = 24, int maxMs = 240}) =>
    Duration(
        milliseconds:
            (index * stepMs).clamp(0, maxMs));
