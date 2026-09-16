import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';

/// WinUI 3 motion layer — staggered "Entrance" choreography.
///
/// Mirrors the WinUI `EntranceThemeTransition`: content fades in while
/// drifting upward a short distance, with a small per-item stagger so
/// sections cascade instead of popping as one slab.
///
/// Recycling safety: [WaveEntranceGroup] owns ONE controller started when
/// the content mounts (typically when async data first arrives). Every
/// [WaveEntrance] maps its index onto an interval of that single
/// timeline, so lazily-built list/grid rows that mount AFTER the timeline
/// finished render fully visible — no fade-replay when scrolling back up
/// in virtualized lists ([SuperSliverList], [SliverGrid], …).
///
/// Usage:
/// ```dart
/// WaveEntranceGroup(
///   child: CustomScrollView(slivers: [
///     SliverToBoxAdapter(child: WaveEntrance(index: 0, child: header)),
///     SliverGrid(... WaveEntrance(index: i, child: card) ...),
///   ]),
/// )
/// ```
class WaveEntranceGroup extends StatefulWidget {
  final Widget child;

  /// Set false while data loads and flip to true when content is ready —
  /// the timeline starts on the first `true` and never restarts.
  final bool start;

  const WaveEntranceGroup({
    super.key,
    required this.child,
    this.start = true,
  });

  @override
  State<WaveEntranceGroup> createState() => _WaveEntranceGroupState();
}

class _WaveEntranceGroupState extends State<WaveEntranceGroup>
    with SingleTickerProviderStateMixin {
  /// Total window: must exceed max stagger + item duration.
  static const _window = Duration(milliseconds: 1000);

  late final AnimationController _controller;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _window);
    if (widget.start) _go();
  }

  @override
  void didUpdateWidget(WaveEntranceGroup oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.start) _go();
  }

  void _go() {
    if (_started) return;
    _started = true;
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _WaveEntranceScope(
      controller: _controller,
      child: widget.child,
    );
  }
}

class _WaveEntranceScope extends InheritedWidget {
  final AnimationController controller;
  const _WaveEntranceScope({required this.controller, required super.child});

  static AnimationController? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_WaveEntranceScope>()
      ?.controller;

  @override
  bool updateShouldNotify(_WaveEntranceScope oldWidget) =>
      oldWidget.controller != controller;
}

/// Staggered fade + rise entrance for one child.
///
/// - Inside a [WaveEntranceGroup]: driven by the shared timeline
///   (recycle-safe for virtualized lists).
/// - Standalone (no group): animates once on mount, but only for
///   [index] < [_standaloneCap] so deep rows in lazy lists never replay.
class WaveEntrance extends StatelessWidget {
  final int index;
  final Widget child;

  /// Rise distance in logical pixels (WinUI entrance drift).
  final double rise;

  /// When true, always run a local one-shot entrance even inside a
  /// [WaveEntranceGroup] — for content that must animate at page mount
  /// instead of waiting for the group's start gate (e.g. page headers).
  final bool local;

  const WaveEntrance({
    super.key,
    this.index = 0,
    this.rise = 14,
    this.local = false,
    required this.child,
  });

  /// Per-item stagger step.
  static const stepMs = 40;

  /// One item's fade/rise duration.
  static const itemMs = 340;

  /// Items past this index share the last stagger slot (grouped).
  static const maxStagger = 14;

  /// Standalone mode animates only the first few rows (lazy-list safety).
  static const _standaloneCap = 6;

  @override
  Widget build(BuildContext context) {
    final group = local ? null : _WaveEntranceScope.of(context);
    if (group != null) return _groupDriven(group);
    if (index >= _standaloneCap) return child;
    return _standalone();
  }

  Widget _groupDriven(AnimationController controller) {
    final totalMs = controller.duration?.inMilliseconds ?? 1000;
    final slot = math.min(index, maxStagger);
    final startMs = math.min(slot * stepMs, totalMs - itemMs - 40);
    final begin = (startMs / totalMs).clamp(0.0, 0.97);
    final end = ((startMs + itemMs) / totalMs).clamp(begin + 0.01, 1.0);
    final curved = CurvedAnimation(
      parent: controller,
      curve: Interval(begin, end, curve: Curves.easeOutCubic),
    );
    return AnimatedBuilder(
      animation: controller,
      child: child,
      builder: (context, child) => _paint(curved.value, child!),
    );
  }

  Widget _standalone() {
    // Bake the stagger delay into an Interval curve so the one-shot
    // TweenAnimationBuilder needs no timers or extra controllers.
    final delayMs = index * stepMs;
    final totalMs = delayMs + itemMs;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: totalMs),
      curve: Interval(
        delayMs / totalMs,
        1,
        curve: Curves.easeOutCubic,
      ),
      child: child,
      builder: (context, value, child) => _paint(value, child!),
    );
  }

  Widget _paint(double t, Widget child) {
    return Opacity(
      opacity: t,
      child: Transform.translate(
        offset: Offset(0, rise * (1 - t)),
        child: child,
      ),
    );
  }
}
