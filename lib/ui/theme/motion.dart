import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';

import 'tokens.dart';

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
  static const _window = Duration(milliseconds: 220);

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
    // Reduce motion: the whole point of this widget is the movement, so
    // there is no "instant" version to fall back to — hand the child over.
    if (waveReduceMotion(context)) return widget.child;
    // The scope stays for the group's whole life. Dropping it once the
    // timeline finished looked like a saving, but a descendant that rebuilds
    // afterwards — a rail row on expand/collapse, a table on sort, a row whose
    // like just flipped — then fell back to the standalone entrance and
    // replayed its fade, so the content blinked back in. A completed group
    // already hands plain children back (`_groupDriven` short-circuits), so
    // keeping the scope costs one inherited lookup and nothing else.
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
class WaveEntrance extends StatefulWidget {
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
  static const stepMs = 20;

  /// One item's fade/rise duration.
  static const itemMs = 180;

  /// Items past this index share the last stagger slot (grouped).
  static const maxStagger = 6;

  /// Standalone mode animates only the first few rows (lazy-list safety).
  static const _standaloneCap = 6;

  @override
  State<WaveEntrance> createState() => _WaveEntranceState();
}

class _WaveEntranceState extends State<WaveEntrance>
    with SingleTickerProviderStateMixin {
  /// Decided once, on first build, and kept for this element's life: the
  /// wrapper structure never changes, so the child is never remounted.
  /// (It used to swap between `child`, `Opacity(child)` and
  /// `Opacity(Transform(child))` as the fade began and ended, tearing down
  /// and rebuilding every entering row twice — images re-requested, state
  /// reset — which is what made pages stutter as they opened.)
  CurvedAnimation? _t;
  AnimationController? _own;
  bool _decided = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_decided) return;
    _decided = true;
    final w = widget;
    if (waveReduceMotion(context)) return;
    final group = w.local ? null : _WaveEntranceScope.of(context);
    if (group != null) {
      // A finished cascade hands rows built later back untouched.
      if (group.isCompleted || group.value >= 1.0) return;
      final totalMs = group.duration?.inMilliseconds ?? 220;
      final slot = math.min(w.index, WaveEntrance.maxStagger);
      final startMs =
          math.min(slot * WaveEntrance.stepMs, totalMs - WaveEntrance.itemMs - 20);
      final begin = (startMs / totalMs).clamp(0.0, 0.97);
      final end =
          ((startMs + WaveEntrance.itemMs) / totalMs).clamp(begin + 0.01, 1.0);
      _t = CurvedAnimation(
        parent: group,
        curve: Interval(begin, end, curve: Curves.easeOutCubic),
      );
      return;
    }
    if (w.index >= WaveEntrance._standaloneCap) return;
    // Bake the stagger delay into an Interval curve: one controller, no timers.
    final delayMs = w.index * WaveEntrance.stepMs;
    final totalMs = delayMs + WaveEntrance.itemMs;
    _own = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: totalMs),
    )..forward();
    _t = CurvedAnimation(
      parent: _own!,
      curve: Interval(delayMs / totalMs, 1, curve: Curves.easeOutCubic),
    );
  }

  @override
  void dispose() {
    _t?.dispose(); // drops its status listener on a shared group
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    if (t == null) return widget.child;
    final rise = widget.rise;
    // At rest this is Opacity(1) + a zero translation: both paint the child
    // directly (no layer), so the settled cost is nil.
    return AnimatedBuilder(
      animation: t,
      child: widget.child,
      builder: (context, child) {
        final v = t.value.clamp(0.0, 1.0);
        return Opacity(
          opacity: v,
          child: Transform.translate(
            offset: Offset(0, rise * (1 - v)),
            child: child,
          ),
        );
      },
    );
  }
}
