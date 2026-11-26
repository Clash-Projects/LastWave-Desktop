import 'dart:math' as math;
import 'dart:ui';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/scheduler.dart';

import '../../ui/theme/tokens.dart';

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
      padding: const EdgeInsets.symmetric(horizontal: 4),
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
    return const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());
  }

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    // Horizontal carousels: no bar. Even a fading one drew a line across
    // the artwork row; wheel, trackpad and drag scroll them.
    if (details.direction == AxisDirection.left ||
        details.direction == AxisDirection.right) {
      return child;
    }
    return WaveThinScrollbar(controller: details.controller, child: child);
  }
}

/// Smooths wheel notches at the scroll position, after Flutter resolves the
/// event to the correct viewport. Works independently of scrollbar visibility.
class WaveScrollController extends ScrollController {
  WaveScrollController({
    super.initialScrollOffset,
    super.keepScrollOffset,
    super.debugLabel,
  });

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _WaveScrollPosition(
    physics: physics,
    context: context,
    initialPixels: initialScrollOffset,
    keepScrollOffset: keepScrollOffset,
    oldPosition: oldPosition,
    debugLabel: debugLabel,
  );
}

/// Keeps hover feedback local and avoids replaying it on every row that
/// passes under a stationary pointer during a scroll.
class WaveScrollHover extends StatefulWidget {
  const WaveScrollHover({super.key, required this.builder});

  final Widget Function(BuildContext context, bool hovered) builder;

  @override
  State<WaveScrollHover> createState() => _WaveScrollHoverState();
}

class _WaveScrollHoverState extends State<WaveScrollHover> {
  ValueNotifier<bool>? _scrolling;
  bool _inside = false;
  bool _hovered = false;

  bool get _showHover => _inside && !(_scrolling?.value ?? false);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scrolling = Scrollable.maybeOf(context)?.position.isScrollingNotifier;
    if (identical(scrolling, _scrolling)) return;
    _scrolling?.removeListener(_updateHover);
    _scrolling = scrolling;
    _scrolling?.addListener(_updateHover);
    _hovered = _showHover;
  }

  void _updateHover() {
    final hovered = _showHover;
    if (_hovered != hovered) setState(() => _hovered = hovered);
  }

  @override
  void dispose() {
    _scrolling?.removeListener(_updateHover);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        _inside = true;
        _updateHover();
      },
      onExit: (_) {
        _inside = false;
        _updateHover();
      },
      child: widget.builder(context, _hovered),
    );
  }
}

class _WaveScrollPosition extends ScrollPositionWithSingleContext {
  _WaveScrollPosition({
    required super.physics,
    required super.context,
    required super.initialPixels,
    required super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  @override
  void pointerScroll(double delta) {
    final viewport = context.notificationContext;
    // Precision-wheel deltas and inertia-cancel signals are handled directly.
    // Trackpad pan/zoom and touch drags use Flutter's separate drag activity.
    if (delta.abs() < 20 || (viewport != null && waveReduceMotion(viewport))) {
      super.pointerScroll(delta);
      return;
    }

    final target = (pixels + delta).clamp(minScrollExtent, maxScrollExtent);
    if (target == pixels) return;
    updateUserScrollDirection(
      delta > 0 ? ScrollDirection.reverse : ScrollDirection.forward,
    );
    final current = activity;
    if (current is _GlideActivity) {
      current.addDelta(delta);
    } else {
      beginActivity(_GlideActivity(this, target.toDouble()));
    }
  }
}

/// Moves the position toward its target each frame: a fixed fraction of the
/// remaining distance per unit time (time constant [_tau]), so speed
/// carries smoothly between notches and eases out at the end.
class _GlideActivity extends ScrollActivity {
  _GlideActivity(_WaveScrollPosition position, this._target) : super(position) {
    _ticker = position.context.vsync.createTicker(_tick)..start();
  }

  static const double _tau = 0.052; // seconds

  late final Ticker _ticker;
  double _target;
  Duration? _last;
  double _velocity = 0;

  ScrollPositionWithSingleContext get _position =>
      delegate as ScrollPositionWithSingleContext;

  double _clamp(double value) =>
      value.clamp(_position.minScrollExtent, _position.maxScrollExtent);

  void addDelta(double delta) {
    final pixels = _position.pixels;
    final reversing = (_target - pixels) * delta < 0;
    _target = _clamp((reversing ? pixels : _target) + delta);
  }

  void _tick(Duration elapsed) {
    final last = _last;
    final dt = last == null
        ? 1 / 120
        : ((elapsed - last).inMicroseconds / 1e6).clamp(0.0, 0.05);
    _last = elapsed;
    if (dt == 0) return;
    // Extents can change mid-glide (lazy lists growing).
    _target = _clamp(_target);
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
    _ticker.dispose();
    super.dispose();
  }
}
