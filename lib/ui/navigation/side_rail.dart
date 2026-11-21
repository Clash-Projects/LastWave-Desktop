import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';

import '../components/buttons.dart' show LWTooltip;
import '../theme/haze.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import 'destinations.dart';

/// Compact secondary navigation — MUSIC stays primary.
///
/// - 200px expanded / 60px collapsed rail
/// - small 36px rows, no giant rounded rectangles
/// - selected = subtle wash + 3px accent bar, nothing loud
/// - bottom: Friends / Settings pinned, history hidden
class WaveSideRail extends StatefulWidget {
  final bool expanded;
  final String active;
  final void Function(String) onGo;
  const WaveSideRail({
    super.key,
    required this.expanded,
    required this.active,
    required this.onGo,
  });
  @override
  State<WaveSideRail> createState() => _WaveSideRailState();
}

class _WaveSideRailState extends State<WaveSideRail> {
  bool get expanded => widget.expanded;
  String get active => widget.active;
  void Function(String) get onGo => widget.onGo;

  /// Row cache: per navigation only the two rows whose selection flips
  /// miss (old + new active); the other ~10 rows — entrance wrapper,
  /// tooltips, semantics, hover regions included — are reused verbatim
  /// instead of reconstructed. Cleared on expand/collapse (every row
  /// changes shape); bounded at 4 instances per destination max.
  final Map<String, Widget> _rowCache = {};

  @override
  void didUpdateWidget(covariant WaveSideRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expanded != widget.expanded) _rowCache.clear();
  }

  Widget _row(WaveDestination destination, int index, {double rise = 6}) {
    final selected = active == destination.path;
    return _rowCache.putIfAbsent(
      '${destination.path}|$expanded|$selected',
      () => WaveEntrance(
        index: index,
        rise: rise,
        child: _RailItem(
          destination: destination,
          expanded: expanded,
          selected: selected,
          onTap: () => onGo(destination.path),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final width =
        expanded ? WaveDensity.railExpanded : WaveDensity.railCollapsed;
    // Haze Level 1 — subtle tonal navigation material, never a solid slab.
    // The expanded 200px drawer floats over the page (content only reserves
    // the 60px collapsed strip), so it has to frost what it covers; the
    // collapsed strip has the shell behind it and blurring it would buy
    // nothing. Haze=Solid still short-circuits the filter upstream.
    //
    // Expanded it wears the lyrics drawer's frost verbatim — L2's 20px blur
    // under a 40% tint (60% in light themes, matching that panel's fill)
    // instead of L1's 88% fill. At 88% the drawer read as an opaque slab
    // parked next to a translucent panel that covers the same page.
    // Fully opaque in both states: the expanded rail is just the collapsed
    // strip grown wider, and the page sits beside it, never under it.
    return WaveHaze(
      level: LwHazeLevel.l1,
      enableBlur: false,
      fillAlpha: 1.0,
      // Glass keeps the palette's own see-through fill.
      base: waveGlassOn(context)
          ? waveRailTranslucent(context)
          : waveRailTranslucent(context).withValues(alpha: 1.0),
      border: Border(
        right: BorderSide(color: waveDivider(context)),
      ),
      child: AnimatedContainer(
        duration: waveMotion(context, WaveMotion.normal),
        curve: WaveMotion.standard,
        width: width,
      // The rail persists across navigation, so this group's timeline
      // runs exactly once — a startup cascade for the destinations.
      child: WaveEntranceGroup(
        child: Column(
        children: [
          const SizedBox(height: 6),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              children: [
                // One-shot startup cascade — standalone entrances run once
                // on mount; in-place rebuilds (selection/hover) never replay.
                for (var i = 0; i < waveListenDestinations.length; i++)
                  _row(waveListenDestinations[i], i),
                WaveEntrance(
                  index: waveListenDestinations.length,
                  rise: 4,
                  child: const _RailSeparator(),
                ),
                for (var i = 0; i < waveCollectionDestinations.length; i++)
                  _row(
                    waveCollectionDestinations[i],
                    waveListenDestinations.length + i,
                  ),
                WaveEntrance(
                  index: waveListenDestinations.length +
                      waveCollectionDestinations.length,
                  rise: 4,
                  child: const _RailSeparator(),
                ),
                for (var i = 0; i < waveOfflineDestinations.length; i++)
                  _row(
                    waveOfflineDestinations[i],
                    waveListenDestinations.length +
                        waveCollectionDestinations.length +
                        i,
                  ),
              ],
            ),
          ),
          Container(
            height: 1,
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: waveDivider(context),
          ),
          for (var i = 0; i < waveSystemDestinations.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: _row(
                waveSystemDestinations[i],
                waveListenDestinations.length +
                    waveCollectionDestinations.length +
                    waveOfflineDestinations.length +
                    i,
              ),
            ),
          const SizedBox(height: 8),
        ],
      ),
      ),
      ),
    );
  }
}

class _RailSeparator extends StatelessWidget {
  const _RailSeparator();
  @override
  Widget build(BuildContext context) {
    // Same inset line in both states: no width jump when toggling.
    return Container(
      height: 1,
      margin: const EdgeInsets.symmetric(vertical: 7, horizontal: 10),
      color: waveDivider(context),
    );
  }
}

class _RailItem extends StatefulWidget {
  final WaveDestination destination;
  final bool expanded;
  final bool selected;
  final VoidCallback onTap;
  const _RailItem({
    required this.destination,
    required this.expanded,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_RailItem> createState() => _RailItemState();
}

/// Inner width of a row in the collapsed rail (60 - 2*6 padding - 2*1
/// border): the icon sits centred in it in both states.
const double _iconBox = 46;

/// Label room in the expanded rail (200 - 12 - 2 - [_iconBox]).
const double _labelWidth = 140;

class _RailItemState extends State<_RailItem> {
  bool _hover = false;
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);
    final bg = widget.selected
        ? (dark ? Colors.white : Colors.black).withValues(alpha: 0.08)
        : _hover
            ? (dark ? Colors.white : Colors.black).withValues(alpha: 0.04)
            : Colors.transparent;
    final fg = widget.selected
        ? (dark ? WaveColors.textPrimary : WaveColors.lightTextPrimary)
        : (dark ? WaveColors.textSecondary : WaveColors.lightTextSecondary);
    final hasFocus = _focus.hasFocus;
    const itemHeight = 40.0;

    final content = Focus(
      focusNode: _focus,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.numpadEnter ||
                event.logicalKey == LogicalKeyboardKey.space)) {
          widget.onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      onFocusChange: (_) => setState(() {}),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: () {
            _focus.requestFocus();
            widget.onTap();
          },
          child: AnimatedContainer(
            duration: waveMotion(context, WaveMotion.fast),
            height: itemHeight,
            margin: const EdgeInsets.symmetric(vertical: 1.5),
            padding: EdgeInsets.zero,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: WaveRadius.controlsRadius,
              border: hasFocus
                  ? Border.all(
                      color: accent.withValues(alpha: 0.6), width: 1)
                  : Border.all(color: Colors.transparent, width: 1),
            ),
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                AnimatedPositioned(
                  duration: waveMotion(context, WaveMotion.fast),
                  curve: Curves.easeOutCubic,
                  left: widget.selected ? 0 : -4,
                  top: (itemHeight - 16) / 2,
                  height: 16,
                  child: AnimatedOpacity(
                    duration: waveMotion(context, WaveMotion.fast),
                    opacity: widget.selected ? 1.0 : 0.0,
                    child: Container(
                      width: 3,
                      decoration: BoxDecoration(
                        color: accent,
                        borderRadius: WaveRadius.tinyRadius,
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      // The icon keeps one size and x position in both
                      // states; only the label fades in with the
                      // animating rail width, so nothing snaps mid-flight.
                      final reveal =
                          ((constraints.maxWidth - _iconBox) / 90)
                              .clamp(0.0, 1.0);
                      return Row(
                        children: [
                          SizedBox(
                            width: _iconBox,
                            child: Center(
                              child: AnimatedScale(
                                scale: widget.selected
                                    ? 1.06
                                    : (_hover ? 1.03 : 1.0),
                                duration:
                                    waveMotion(context, WaveMotion.fast),
                                curve: Curves.easeOutCubic,
                                child: Icon(
                                  widget.destination.icon,
                                  size: 18,
                                  color: widget.selected ? accent : fg,
                                ),
                              ),
                            ),
                          ),
                          if (reveal > 0)
                            Expanded(
                              child: ClipRect(
                                // Laid out once at the full label width
                                // and clipped, not re-ellipsized per frame.
                                child: OverflowBox(
                                  alignment: Alignment.centerLeft,
                                  minWidth: 0,
                                  maxWidth: _labelWidth,
                                  child: Opacity(
                                    opacity: reveal,
                                    child: Text(
                                      widget.destination.label,
                                      maxLines: 1,
                                      softWrap: false,
                                      overflow: TextOverflow.ellipsis,
                                      style: WaveType.label.copyWith(
                                        fontSize: 13,
                                        fontWeight: widget.selected
                                            ? FontWeight.w600
                                            : FontWeight.w400,
                                        color: fg,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final labelled = Semantics(
      button: true,
      selected: widget.selected,
      label: widget.destination.label,
      onTap: widget.onTap,
      excludeSemantics: true,
      child: content,
    );
    if (widget.expanded) return labelled;
    return LWTooltip(
      message: widget.destination.label,
      child: labelled,
    );
  }
}
