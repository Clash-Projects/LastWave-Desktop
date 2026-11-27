import 'dart:async';
import 'package:fluent_ui/fluent_ui.dart';

import '../theme/tokens.dart';

/// Branch container for the shell's `StatefulShellRoute`.
///
/// go_router's default `IndexedStack` container keeps every branch mounted —
/// tab scroll offset and page state survive a destination change — but swaps
/// the visible branch with no motion at all, so the side rail cut between
/// pages. This container keeps that exact keep-alive contract and layers the
/// app's motion language on top: content dissolves between branches over
/// [WaveMotion.slow]. The rail, title bar and dock stay in place.
///
/// Each branch keeps one stable wrapper shape (ignore · offstage · ticker ·
/// fade) so an index change only flips *properties*, never widget types.
/// Changing a wrapper's type would deactivate and rebuild that branch, which
/// is the state loss this container exists to prevent.
///
/// Branches that are neither incoming nor outgoing are `Offstage` and
/// ticker-muted — the same treatment the queue and lyrics drawers get — so a
/// hidden page neither paints nor animates in the background.
///
/// Honours the OS reduce-motion switch (`MediaQuery.disableAnimations`):
/// the switch then applies instantly.
class WaveBranchSwitcher extends StatefulWidget {
  const WaveBranchSwitcher({
    super.key,
    required this.currentIndex,
    required this.children,
  });

  /// Active branch index (`StatefulNavigationShell.currentIndex`).
  final int currentIndex;

  /// Branch navigator widgets, one per `StatefulShellBranch`.
  final List<Widget> children;

  @override
  State<WaveBranchSwitcher> createState() => _WaveBranchSwitcherState();
}

class _WaveBranchSwitcherState extends State<WaveBranchSwitcher>
    with SingleTickerProviderStateMixin {
  /// 0 → the incoming branch is fully transparent, 1 → settled.
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: WaveMotion.slow,
    value: 1,
  );

  /// The opacity each visible branch had when the current switch began.
  Map<int, double> _startingOpacities = const {};

  /// Updated with MediaQuery so widget changes can honour the OS switch.
  bool _reducedMotion = false;

  /// Inactivity timers for non-home branches.
  final Map<int, Timer> _inactivityTimers = {};

  /// Set of branches currently evicted due to prolonged inactivity (> 45s).
  final Set<int> _evicted = <int>{};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = waveReduceMotion(context);
    if (_reducedMotion) {
      _startingOpacities = const {};
      _fade.value = 1;
    }
  }

  double _opacity(int branch, int current) {
    final progress = WaveMotion.move.transform(_fade.value);
    final start = _startingOpacities[branch] ?? 0;
    return branch == current
        ? start + (1 - start) * progress
        : start * (1 - progress);
  }

  @override
  void didUpdateWidget(covariant WaveBranchSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex == widget.currentIndex) return;

    // Reactivate incoming branch if previously evicted
    _inactivityTimers[widget.currentIndex]?.cancel();
    _inactivityTimers.remove(widget.currentIndex);
    _evicted.remove(widget.currentIndex);

    // Schedule eviction for departed non-home branch after 45s
    final departed = oldWidget.currentIndex;
    if (departed > 0) {
      _inactivityTimers[departed]?.cancel();
      _inactivityTimers[departed] = Timer(const Duration(seconds: 45), () {
        if (!mounted) return;
        if (widget.currentIndex != departed) {
          setState(() {
            _evicted.add(departed);
          });
        }
      });
    }

    if (_reducedMotion) return;
    // A second selection continues from the visible blend instead of
    // bringing the barely visible departing tab back to full opacity.
    final opacities = <int, double>{};
    for (final i in {..._startingOpacities.keys, departed}) {
      final opacity = _opacity(i, departed);
      if (opacity > 0) opacities[i] = opacity;
    }
    _startingOpacities = opacities;
    _fade.forward(from: 0).whenComplete(() {
      if (mounted) setState(() => _startingOpacities = const {});
    });
  }

  @override
  void dispose() {
    for (final timer in _inactivityTimers.values) {
      timer.cancel();
    }
    _inactivityTimers.clear();
    _fade.dispose();
    super.dispose();
  }

  Widget _branch(int i) {
    final active = i == widget.currentIndex;
    final visible = active || _startingOpacities.containsKey(i);
    final isEvicted = _evicted.contains(i) && !visible;
    return ExcludeFocus(
      excluding: !active,
      child: IgnorePointer(
        ignoring: !active,
        child: Offstage(
          offstage: !visible,
          child: TickerMode(
            enabled: active,
            child: ExcludeSemantics(
              excluding: !active,
              child: AnimatedBuilder(
                animation: visible ? _fade : const AlwaysStoppedAnimation(0),
                child: isEvicted ? const SizedBox.shrink() : widget.children[i],
                builder: (context, child) => Opacity(
                  opacity: _opacity(i, widget.currentIndex),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        for (var i = 0; i < widget.children.length; i++) _branch(i),
      ],
    );
  }
}
