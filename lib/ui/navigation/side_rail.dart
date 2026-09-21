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
class WaveSideRail extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final width =
        expanded ? WaveDensity.railExpanded : WaveDensity.railCollapsed;
    // Haze Level 1 — subtle tonal navigation material, never a solid slab.
    return WaveHaze(
      level: LwHazeLevel.l1,
      base: dark
          ? WaveColors.railTranslucent
          : WaveColors.lightNavBackground.withValues(alpha: 0.92),
      border: Border(
        right: BorderSide(color: waveDivider(context)),
      ),
      child: AnimatedContainer(
        duration: WaveMotion.normal,
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
                  WaveEntrance(
                    index: i,
                    rise: 6,
                    child: _RailItem(
                      destination: waveListenDestinations[i],
                      expanded: expanded,
                      selected: active == waveListenDestinations[i].path,
                      onTap: () =>
                          onGo(waveListenDestinations[i].path),
                    ),
                  ),
                WaveEntrance(
                  index: waveListenDestinations.length,
                  rise: 4,
                  child: _RailSeparator(expanded: expanded),
                ),
                for (var i = 0; i < waveCollectionDestinations.length; i++)
                  WaveEntrance(
                    index: waveListenDestinations.length + i,
                    rise: 6,
                    child: _RailItem(
                      destination: waveCollectionDestinations[i],
                      expanded: expanded,
                      selected:
                          active == waveCollectionDestinations[i].path,
                      onTap: () =>
                          onGo(waveCollectionDestinations[i].path),
                    ),
                  ),
                WaveEntrance(
                  index: waveListenDestinations.length +
                      waveCollectionDestinations.length,
                  rise: 4,
                  child: _RailSeparator(expanded: expanded),
                ),
                for (var i = 0; i < waveOfflineDestinations.length; i++)
                  WaveEntrance(
                    index: waveListenDestinations.length +
                        waveCollectionDestinations.length +
                        i,
                    rise: 6,
                    child: _RailItem(
                      destination: waveOfflineDestinations[i],
                      expanded: expanded,
                      selected: active == waveOfflineDestinations[i].path,
                      onTap: () =>
                          onGo(waveOfflineDestinations[i].path),
                    ),
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
              child: WaveEntrance(
                index: waveListenDestinations.length +
                    waveCollectionDestinations.length +
                    waveOfflineDestinations.length +
                    i,
                rise: 6,
                child: _RailItem(
                  destination: waveSystemDestinations[i],
                  expanded: expanded,
                  selected: active == waveSystemDestinations[i].path,
                  onTap: () => onGo(waveSystemDestinations[i].path),
                ),
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
  final bool expanded;
  const _RailSeparator({required this.expanded});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Center(
        child: Container(
          width: expanded ? double.infinity : 20,
          height: 1,
          margin: expanded
              ? const EdgeInsets.symmetric(horizontal: 10)
              : EdgeInsets.zero,
          color: waveDivider(context),
        ),
      ),
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
    final itemHeight = widget.expanded ? 36.0 : 46.0;

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
            duration: WaveMotion.fast,
            height: itemHeight,
            margin: const EdgeInsets.symmetric(vertical: 1.5),
            padding: EdgeInsets.zero,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(4),
              border: hasFocus
                  ? Border.all(
                      color: accent.withValues(alpha: 0.6), width: 1)
                  : Border.all(color: Colors.transparent, width: 1),
            ),
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                AnimatedPositioned(
                  duration: WaveMotion.fast,
                  curve: Curves.easeOutCubic,
                  left: widget.selected ? 0 : -4,
                  top: (itemHeight - 16) / 2,
                  height: 16,
                  child: AnimatedOpacity(
                    duration: WaveMotion.fast,
                    opacity: widget.selected ? 1.0 : 0.0,
                    child: Container(
                      width: 3,
                      decoration: BoxDecoration(
                        color: accent,
                        borderRadius: BorderRadius.circular(1.5),
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: widget.expanded ? 14 : 0,
                    ),
                    child: Center(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          // Follow the animating rail width, not the
                          // instant `expanded` flag: the rail container
                          // animates 60<->200px over WaveMotion.normal
                          // while the flag flips immediately, which
                          // overflowed the Row mid-flight.
                          final isWide =
                              constraints.maxWidth > 100;
                          return isWide
                              ? Row(
                              children: [
                                AnimatedScale(
                                  scale: widget.selected
                                      ? 1.05
                                      : (_hover ? 1.02 : 1.0),
                                  duration: WaveMotion.fast,
                                  curve: Curves.easeOutCubic,
                                  child: Icon(
                                    widget.destination.icon,
                                    size: 16,
                                    color: widget.selected ? accent : fg,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    widget.destination.label,
                                    maxLines: 1,
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
                              ],
                            )
                          : Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                AnimatedScale(
                                  scale: widget.selected
                                      ? 1.06
                                      : (_hover ? 1.03 : 1.0),
                                  duration: WaveMotion.fast,
                                  curve: Curves.easeOutCubic,
                                  child: Icon(
                                    widget.destination.icon,
                                    size: 18,
                                    color: widget.selected ? accent : fg,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  widget.destination.label.split(' ').first,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: WaveType.meta.copyWith(
                                    fontSize: 9.5,
                                    fontWeight: widget.selected
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                    color: fg,
                                  ),
                                ),
                              ],
                            );
                      },
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (widget.expanded) return content;
    return LWTooltip(
      message: widget.destination.label,
      child: content,
    );
  }
}
