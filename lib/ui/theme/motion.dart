import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';

import 'tokens.dart';

/// The dock and Now Playing use the same handoff when the track changes.
/// Only the current track can receive focus, taps, or accessibility actions.
/// Give [child] a key that identifies the track.
class WaveTrackSwap extends StatelessWidget {
  const WaveTrackSwap({super.key, required this.child});

  final Widget child;

  static Widget _transition(Widget child, Animation<double> animation) {
    return FadeTransition(
      opacity: animation,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.08),
          end: Offset.zero,
        ).animate(animation),
        transformHitTests: false,
        child: child,
      ),
    );
  }

  static Widget _layer(Widget child, {required bool current}) {
    return ExcludeFocus(
      key: child.key,
      excluding: !current,
      child: IgnorePointer(
        ignoring: !current,
        child: ExcludeSemantics(excluding: !current, child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final reduced = waveReduceMotion(context);
    return AnimatedSwitcher(
      duration: reduced ? Duration.zero : WaveMotion.normal,
      reverseDuration: reduced ? Duration.zero : WaveMotion.fast,
      switchInCurve: WaveMotion.standard,
      switchOutCurve: WaveMotion.standard.flipped,
      transitionBuilder: _transition,
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.center,
        children: [
          if (!reduced && previous.isNotEmpty)
            _layer(previous.last, current: false),
          if (current != null) _layer(current, current: true),
        ],
      ),
      child: child,
    );
  }
}

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
  static const _window = Duration(
    milliseconds:
        WaveEntrance.maxStagger * WaveEntrance.stepMs + WaveEntrance.itemMs,
  );

  late final AnimationController _controller;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _window);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (waveReduceMotion(context) && _started) _controller.value = 1;
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
    if (waveReduceMotion(context)) {
      _controller.value = 1;
    } else {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
    this.rise = 8,
    this.local = false,
    required this.child,
  });

  /// Per-item stagger step.
  static const stepMs = 25;

  /// One item's fade/rise duration.
  static const itemMs = 160;

  /// Items past this index share the last stagger slot (grouped).
  static const maxStagger = 4;

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
      final totalMs = group.duration!.inMilliseconds;
      final slot = w.index.clamp(0, WaveEntrance.maxStagger);
      final startMs = slot * WaveEntrance.stepMs;
      _t = CurvedAnimation(
        parent: group,
        curve: Interval(
          startMs / totalMs,
          (startMs + WaveEntrance.itemMs) / totalMs,
          curve: WaveMotion.standard,
        ),
      );
      return;
    }
    if (w.index >= WaveEntrance._standaloneCap) return;
    // Bake the stagger delay into an Interval curve: one controller, no timers.
    final delayMs = math.max(w.index, 0) * WaveEntrance.stepMs;
    final totalMs = delayMs + WaveEntrance.itemMs;
    _own = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: totalMs),
    )..forward();
    _t = CurvedAnimation(
      parent: _own!,
      curve: Interval(delayMs / totalMs, 1, curve: WaveMotion.standard),
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
    final reduced = waveReduceMotion(context);
    final rise = widget.rise;
    // At rest this is Opacity(1) + a zero translation: both paint the child
    // directly (no layer), so the settled cost is nil.
    return AnimatedBuilder(
      animation: t,
      child: widget.child,
      builder: (context, child) {
        final v = reduced ? 1.0 : t.value.clamp(0.0, 1.0);
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
