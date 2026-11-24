import 'dart:math' as math;
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
      padding: const EdgeInsets.only(right: 4),
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
    // Horizontal carousels: no bar. Even a fading one drew a line across
    // the artwork row; wheel, trackpad and drag scroll them.
    if (details.direction == AxisDirection.left ||
        details.direction == AxisDirection.right) {
      scrollbar = child;
    } else {
      scrollbar = RawScrollbar(
        controller: details.controller,
        thumbVisibility: false,
        thickness: 6,
        padding: const EdgeInsets.only(right: 4),
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

/// Desktop mouse-wheel smoothing that feels native.
///
/// Each wheel notch moves a target; one [_GlideActivity] chases it every
/// frame with exponential easing. Notches that arrive mid-glide just move
/// the target, so a fast spin is one continuous motion. The previous
/// version restarted a 200ms ease-out per notch, dropping to zero speed at
/// every notch: the surge-and-stall that read as jitter. The activity also
/// reports its real velocity, so image providers defer decoding while the
/// list moves fast instead of hitching mid-scroll.
class WaveSmoothScroll extends StatefulWidget {
  final Widget child;
  final ScrollController? controller;
  final AxisDirection direction;

  const WaveSmoothScroll({
    super.key,
    required this.child,
    this.controller,
    this.direction = AxisDirection.down,
  });

  @override
  State<WaveSmoothScroll> createState() => _WaveSmoothScrollState();
}

class _WaveSmoothScrollState extends State<WaveSmoothScroll>
    with TickerProviderStateMixin {
  /// The running glide, if any. Kept here because
  /// [ScrollPosition.activity] is protected; the activity flags itself
  /// [_GlideActivity.done] once the position replaces or drops it.
  _GlideActivity? _glide;

  bool get _gliding => _glide != null && !_glide!.done;
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final isVertical = widget.direction == AxisDirection.down ||
        widget.direction == AxisDirection.up;
    final delta = isVertical ? event.scrollDelta.dy : event.scrollDelta.dx;
    if (delta == 0) return;

    // Notched mouse wheel only (|delta| >= 20 per notch on Windows);
    // trackpads already deliver fine-grained deltas.
    if (event.kind != PointerDeviceKind.mouse || delta.abs() < 20.0) return;

    // Claim the wheel only when THIS scrollable can move that way, so an
    // edge-pinned inner list lets the page behind it scroll.
    final controller = widget.controller;
    if (controller == null || controller.positions.length != 1) return;
    final position = controller.position;
    if (position is! ScrollPositionWithSingleContext || !position.hasPixels) {
      return;
    }
    if (position.maxScrollExtent <= position.minScrollExtent) return;
    final gliding = _gliding;
    final atStart = position.pixels <= position.minScrollExtent;
    final atEnd = position.pixels >= position.maxScrollExtent;
    if (!gliding && ((delta < 0 && atStart) || (delta > 0 && atEnd))) return;

    GestureBinding.instance.pointerSignalResolver.register(event, (resolved) {
      if (!mounted) return;
      final e = resolved as PointerScrollEvent;
      final d = isVertical ? e.scrollDelta.dy : e.scrollDelta.dx;
      if (d == 0) return;
      final current = _glide;
      if (_gliding && identical(current!.position, position)) {
        current.retarget(current.target + d);
      } else {
        final glide = _GlideActivity(position, this, position.pixels + d);
        _glide = glide;
        position.beginActivity(glide);
      }
    });
  }

  void _onPointerDown(PointerDownEvent _) {
    // A click or drag stops the glide where it is.
    final controller = widget.controller;
    if (controller == null || controller.positions.length != 1) return;
    final position = controller.position;
    if (_gliding && position is ScrollPositionWithSingleContext) {
      position.goIdle();
    }
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

/// Moves the position toward [target] each frame: a fixed fraction of the
/// remaining distance per unit time (time constant [_tau]), so speed
/// carries smoothly between notches and eases out at the end.
class _GlideActivity extends ScrollActivity {
  _GlideActivity(this._position, TickerProvider vsync, double target)
      : _target = _clamp(_position, target),
        super(_position) {
    _ticker = vsync.createTicker(_tick)..start();
  }

  static const double _tau = 0.085; // seconds

  final ScrollPositionWithSingleContext _position;
  late final Ticker _ticker;
  double _target;
  Duration _last = Duration.zero;
  double _velocity = 0;

  double get target => _target;
  ScrollPosition get position => _position;

  /// Set when the position replaced or dropped this activity.
  bool done = false;

  static double _clamp(ScrollPosition p, double v) =>
      v.clamp(p.minScrollExtent, p.maxScrollExtent).toDouble();

  void retarget(double target) => _target = _clamp(_position, target);

  void _tick(Duration elapsed) {
    final dt = ((elapsed - _last).inMicroseconds / 1e6).clamp(0.0, 0.05);
    _last = elapsed;
    if (dt == 0) return;
    // Extents can change mid-glide (lazy lists growing).
    _target = _clamp(_position, _target);
    final from = _position.pixels;
    final remaining = _target - from;
    if (remaining.abs() < 0.5) {
      _position.setPixels(_target);
      _velocity = 0;
      delegate.goIdle();
      return;
    }
    final step = remaining * (1 - math.exp(-dt / _tau));
    _velocity = step / dt;
    if (_position.setPixels(from + step) != 0) {
      // Hit an edge: stop instead of fighting the boundary.
      _velocity = 0;
      delegate.goIdle();
    }
  }

  @override
  bool get shouldIgnorePointer => false;

  @override
  bool get isScrolling => true;

  @override
  double get velocity => _velocity;

  @override
  void dispose() {
    done = true;
    _ticker.dispose();
    super.dispose();
  }
}
