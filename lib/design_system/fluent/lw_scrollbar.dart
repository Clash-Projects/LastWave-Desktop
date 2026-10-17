import 'dart:ui';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/gestures.dart';

import '../../../ui/theme/tokens.dart';

/// ONE reusable Fluent scrollbar treatment.
///
/// - thin (6px idle, 8px hover), unobtrusive, fades when idle
/// - larger hit area than visible thumb (Fluent handles this)
/// - no huge track, no browser appearance
/// - vertical only for page regions; horizontal carousels hide bars and
///   rely on wheel/trackpad/drag + subtle edge affordance
/// - reserves space so durations/actions/lyrics never sit underneath
class WaveThinScrollbar extends StatelessWidget {
  final Widget child;
  final ScrollController? controller;
  final bool thumbVisible;
  const WaveThinScrollbar({
    super.key,
    required this.child,
    this.controller,
    this.thumbVisible = false,
  });

  @override
  Widget build(BuildContext context) {
    return RawScrollbar(
      controller: controller,
      thumbVisibility: thumbVisible,
      thickness: 6,
      radius: const Radius.circular(3),
      minThumbLength: 40,
      fadeDuration: WaveMotion.normal,
      timeToFade: const Duration(milliseconds: 800),
      pressDuration: Duration.zero,
      child: child,
    );
  }
}

/// Global scroll behaviour: thin Fluent bars, smooth inertia scroll physics,
/// and support for mouse and trackpad dragging. Horizontal strips scroll via wheel/
/// trackpad/drag; the bar only appears while interacting.
class WaveScrollBehavior extends FluentScrollBehavior {
  const WaveScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
      };

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    return const BouncingScrollPhysics(
      parent: AlwaysScrollableScrollPhysics(),
    );
  }

  @override
  Widget buildScrollbar(
      BuildContext context, Widget child, ScrollableDetails details) {
    Widget scrollbar;
    // Horizontal carousels: deliberate scroll, no permanent bar.
    if (details.direction == AxisDirection.left ||
        details.direction == AxisDirection.right) {
      scrollbar = RawScrollbar(
        controller: details.controller,
        thumbVisibility: false,
        thickness: 4,
        radius: const Radius.circular(2),
        fadeDuration: WaveMotion.fast,
        timeToFade: const Duration(milliseconds: 600),
        child: child,
      );
    } else {
      scrollbar = RawScrollbar(
        controller: details.controller,
        thumbVisibility: false,
        thickness: 6,
        radius: const Radius.circular(3),
        minThumbLength: 40,
        fadeDuration: WaveMotion.normal,
        timeToFade: const Duration(milliseconds: 800),
        child: child,
      );
    }
    return WaveSmoothScroll(
      controller: details.controller,
      direction: details.direction,
      child: scrollbar,
    );
  }
}

/// Intercepts desktop mouse wheel [PointerScrollEvent]s to interpolate
/// target scroll offsets smoothly over time (180ms easeOutCubic)
/// instead of discrete single-frame pixel jumps.
class WaveSmoothScroll extends StatefulWidget {
  final Widget child;
  final ScrollController? controller;
  final AxisDirection direction;
  final Duration duration;
  final Curve curve;

  const WaveSmoothScroll({
    super.key,
    required this.child,
    this.controller,
    this.direction = AxisDirection.down,
    this.duration = const Duration(milliseconds: 180),
    this.curve = Curves.easeOutCubic,
  });

  @override
  State<WaveSmoothScroll> createState() => _WaveSmoothScrollState();
}

class _WaveSmoothScrollState extends State<WaveSmoothScroll> {
  double? _targetOffset;

  ScrollPosition? _resolvePosition() {
    if (widget.controller?.hasClients == true) {
      return widget.controller!.position;
    }
    final primary = PrimaryScrollController.maybeOf(context);
    if (primary?.hasClients == true) {
      return primary!.position;
    }
    return null;
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;

    final isVertical = widget.direction == AxisDirection.down ||
        widget.direction == AxisDirection.up;
    final delta = isVertical ? event.scrollDelta.dy : event.scrollDelta.dx;
    if (delta == 0) return;

    final position = _resolvePosition();
    if (position == null || !position.hasPixels) return;

    GestureBinding.instance.pointerSignalResolver.register(event, (resolved) {
      if (!mounted) return;
      final scrollEvent = resolved as PointerScrollEvent;
      final d = isVertical ? scrollEvent.scrollDelta.dy : scrollEvent.scrollDelta.dx;
      if (d == 0) return;

      final current = position.pixels;
      final base = (_targetOffset != null && (_targetOffset! - current).abs() < 800)
          ? _targetOffset!
          : current;

      final min = position.minScrollExtent;
      final max = position.maxScrollExtent;
      final newTarget = (base + d).clamp(min, max);
      _targetOffset = newTarget;

      position.animateTo(
        newTarget,
        duration: widget.duration,
        curve: widget.curve,
      ).whenComplete(() {
        if (_targetOffset == newTarget) {
          _targetOffset = null;
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: _onPointerSignal,
      child: widget.child,
    );
  }
}
