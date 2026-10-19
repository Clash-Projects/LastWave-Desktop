import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../features/player/playback_service.dart';
import '../components/artwork.dart';
import '../components/buttons.dart' show LWTooltip;
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

/// Small floating mini player window content.
///
/// `grip + artwork + title/artist + prev + play/pause + next + minimize + expand + close`
/// with an interactive scrubbable progress hairline.
/// Clicking and dragging anywhere on the non-button areas moves the native desktop window.
class WaveMiniPlayer extends ConsumerStatefulWidget {
  final VoidCallback onClose;
  final VoidCallback onExpand;
  const WaveMiniPlayer({
    super.key,
    required this.onClose,
    required this.onExpand,
  });

  @override
  ConsumerState<WaveMiniPlayer> createState() => _WaveMiniPlayerState();
}

class _WaveMiniPlayerState extends ConsumerState<WaveMiniPlayer> {
  @override
  void initState() {
    super.initState();
    _setTop(true);
  }

  @override
  void dispose() {
    _setTop(false);
    super.dispose();
  }

  Future<void> _setTop(bool value) async {
    try {
      await windowManager.setAlwaysOnTop(value);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final snap = ref.watch(playbackServiceProvider.select((s) => (
          current: s.current,
          isPlaying: s.isPlaying,
          isBuffering: s.isBuffering,
        )));
    final notifier = ref.read(playbackServiceProvider.notifier);
    final current = snap.current;

    // Draggable card container that fills the miniplayer window
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) {
        try {
          windowManager.startDragging();
        } catch (_) {}
      },
      onDoubleTap: widget.onExpand,
      child: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: BoxDecoration(
          color: dark ? waveSurfaceRaised(context) : WaveColors.lightSurface,
          border: Border.all(
            color: waveDivider(context).withValues(alpha: dark ? 0.35 : 0.6),
            width: 1,
          ),
        ),
        child: current == null
            ? _buildEmptyState(context, dark)
            : _buildPlayerContent(context, dark, current, snap, notifier),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context, bool dark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          MouseRegion(
            cursor: SystemMouseCursors.move,
            child: Icon(
              FluentIcons.gripper_dots_vertical,
              size: 14,
              color: waveTextSecondary(context).withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(width: 8),
          Icon(WaveIcons.music, size: 16, color: waveTextSecondary(context)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'No track playing',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: WaveType.meta.copyWith(fontSize: 12),
            ),
          ),
          _MiniGlyph(
            tooltip: 'Minimize',
            icon: FluentIcons.chrome_minimize,
            onTap: () {
              try {
                windowManager.minimize();
              } catch (_) {}
            },
            size: 11,
          ),
          _MiniGlyph(
            tooltip: 'Expand to window',
            icon: WaveIcons.expand,
            onTap: widget.onExpand,
            size: 12,
          ),
          _MiniGlyph(
            tooltip: 'Close mini player',
            icon: FluentIcons.chrome_close,
            onTap: widget.onClose,
            danger: true,
            size: 12,
          ),
        ],
      ),
    );
  }

  Widget _buildPlayerContent(
    BuildContext context,
    bool dark,
    dynamic current,
    dynamic snap,
    dynamic notifier,
  ) {
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                // Grip indicator for dragging window
                MouseRegion(
                  cursor: SystemMouseCursors.move,
                  child: Container(
                    padding: const EdgeInsets.only(right: 6, left: 2),
                    color: Colors.transparent,
                    child: Icon(
                      FluentIcons.gripper_dots_vertical,
                      size: 14,
                      color: waveTextSecondary(context).withValues(alpha: 0.5),
                    ),
                  ),
                ),
                // Artwork
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: widget.onExpand,
                    child: WaveArtwork(
                      url: current.artworkUrl,
                      videoId: current.videoId,
                      size: 46,
                      radius: WaveRadius.artwork,
                      label: current.title,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Title and Artist (draggable on pan, expand on tap)
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onExpand,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            current.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: WaveType.trackTitle.copyWith(
                              fontSize: 12.0,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            current.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: WaveType.meta.copyWith(fontSize: 11.0),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                // Transport controls: Previous, Play/Pause, Next
                _MiniGlyph(
                  tooltip: 'Previous',
                  icon: WaveIcons.previous,
                  onTap: notifier.previous,
                  size: 13,
                ),
                const SizedBox(width: 2),
                _MiniPlay(
                  playing: snap.isPlaying,
                  buffering: snap.isBuffering,
                  onTap: notifier.toggle,
                ),
                const SizedBox(width: 2),
                _MiniGlyph(
                  tooltip: 'Next',
                  icon: WaveIcons.next,
                  onTap: notifier.next,
                  size: 13,
                ),
                const SizedBox(width: 4),
                // Subtle divider between transport and window actions
                Container(
                  width: 1,
                  height: 18,
                  color: waveDivider(context).withValues(alpha: 0.6),
                ),
                const SizedBox(width: 4),
                _MiniGlyph(
                  tooltip: 'Minimize',
                  icon: FluentIcons.chrome_minimize,
                  onTap: () {
                    try {
                      windowManager.minimize();
                    } catch (_) {}
                  },
                  size: 11,
                ),
                _MiniGlyph(
                  tooltip: 'Expand to window',
                  icon: WaveIcons.expand,
                  onTap: widget.onExpand,
                  size: 12,
                ),
                _MiniGlyph(
                  tooltip: 'Close mini player',
                  icon: FluentIcons.chrome_close,
                  onTap: widget.onClose,
                  danger: true,
                  size: 12,
                ),
              ],
            ),
          ),
        ),
        const RepaintBoundary(child: _MiniProgress()),
      ],
    );
  }
}

/// 32px accent disc + on-accent glyph (dock parity, scaled down).
class _MiniPlay extends StatelessWidget {
  final bool playing;
  final bool buffering;
  final VoidCallback onTap;
  const _MiniPlay(
      {required this.playing,
      required this.buffering,
      required this.onTap});
  @override
  Widget build(BuildContext context) {
    // The dock renders the accent with a luminance-derived glyph; the mini
    // player used to hardcode off-white + black, which broke under the
    // off-white "LastWave neutral" accent and under light accents.
    final accent = waveAccent(context);
    final onAccent = onAccentFor(accent);
    return LWTooltip(
      message: playing ? 'Pause' : 'Play',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: accent,
            ),
            child: Center(
              child: buffering
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: ProgressRing(
                        strokeWidth: 2.5,
                        activeColor: onAccent,
                        backgroundColor: onAccent.withValues(alpha: 0.25),
                      ),
                    )
                  : Icon(
                      playing
                          ? WaveIcons.pause
                          : WaveIcons.play,
                      size: 14,
                      color: onAccent,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Sole position subscriber in the mini player with click-to-seek support.
class _MiniProgress extends ConsumerWidget {
  const _MiniProgress();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = waveIsDark(context);
    final clock = ref.watch(playbackServiceProvider.select((s) => (
          position: s.position,
          duration: s.duration,
        )));
    final totalMs = clock.duration.inMilliseconds;
    final progress = totalMs > 0
        ? (clock.position.inMilliseconds / totalMs).clamp(0.0, 1.0)
        : 0.0;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (details) {
        if (totalMs > 0) {
          final box = context.findRenderObject() as RenderBox?;
          if (box != null && box.size.width > 0) {
            final ratio =
                (details.localPosition.dx / box.size.width).clamp(0.0, 1.0);
            final targetMs = (ratio * totalMs).round();
            ref
                .read(playbackServiceProvider.notifier)
                .seek(Duration(milliseconds: targetMs));
          }
        }
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          height: 4,
          alignment: Alignment.bottomCenter,
          child: Container(
            height: 2.5,
            alignment: Alignment.centerLeft,
            color: (dark ? Colors.white : Colors.black).withValues(alpha: 0.12),
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: progress,
              child: Container(
                color: WaveColors.defaultAccent,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MiniGlyph extends StatefulWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;
  final bool danger;
  final double size;
  const _MiniGlyph({
    required this.tooltip,
    required this.icon,
    required this.onTap,
    this.danger = false,
    this.size = 13,
  });

  @override
  State<_MiniGlyph> createState() => _MiniGlyphState();
}

class _MiniGlyphState extends State<_MiniGlyph> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    return LWTooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration:
                waveMotion(context, const Duration(milliseconds: 120)),
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _hover
                  ? (widget.danger
                      ? WaveColors.danger.withValues(alpha: 0.85)
                      : (dark
                          ? Colors.white.withValues(alpha: 0.1)
                          : Colors.black.withValues(alpha: 0.06)))
                  : Colors.transparent,
            ),
            child: Center(
              child: Icon(
                widget.icon,
                size: widget.size,
                color: _hover
                    ? (widget.danger
                        ? Colors.white
                        : (dark ? Colors.white : Colors.black))
                    : waveTextSecondary(context),
              ),
            ),
          ),
        ),
      ),
    );
  }
}




