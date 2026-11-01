import 'dart:ui';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';

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
      radius: const Radius.circular(WaveRadius.tiny),
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
    // Mouse is a drag device (carousels), so inside a text field the
    // internal scrollable would grab the press and pan the text instead of
    // extending the selection. Caret/selection auto-scroll is programmatic
    // and unaffected by this.
    if (context.findAncestorWidgetOfExactType<EditableText>() != null) {
      return const NeverScrollableScrollPhysics();
    }
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
        radius: const Radius.circular(WaveRadius.tiny),
        fadeDuration: WaveMotion.fast,
        timeToFade: const Duration(milliseconds: 600),
        child: child,
      );
    } else {
      scrollbar = RawScrollbar(
        controller: details.controller,
        thumbVisibility: false,
        thickness: 6,
        radius: const Radius.circular(WaveRadius.tiny),
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
/// target scroll offsets smoothly over time (160ms easeOutCubic)
/// via a high-refresh-rate [Ticker] instead of discrete single-frame pixel jumps.
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
    this.duration = const Duration(milliseconds: 160),
    this.curve = Curves.easeOutCubic,
  });

  @override
  State<WaveSmoothScroll> createState() => _WaveSmoothScrollState();
}

class _WaveSmoothScrollState extends State<WaveSmoothScroll>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  double? _targetPixels;
  double _startPixels = 0.0;
  Duration _animationStart = Duration.zero;
  Duration _lastTickElapsed = Duration.zero;
  ScrollPosition? _activePosition;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    _lastTickElapsed = elapsed;
    final position = _activePosition;
    if (position == null || !position.hasPixels || _targetPixels == null) {
      _stopGliding();
      return;
    }

    final totalDurationMs = widget.duration.inMilliseconds.toDouble();
    if (totalDurationMs <= 0) {
      position.jumpTo(_targetPixels!);
      _stopGliding();
      return;
    }

    final progressMs =
        (elapsed - _animationStart).inMicroseconds / 1000.0;
    final t = (progressMs / totalDurationMs).clamp(0.0, 1.0);
    final curveValue = widget.curve.transform(t);

    final currentPixels =
        _startPixels + (_targetPixels! - _startPixels) * curveValue;
    final clamped = currentPixels.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    position.jumpTo(clamped);

    if (t >= 1.0 || (clamped - _targetPixels!).abs() < 0.25) {
      position.jumpTo(_targetPixels!);
      _stopGliding();
    }
  }

  void _stopGliding() {
    if (_ticker.isActive) {
      _ticker.stop();
    }
    _targetPixels = null;
    _activePosition = null;
    _animationStart = Duration.zero;
    _lastTickElapsed = Duration.zero;
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;

    final isVertical = widget.direction == AxisDirection.down ||
        widget.direction == AxisDirection.up;
    final delta = isVertical ? event.scrollDelta.dy : event.scrollDelta.dx;
    if (delta == 0) return;

    // Distinguish physical notched mouse wheel from trackpad:
    // Physical mouse wheel events on Windows/desktop have event.kind == PointerDeviceKind.mouse
    // and discrete delta magnitude >= 20.0 (typically 40, 100, or 120 per notch).
    // Trackpads emit continuous micro-deltas or PointerDeviceKind.trackpad.
    final isNotchedMouseWheel =
        event.kind == PointerDeviceKind.mouse && delta.abs() >= 20.0;
    if (!isNotchedMouseWheel) {
      // Trackpads use standard fluid platform handling
      return;
    }

    // Only claim the wheel when THIS scrollable can actually move in the
    // wheel's direction. Registering unconditionally let a non-scrollable
    // (or shrink-wrapped / edge-pinned) inner list swallow the event, so the
    // page scrollable behind it never saw it. Unclaimed events fall through
    // to the next scrollable up the hit-test chain.
    final controller = widget.controller;
    if (controller == null || controller.positions.length != 1) return;
    final position = controller.position;
    if (!position.hasPixels) return;
    final atStart = position.pixels <= position.minScrollExtent;
    final atEnd = position.pixels >= position.maxScrollExtent;
    if (position.maxScrollExtent <= position.minScrollExtent) return;
    if ((delta < 0 && atStart) || (delta > 0 && atEnd)) {
      if (_targetPixels == null) return;
    }

    // Register with pointerSignalResolver so Flutter's default stepped pointerScroll does NOT fire
    GestureBinding.instance.pointerSignalResolver.register(event, (resolved) {
      if (!mounted) return;
      final scrollEvent = resolved as PointerScrollEvent;
      final d =
          isVertical ? scrollEvent.scrollDelta.dy : scrollEvent.scrollDelta.dx;
      if (d == 0) return;

      final current = position.pixels;
      final min = position.minScrollExtent;
      final max = position.maxScrollExtent;

      // Accumulate target offset so fast consecutive spins glide continuously
      final base = (_targetPixels != null) ? _targetPixels! : current;
      final newTarget = (base + d).clamp(min, max);

      _activePosition = position;
      _startPixels = current;
      _targetPixels = newTarget;

      if (!_ticker.isActive) {
        _animationStart = Duration.zero;
        _lastTickElapsed = Duration.zero;
        _ticker.start();
      } else {
        // Reset animation start point from current position to target
        _animationStart = _lastTickElapsed;
      }
    });
  }

  void _onPointerDown(PointerDownEvent _) {
    // Immediately cancel wheel interpolation if user touches/clicks/drags
    _stopGliding();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: _onPointerSignal,
      onPointerDown: _onPointerDown,
      child: widget.child,
    );
  }
}
