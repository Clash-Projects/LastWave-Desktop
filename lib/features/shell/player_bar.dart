import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../design_system/icons.dart';

import '../../core/audio/stream_models.dart';
import '../../design_system/components.dart';
import '../../design_system/tokens.dart';
import '../library/playlists.dart';
import '../player/playback_service.dart';
import '../../app/track_actions.dart';

/// Persistent bottom player: artwork, metadata, transport, timeline,
/// volume, and quick access to queue/lyrics/quality.
class PlayerBar extends ConsumerStatefulWidget {
  final VoidCallback onExpand;
  final VoidCallback onToggleQueue;
  const PlayerBar({
    super.key,
    required this.onExpand,
    required this.onToggleQueue,
  });

  @override
  ConsumerState<PlayerBar> createState() => _PlayerBarState();
}

class _PlayerBarState extends ConsumerState<PlayerBar> {
  double? _dragVolume;

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(playbackServiceProvider);
    final notifier = ref.read(playbackServiceProvider.notifier);
    final current = player.current;
    if (current == null) return const SizedBox.shrink();
    final accent = Theme.of(context).colorScheme.primary;

    return Container(
      height: 76,
      decoration: const BoxDecoration(
        color: LwColors.surface,
        border: Border(
            top: BorderSide(color: LwColors.outlineSoft)),
      ),
      child: Column(
        children: [
          // Timeline (edge-to-edge, compact).
          _Timeline(
            position: player.position,
            duration: player.duration,
            accent: accent,
            onSeek: notifier.seek,
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: LwSpacing.sm),
              child: Row(
                children: [
                  // Track identity.
                  InkWell(
                    onTap: widget.onExpand,
                    borderRadius:
                        BorderRadius.circular(LwRadius.sm),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Artwork(
                            url: current.artworkUrl, size: 46),
                        const SizedBox(width: 10),
                        ConstrainedBox(
                          constraints: const BoxConstraints(
                              maxWidth: 260),
                          child: Column(
                            mainAxisAlignment:
                                MainAxisAlignment.center,
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              Text(
                                current.title,
                                maxLines: 1,
                                overflow:
                                    TextOverflow.ellipsis,
                                style: LwType.title.copyWith(
                                    fontSize: 13),
                              ),
                              Text(
                                current.artist,
                                maxLines: 1,
                                overflow:
                                    TextOverflow.ellipsis,
                                style: LwType.caption.copyWith(
                                    color: LwColors
                                        .textSecondary),
                              ),
                            ],
                          ),
                        ),
                        if ((player.stream?.qualityBadge ??
                                '')
                            .isNotEmpty) ...[
                          const SizedBox(width: 8),
                          QualityBadge(
                              label: player
                                  .stream!.qualityBadge),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _BarButton(
                    icon: LwIcons.heart,
                    tooltip: 'Like',
                    onTap: () => _toggleLike(current),
                  ),
                  const Spacer(),
                  // Transport cluster.
                  _BarButton(
                    icon: LwIcons.shuffle,
                    tooltip: 'Shuffle',
                    active: player.shuffleEnabled,
                    onTap: notifier.toggleShuffle,
                  ),
                  _BarButton(
                    icon: LwIcons.skipBack,
                    tooltip: 'Previous',
                    filled: true,
                    onTap: notifier.previous,
                  ),
                  _PlayButton(
                    playing: player.isPlaying,
                    buffering: player.isBuffering,
                    accent: accent,
                    onTap: notifier.toggle,
                  ),
                  _BarButton(
                    icon: LwIcons.skipForward,
                    tooltip: 'Next',
                    filled: true,
                    onTap: notifier.next,
                  ),
                  _BarButton(
                    icon: switch (player.repeatMode) {
                      RepeatMode.one =>
                        LwIcons.repeat1,
                      _ => LwIcons.repeat,
                    },
                    tooltip:
                        'Repeat (${player.repeatMode.name})',
                    active:
                        player.repeatMode != RepeatMode.off,
                    onTap: notifier.cycleRepeat,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${formatDuration(player.position)} / ${formatDuration(player.duration)}',
                    style: LwType.caption.copyWith(
                        color: LwColors.textTertiary,
                        fontFeatures: const [
                          FontFeature.tabularFigures()
                        ]),
                  ),
                  const Spacer(),
                  // Right cluster.
                  if (player.sleepRemaining != null)
                    Padding(
                      padding: const EdgeInsets.only(
                          right: LwSpacing.xs),
                      child: QualityBadge(
                        label:
                            'SLEEP ${player.sleepRemaining!.inMinutes}m',
                      ),
                    ),
                  _VolumeControl(
                    volume: _dragVolume,
                    onChanged: (_) {},
                  ),
                  _BarButton(
                    icon: LwIcons.listVideo,
                    tooltip: 'Queue',
                    onTap: widget.onToggleQueue,
                  ),
                  _BarButton(
                    icon: LwIcons.mic,
                    tooltip: 'Lyrics',
                    onTap: () => context.go('/lyrics'),
                  ),
                  _BarButton(
                    icon: LwIcons.maximize2,
                    tooltip: 'Now playing',
                    onTap: widget.onExpand,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleLike(PlayableTrack current) async {    await ref
        .read(playlistRepositoryProvider.notifier)
        .toggleLiked(StoredTrack(
          name: current.title,
          artist: current.artist,
          artworkUrl: current.artworkUrl,
          videoId: current.videoId,
        ));
  }
}

class _Timeline extends StatefulWidget {
  final Duration position;
  final Duration duration;
  final Color accent;
  final ValueChanged<Duration> onSeek;
  const _Timeline({
    required this.position,
    required this.duration,
    required this.accent,
    required this.onSeek,
  });
  @override
  State<_Timeline> createState() => _TimelineState();
}

class _TimelineState extends State<_Timeline> {
  double? _drag;
  @override
  Widget build(BuildContext context) {
    final totalMs = widget.duration.inMilliseconds;
    final posMs = widget.position.inMilliseconds;
    final ratio = totalMs <= 0
        ? 0.0
        : ((_drag ?? posMs.toDouble()) / totalMs)
            .clamp(0.0, 1.0);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: (d) =>
          setState(() => _drag = ratio * totalMs),
      onHorizontalDragUpdate: (d) {
        final box = context.findRenderObject() as RenderBox?;
        if (box == null) return;
        final local = box.globalToLocal(d.globalPosition);
        setState(() => _drag =
            (local.dx / box.size.width * totalMs)
                .clamp(0, totalMs.toDouble()));
      },
      onHorizontalDragEnd: (_) {
        if (_drag != null) {
          widget.onSeek(
              Duration(milliseconds: _drag!.round()));
        }
        setState(() => _drag = null);
      },
      onTapDown: (d) {
        final box = context.findRenderObject() as RenderBox?;
        if (box == null || totalMs <= 0) return;
        final local = box.globalToLocal(d.globalPosition);
        widget.onSeek(Duration(
            milliseconds:
                (local.dx / box.size.width * totalMs)
                    .round()
                    .clamp(0, totalMs)));
      },
      child: SizedBox(
        height: 12,
        child: Center(
          child: Stack(
            children: [
              Container(
                  height: 3,
                  color: Colors.white
                      .withValues(alpha: 0.12)),
              FractionallySizedBox(
                widthFactor: ratio,
                child: Container(
                    height: 3, color: widget.accent),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BarButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;
  final bool filled;
  const _BarButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
    this.filled = false,
  });
  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final color = active
        ? accent
        : filled
            ? LwColors.textPrimary
            : LwColors.textSecondary;
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onTap,
        icon: Icon(icon, size: filled ? 19 : 16),
        color: color,
        hoverColor:
            Colors.white.withValues(alpha: 0.06),
        constraints:
            const BoxConstraints(minWidth: 34, minHeight: 34),
        padding: EdgeInsets.zero,
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  final bool playing;
  final bool buffering;
  final Color accent;
  final VoidCallback onTap;
  const _PlayButton({
    required this.playing,
    required this.buffering,
    required this.accent,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: Colors.white,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: buffering
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: accent,
                    ),
                  )
                : Icon(
                    playing
                        ? LwIcons.pause
                        : LwIcons.play,
                    size: 18,
                    color: Colors.black,
                  ),
          ),
        ),
      ),
    );
  }
}

class _VolumeControl extends StatelessWidget {
  final double? volume;
  final ValueChanged<double> onChanged;
  const _VolumeControl({
    required this.volume,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) {
    // media_kit volume is controlled per-player; the bar keeps a
    // compact mute affordance until device routing lands.
    return const Tooltip(
      message: 'Volume follows the system mixer',
      child: Padding(
        padding:
            EdgeInsets.symmetric(horizontal: LwSpacing.xs),
        child: Icon(LwIcons.volume2,
            size: 16, color: LwColors.textSecondary),
      ),
    );
  }
}
