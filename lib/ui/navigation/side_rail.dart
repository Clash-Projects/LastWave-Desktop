import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/player/playback_service.dart';
import '../components/artwork.dart';
import '../components/buttons.dart' show LWTooltip;
import '../theme/haze.dart';
import '../theme/tokens.dart';
import 'destinations.dart';

/// Compact secondary navigation — MUSIC stays primary.
///
/// - 200px expanded / 60px collapsed rail
/// - small 32px rows, no giant rounded rectangles
/// - selected = subtle wash + 2px accent bar, nothing loud
/// - bottom: Friends / Settings pinned, history hidden
class WaveSideRail extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
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
      child: SizedBox(
        width: width,
      child: Column(
        children: [
          const SizedBox(height: 6),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              children: [
                for (final d in waveListenDestinations)
                  _RailItem(
                    destination: d,
                    expanded: expanded,
                    selected: active == d.path,
                    onTap: () => onGo(d.path),
                  ),
                _RailSeparator(expanded: expanded),
                for (final d in waveCollectionDestinations)
                  _RailItem(
                    destination: d,
                    expanded: expanded,
                    selected: active == d.path,
                    onTap: () => onGo(d.path),
                  ),
                _RailSeparator(expanded: expanded),
                for (final d in waveOfflineDestinations)
                  _RailItem(
                    destination: d,
                    expanded: expanded,
                    selected: active == d.path,
                    onTap: () => onGo(d.path),
                  ),
              ],
            ),
          ),
          Container(
            height: 1,
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: waveDivider(context),
          ),
          for (final d in waveSystemDestinations)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: _RailItem(
                destination: d,
                expanded: expanded,
                selected: active == d.path,
                onTap: () => onGo(d.path),
              ),
            ),
          _MiniNowPlaying(expanded: expanded),
          const SizedBox(height: 8),
        ],
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
        ? (dark ? Colors.white : Colors.black).withValues(alpha: 0.07)
        : _hover
            ? (dark ? Colors.white : Colors.black).withValues(alpha: 0.04)
            : Colors.transparent;
    final fg = widget.selected
        ? (dark ? WaveColors.textPrimary : WaveColors.lightTextPrimary)
        : (dark ? WaveColors.textSecondary : WaveColors.lightTextSecondary);
    final hasFocus = _focus.hasFocus;

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
            height: widget.expanded ? 32 : 46,
            margin: const EdgeInsets.symmetric(vertical: 1),
            padding: EdgeInsets.symmetric(
              horizontal: widget.expanded ? 10 : 0,
            ),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(WaveRadius.controls),
              border: hasFocus
                  ? Border.all(
                      color: accent.withValues(alpha: 0.6), width: 1)
                  : Border.all(color: Colors.transparent, width: 1),
            ),
            child: Stack(
              children: [
                if (widget.selected)
                  Positioned(
                    left: widget.expanded ? -10 : -6,
                    top: 8,
                    bottom: 8,
                    child: Container(
                      width: 2,
                      decoration: BoxDecoration(
                        color: accent,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                Center(
                  child: widget.expanded
                      ? Row(
                          children: [
                            Icon(
                              widget.destination.icon,
                              size: 16,
                              color: widget.selected ? accent : fg,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                widget.destination.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: WaveType.label.copyWith(
                                  fontSize: 12.5,
                                  fontWeight: widget.selected
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  color: fg,
                                ),
                              ),
                            ),
                          ],
                        )
                      : Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              widget.destination.icon,
                              size: 17,
                              color: widget.selected ? accent : fg,
                            ),
                            const SizedBox(height: 3),
                            Text(
                              widget.destination.label.split(' ').first,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: WaveType.meta.copyWith(
                                fontSize: 9,
                                fontWeight: widget.selected
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: fg,
                              ),
                            ),
                          ],
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

class _MiniNowPlaying extends ConsumerWidget {
  final bool expanded;
  const _MiniNowPlaying({required this.expanded});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(
      playbackServiceProvider.select((s) => s.current),
    );
    if (track == null) return const SizedBox.shrink();
    final art = WaveArtwork(
      url: track.artworkUrl,
      size: 30,
      radius: WaveRadius.artwork,
    );
    // Collapsed rail is 60px wide: artwork only, with a tooltip.
    // Tapping opens Now Playing; keyboard-focusable.
    Widget inner;
    if (!expanded) {
      inner = Container(
        margin: const EdgeInsets.fromLTRB(0, 6, 0, 0),
        alignment: Alignment.center,
        child: art,
      );
    } else {
      inner = Container(
        margin: const EdgeInsets.fromLTRB(6, 6, 6, 0),
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(WaveRadius.controls),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            art,
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: WaveType.label.copyWith(fontSize: 11),
                  ),
                  Text(
                    track.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: WaveType.meta.copyWith(fontSize: 10.5),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return LWTooltip(
      message: '${track.title} — ${track.artist}\nOpen Now Playing',
      child: Focus(
        canRequestFocus: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.enter ||
                  event.logicalKey == LogicalKeyboardKey.space)) {
            context.go('/now');
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () => context.go('/now'),
            child: inner,
          ),
        ),
      ),
    );
  }
}
