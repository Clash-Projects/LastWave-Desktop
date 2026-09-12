import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../design_system/icons.dart';
import 'package:palette_generator/palette_generator.dart';

import '../../app/track_actions.dart';
import '../../core/audio/stream_models.dart';
import '../../design_system/components.dart';
import '../../design_system/tokens.dart';
import '../downloads/download_manager.dart';
import '../library/playlists.dart';
import '../player/playback_service.dart';

final _paletteProvider = FutureProvider.autoDispose
    .family<Color, String>((ref, url) async {
  if (url.isEmpty) return const Color(0xFF232838);
  try {
    final palette = await PaletteGenerator.fromImageProvider(
      NetworkImage(url),
      size: const Size(64, 64),
      maximumColorCount: 8,
    );
    return palette.dominantColor?.color ?? const Color(0xFF232838);
  } catch (_) {
    return const Color(0xFF232838);
  }
});

/// Cinematic desktop Now Playing: artwork + metadata left, transport
/// centre, up-next right, ambient artwork-derived backdrop.
class NowPlayingScreen extends ConsumerWidget {
  const NowPlayingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playbackServiceProvider);
    final current = player.current;
    if (current == null) {
      return const EmptyState(
        icon: LwIcons.disc3,
        title: 'Nothing playing',
        subtitle: 'Pick something from Home or Search.',
      );
    }
    final seed = ref
            .watch(_paletteProvider(current.artworkUrl))
            .valueOrNull ??
        const Color(0xFF232838);
    final accent = Theme.of(context).colorScheme.primary;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            seed.withValues(alpha: 0.34),
            Theme.of(context)
                .scaffoldBackgroundColor
                .withValues(alpha: 0.0),
            Theme.of(context).scaffoldBackgroundColor,
          ],
          stops: const [0.0, 0.45, 1.0],
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth > 1100;
          return ListView(
            padding: const EdgeInsets.fromLTRB(
                LwSpacing.xl, LwSpacing.xl, LwSpacing.xl, 96),
            children: [
              Row(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  // LEFT: artwork + metadata + actions.
                  SizedBox(
                    width: wide ? 340 : 300,
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        Hero(
                          tag:
                              'artwork:${current.queueKey}',
                          child: Artwork(
                            url: current.artworkUrl,
                            size: wide ? 340 : 300,
                            radius: LwRadius.lg,
                          ),
                        ),
                        const SizedBox(
                            height: LwSpacing.md),
                        Text(current.title,
                            style: LwType.display
                                .copyWith(fontSize: 24)),
                        const SizedBox(height: 2),
                        Text(current.artist,
                            style: LwType.headline.copyWith(
                                fontSize: 15,
                                color: LwColors
                                    .textSecondary,
                                fontWeight:
                                    FontWeight.w500)),
                        if (current.album.isNotEmpty)
                          Text(current.album,
                              style: LwType.caption.copyWith(
                                  color: LwColors
                                      .textTertiary)),
                        const SizedBox(height: 8),
                        _QualityRow(),
                        const SizedBox(height: 12),
                        _ActionRow(accent: accent),
                      ],
                    ),
                  ),
                  const SizedBox(width: LwSpacing.xl),
                  // CENTER: transport + timeline + details.
                  Expanded(
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        Text(
                            player.sourceLabel.isEmpty
                                ? 'Now playing'
                                : player.sourceLabel,
                            style: LwType.micro.copyWith(
                                color: LwColors
                                    .textTertiary)),
                        const SizedBox(
                            height: LwSpacing.lg),
                        _BigTimeline(),
                        const SizedBox(
                            height: LwSpacing.md),
                        _BigTransport(),
                        const SizedBox(
                            height: LwSpacing.lg),
                        _MetaTable(),
                      ],
                    ),
                  ),
                  // RIGHT: up next.
                  if (wide) ...[
                    const SizedBox(
                        width: LwSpacing.xl),
                    const SizedBox(
                      width: 300,
                      child: _UpNext(),
                    ),
                  ],
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _QualityRow extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playbackServiceProvider);
    final stream = player.stream;
    if (stream == null) return const SizedBox.shrink();
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        QualityBadge(label: stream.qualityBadge),
        QualityBadge(label: stream.audioCodec),
        if (stream.isLossless)
          QualityBadge(
            label:
                '${stream.bitDepth}/${stream.samplingRateKhz}k',
          ),
        if (stream.bitrateKbps > 0)
          QualityBadge(
              label: '${stream.bitrateKbps} kbps'),
      ],
    );
  }
}

class _ActionRow extends ConsumerWidget {
  final Color accent;
  const _ActionRow({required this.accent});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playbackServiceProvider);
    final current = player.current!;
    final notifier =
        ref.read(playbackServiceProvider.notifier);
    final liked = ref
        .watch(playlistRepositoryProvider.notifier)
        .likedKeys()
        .contains(current.queueKey);
    return Row(
      children: [
        _CircleAction(
          icon: liked
              ? LwIcons.heart
              : LwIcons.heart,
          filled: liked,
          tooltip: liked ? 'Unlike' : 'Like',
          onTap: () => ref
              .read(playlistRepositoryProvider.notifier)
              .toggleLiked(StoredTrack(
                name: current.title,
                artist: current.artist,
                artworkUrl: current.artworkUrl,
                videoId: current.videoId,
              )),
        ),
        const SizedBox(width: 8),
        _CircleAction(
          icon: LwIcons.download,
          tooltip: 'Download',
          onTap: () => ref
              .read(downloadManagerProvider.notifier)
              .downloadTrack(
                title: current.title,
                artist: current.artist,
                album: current.album,
                artworkUrl: current.artworkUrl,
              ),
        ),
        const SizedBox(width: 8),
        _CircleAction(
          icon: LwIcons.listPlus,
          tooltip: 'Add to playlist',
          onTap: () =>
              _addToPlaylist(context, ref, current),
        ),
        const SizedBox(width: 8),
        _CircleAction(
          icon: LwIcons.mic,
          tooltip: 'Lyrics',
          onTap: () => context.go('/lyrics'),
        ),
        const SizedBox(width: 8),
        _CircleAction(
          icon: LwIcons.timer,
          tooltip: 'Sleep timer',
          active: player.sleepRemaining != null,
          onTap: () =>
              _sleepMenu(context, notifier, player),
        ),
      ],
    );
  }

  Future<void> _addToPlaylist(BuildContext context,
      WidgetRef ref, current) async {
    final playlists =
        ref.read(playlistRepositoryProvider);
    final id = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Add to playlist',
            style: LwType.title),
        children: [
          for (final p in playlists)
            SimpleDialogOption(
              onPressed: () =>
                  Navigator.of(context).pop(p.id),
              child: Text(p.title),
            ),
        ],
      ),
    );
    if (id != null) {
      await ref
          .read(playlistRepositoryProvider.notifier)
          .addTrack(
            id,
            StoredTrack(
              name: current.title,
              artist: current.artist,
              artworkUrl: current.artworkUrl,
              videoId: current.videoId,
            ),
          );
    }
  }

  Future<void> _sleepMenu(BuildContext context,
      PlaybackService notifier, player) async {
    final choice = await showDialog<Duration?>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Sleep timer',
            style: LwType.title),
        children: [
          for (final m in [15, 30, 60])
            SimpleDialogOption(
              onPressed: () => Navigator.of(context)
                  .pop(Duration(minutes: m)),
              child: Text('$m minutes'),
            ),
          SimpleDialogOption(
            onPressed: () =>
                Navigator.of(context).pop(Duration.zero),
            child: const Text('Off'),
          ),
        ],
      ),
    );
    if (choice != null) {
      notifier.setSleepTimer(
          choice == Duration.zero ? null : choice);
    }
  }
}

class _CircleAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool filled;
  final bool active;
  const _CircleAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.filled = false,
    this.active = false,
  });
  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: filled
            ? accent
            : Colors.white.withValues(alpha: 0.06),
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(icon,
                size: 16,
                color: filled
                    ? Colors.white
                    : active
                        ? accent
                        : LwColors.textPrimary),
          ),
        ),
      ),
    );
  }
}

class _BigTimeline extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playbackServiceProvider);
    final notifier =
        ref.read(playbackServiceProvider.notifier);
    final total = player.duration.inMilliseconds;
    final pos = player.position.inMilliseconds;
    final ratio = total <= 0
        ? 0.0
        : (pos / total).clamp(0.0, 1.0);
    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context)
              .copyWith(trackHeight: 4),
          child: Slider(
            value: ratio,
            onChanged: total <= 0
                ? null
                : (v) => notifier.seek(Duration(
                    milliseconds:
                        (v * total).round())),
          ),
        ),
        Row(
          mainAxisAlignment:
              MainAxisAlignment.spaceBetween,
          children: [
            Text(formatDuration(player.position),
                style: LwType.caption),
            Text(formatDuration(player.duration),
                style: LwType.caption),
          ],
        ),
      ],
    );
  }
}

class _BigTransport extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playbackServiceProvider);
    final notifier =
        ref.read(playbackServiceProvider.notifier);
    final accent = Theme.of(context).colorScheme.primary;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          onPressed: notifier.toggleShuffle,
          icon: const Icon(LwIcons.shuffle,
              size: 18),
          color: player.shuffleEnabled
              ? accent
              : LwColors.textSecondary,
          tooltip: 'Shuffle',
        ),
        IconButton(
          onPressed: notifier.previous,
          icon: const Icon(LwIcons.skipBack,
              size: 26),
          color: LwColors.textPrimary,
          tooltip: 'Previous',
        ),
        const SizedBox(width: 8),
        Material(
          color: Colors.white,
          shape: const CircleBorder(),
          child: InkWell(
            onTap: notifier.toggle,
            customBorder: const CircleBorder(),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: player.isBuffering
                  ? SizedBox(
                      width: 26,
                      height: 26,
                      child:
                          CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: accent,
                      ),
                    )
                  : Icon(
                      player.isPlaying
                          ? LwIcons.pause
                          : LwIcons.play,
                      size: 26,
                      color: Colors.black,
                    ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          onPressed: notifier.next,
          icon: const Icon(LwIcons.skipForward,
              size: 26),
          color: LwColors.textPrimary,
          tooltip: 'Next',
        ),
        IconButton(
          onPressed: notifier.cycleRepeat,
          icon: Icon(
              player.repeatMode == RepeatMode.one
                  ? LwIcons.repeat1
                  : LwIcons.repeat,
              size: 18),
          color: player.repeatMode != RepeatMode.off
              ? accent
              : LwColors.textSecondary,
          tooltip: 'Repeat (${player.repeatMode.name})',
        ),
      ],
    );
  }
}

class _MetaTable extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playbackServiceProvider);
    final stream = player.stream;
    if (stream == null) return const SizedBox.shrink();
    final rows = {
      'Source': stream.cacheKey.startsWith('lossless:')
          ? 'Lossless backend'
          : stream.cacheKey.startsWith('local:')
              ? 'Downloaded file'
              : 'YouTube Music',
      'Codec': stream.audioCodec,
      'Bitrate': '${stream.bitrateKbps} kbps',
      if (stream.isLossless)
        'Depth / Rate':
            '${stream.bitDepth}-bit / ${stream.samplingRateKhz} kHz',
      'Speed': '${player.speed}×',
    };
    return Container(
      padding: const EdgeInsets.all(LwSpacing.md),
      decoration: BoxDecoration(
        color: LwColors.surfaceRaised,
        borderRadius:
            BorderRadius.circular(LwRadius.md),
        border:
            Border.all(color: LwColors.outlineSoft),
      ),
      child: Column(
        children: rows.entries
            .map((e) => Padding(
                  padding: const EdgeInsets.symmetric(
                      vertical: 4),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 110,
                        child: Text(e.key,
                            style: LwType.caption.copyWith(
                                color: LwColors
                                    .textTertiary)),
                      ),
                      Expanded(
                          child: Text(e.value,
                              style: LwType.body)),
                    ],
                  ),
                ))
            .toList(),
      ),
    );
  }
}

class _UpNext extends ConsumerWidget {
  const _UpNext();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playbackServiceProvider);
    final notifier =
        ref.read(playbackServiceProvider.notifier);
    final upcoming = player.currentIndex >= 0
        ? player.queue
            .skip(player.currentIndex + 1)
            .take(8)
            .toList()
        : const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Up next', style: LwType.title),
        const SizedBox(height: 8),
        if (upcoming.isEmpty)
          const Text(
              'Queue ends here — enable Mix radio from any track.',
              style: LwType.caption)
        else
          ...upcoming.asMap().entries.map((e) {
            final t = e.value;
            return TrackTile(
              title: t.title,
              subtitle: t.artist,
              artworkUrl: t.artworkUrl,
              onTap: () => notifier.seekToQueueItem(
                  player.currentIndex + 1 + e.key),
            );
          }),
      ],
    );
  }
}
