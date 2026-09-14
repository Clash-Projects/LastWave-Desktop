import 'package:audio_video_progress_bar/audio_video_progress_bar.dart';
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/track_actions.dart';
import '../../core/audio/stream_models.dart';
import '../../design_system/components.dart';
import '../../design_system/icons.dart';
import '../../design_system/tokens.dart';
import '../downloads/download_manager.dart';
import '../library/playlists.dart';
import '../lyrics/lyrics_view.dart';
import 'playback_service.dart';
import '../../widgets/artwork.dart';
import '../../widgets/quality_badge.dart';
import '../../widgets/toast.dart';
import '../../widgets/track_tile.dart';

/// Editorial Now Playing: ledger (artwork + metadata + single transport)
/// beside expansive Lyrics-or-Queue reader.
///
/// Replaces 3-column artwork/transport/up-next + boxed meta card +
/// duplicated large transports. Wide: balanced 360 ledger + flex reader.
/// Narrow: single column with Ledger | Lyrics | Queue segments.
class NowPlayingScreen extends ConsumerStatefulWidget {
  const NowPlayingScreen({super.key});
  @override
  ConsumerState<NowPlayingScreen> createState() =>
      _NowPlayingScreenState();
}

class _NowPlayingScreenState
    extends ConsumerState<NowPlayingScreen> {
  String _pane = 'lyrics';

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(
        playbackServiceProvider.select((s) => s.current));
    if (current == null) {
      return const _NothingPlaying();
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth > 1100;
        if (wide) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(
                LwSpacing.xl, LwSpacing.lg, LwSpacing.xl, 96),
            children: [
              EdPage(
                child: Row(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    const SizedBox(
                      width: 360,
                      child: _Ledger(),
                    ),
                    const SizedBox(
                        width: LwSpacing.xxl),
                    Expanded(
                      child: SizedBox(
                        height: 640,
                        child: _Reader(
                          pane: _pane,
                          onPane: (v) => setState(
                              () => _pane = v),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(
              LwSpacing.md, LwSpacing.md, LwSpacing.md, 96),
          children: [
            _CompactHeader(track: current),
            const SizedBox(height: LwSpacing.sm),
            Center(
              child: EdSegmented<String>(
                value: _pane,
                options: const [
                  ('ledger', 'Details'),
                  ('lyrics', 'Lyrics'),
                  ('queue', 'Up next'),
                ],
                onChanged: (v) =>
                    setState(() => _pane = v),
              ),
            ),
            const SizedBox(height: LwSpacing.sm),
            if (_pane == 'ledger')
              const _Ledger()
            else if (_pane == 'lyrics')
              SizedBox(
                height: 520,
                child: LyricsColumn(
                  key: ValueKey(current.queueKey),
                  track: current,
                ),
              )
            else
              const _UpNextLedger(),
          ],
        );
      },
    );
  }
}

class _NothingPlaying extends StatelessWidget {
  const _NothingPlaying();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(LwSpacing.lg),
            decoration: BoxDecoration(
              color: LwColors.surfaceRaised,
              borderRadius:
                  BorderRadius.circular(LwRadius.lg),
              border:
                  Border.all(color: LwColors.outlineSoft),
            ),
            child: const Icon(LucideIcons.disc3,
                size: 30, color: LwColors.textTertiary),
          ),
          const SizedBox(height: LwSpacing.md),
          const Text('Nothing playing',
              style: LwType.headline),
          const SizedBox(height: 4),
          const Text('Pick something from Home or Search.',
              style: LwType.caption),
        ],
      ),
    );
  }
}

class _CompactHeader extends ConsumerWidget {
  final PlayableTrack track;
  const _CompactHeader({required this.track});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      children: [
        Artwork(
            url: track.artworkUrl,
            size: 88,
            radius: LwRadius.md),
        const SizedBox(width: LwSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              Text(track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: LwType.headline),
              Text(track.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: LwType.body.copyWith(
                      color: dark
                          ? LwColors.textSecondary
                          : LwColors
                              .lightTextSecondary)),
            ],
          ),
        ),
        _LedgerLike(track: track),
      ],
    );
  }
}

class _Ledger extends ConsumerWidget {
  const _Ledger();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(
        playbackServiceProvider.select((s) => s.current))!;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final source = ref.watch(playbackServiceProvider
        .select((s) => s.sourceLabel));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (source.isNotEmpty) EdKicker(source),
        if (source.isNotEmpty)
          const SizedBox(height: 4),
        Artwork(
          url: current.artworkUrl,
          size: 320,
          radius: LwRadius.lg,
        ),
        const SizedBox(height: LwSpacing.md),
        Text(current.title,
            style:
                LwType.display.copyWith(fontSize: 24)),
        const SizedBox(height: 2),
        Text(current.artist,
            style: LwType.headline.copyWith(
                fontSize: 15,
                color: dark
                    ? LwColors.textSecondary
                    : LwColors.lightTextSecondary,
                fontWeight: FontWeight.w500)),
        if (current.album.isNotEmpty)
          Text(current.album,
              style: LwType.caption.copyWith(
                  color: dark
                      ? LwColors.textTertiary
                      : LwColors
                          .lightTextTertiary)),
        const SizedBox(height: LwSpacing.sm),
        const _QualityLedger(),
        const SizedBox(height: LwSpacing.sm),
        const _SingleTransport(),
        const SizedBox(height: LwSpacing.sm),
        _LedgerActions(track: current),
        const SizedBox(height: LwSpacing.md),
        const _StreamLedger(),
      ],
    );
  }
}

class _QualityLedger extends ConsumerWidget {
  const _QualityLedger();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stream = ref.watch(
        playbackServiceProvider.select((s) => s.stream));
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

/// Single dominant transport: the only large play control on this page
/// (dock stays mini). Progress underneath, volume/speed inline.
class _SingleTransport extends ConsumerWidget {
  const _SingleTransport();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playbackServiceProvider.select((s) => (
      shuffleEnabled: s.shuffleEnabled,
      isPlaying: s.isPlaying,
      isBuffering: s.isBuffering,
      repeatMode: s.repeatMode,
      volume: s.volume,
      speed: s.speed,
    )));
    final notifier =
        ref.read(playbackServiceProvider.notifier);
    final accent = Theme.of(context).colorScheme.primary;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            LwIconButton(
              tooltip: 'Shuffle',
              icon: Icon(LucideIcons.shuffle,
                  size: 17,
                  color: player.shuffleEnabled
                      ? accent
                      : null),
              selected: player.shuffleEnabled,
              onPressed: notifier.toggleShuffle,
            ),
            LwIconButton(
              tooltip: 'Previous',
              icon: const Icon(
                  LucideIcons.skipBack,
                  size: 22),
              onPressed: notifier.previous,
            ),
            const SizedBox(width: LwSpacing.xs),
            Material(
              color: dark
                  ? Colors.white
                  : LwColors.lightTextPrimary,
              shape: const CircleBorder(),
              elevation: 3,
              child: InkWell(
                onTap: notifier.toggle,
                customBorder:
                    const CircleBorder(),
                child: Padding(
                  padding:
                      const EdgeInsets.all(13),
                  child: player.isBuffering
                      ? SizedBox(
                          width: 24,
                          height: 24,
                          child:
                              CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: accent,
                          ),
                        )
                      : Icon(
                          player.isPlaying
                              ? LucideIcons.pause
                              : LucideIcons.play,
                          size: 24,
                          color: dark
                              ? Colors.black
                              : Colors.white,
                        ),
                ),
              ),
            ),
            const SizedBox(width: LwSpacing.xs),
            LwIconButton(
              tooltip: 'Next',
              icon: const Icon(
                  LucideIcons.skipForward,
                  size: 22),
              onPressed: notifier.next,
            ),
            LwIconButton(
              tooltip:
                  'Repeat (${player.repeatMode.name})',
              icon: Icon(
                player.repeatMode ==
                        RepeatMode.one
                    ? LucideIcons.repeat1
                    : LucideIcons.repeat,
                size: 17,
                color: player.repeatMode !=
                        RepeatMode.off
                    ? accent
                    : null,
              ),
              selected: player.repeatMode !=
                  RepeatMode.off,
              onPressed: notifier.cycleRepeat,
            ),
          ],
        ),
        const SizedBox(height: LwSpacing.xs),
        Consumer(builder: (context, ref, _) {
          final clock =
              ref.watch(playbackServiceProvider.select(
                  (s) => (
                        position: s.position,
                        buffered: s.buffered,
                        duration: s.duration
                      )));
          return ProgressBar(
            progress: clock.position,
            buffered: clock.buffered,
            total: clock.duration,
            onSeek: notifier.seek,
            barHeight: 4,
            thumbRadius: 6,
            thumbColor: Colors.white,
            thumbGlowColor:
                accent.withValues(alpha: 0.3),
            progressBarColor: accent,
            bufferedBarColor: (dark
                    ? Colors.white
                    : Colors.black)
                .withValues(alpha: 0.18),
            baseBarColor: (dark
                    ? Colors.white
                    : Colors.black)
                .withValues(alpha: 0.12),
            timeLabelLocation:
                TimeLabelLocation.sides,
            timeLabelTextStyle:
                LwType.caption.copyWith(
                    color: dark
                        ? LwColors.textSecondary
                        : LwColors
                            .lightTextSecondary,
                    fontFeatures: const [
                  FontFeature.tabularFigures()
                ]),
          );
        }),
        const SizedBox(height: LwSpacing.xs),
        Row(
          children: [
            LwIconButton(
              tooltip: 'Mute',
              icon: Icon(
                player.volume == 0
                    ? LucideIcons.volumeX
                    : LucideIcons.volume2,
                size: 16,
              ),
              onPressed: () => notifier.setVolume(
                  player.volume == 0 ? 1 : 0),
            ),
            Expanded(
              child: LwSlider(
                value: player.volume,
                min: 0,
                max: 1,
                onChanged: (v) =>
                    notifier.setVolume(v),
              ),
            ),
            const SizedBox(width: LwSpacing.sm),
            TextButton(
              onPressed: notifier.cycleSpeed,
              child: Text('${player.speed}×',
                  style: LwType.label),
            ),
          ],
        ),
      ],
    );
  }
}

class _LedgerLike extends ConsumerWidget {
  final PlayableTrack track;
  const _LedgerLike({required this.track});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = Theme.of(context).colorScheme.primary;
    final liked = ref
        .watch(playlistRepositoryProvider.notifier)
        .likedKeys()
        .contains(track.queueKey);
    return LwIconButton(
      tooltip: liked ? 'Unlike' : 'Like',
      icon: Icon(LucideIcons.heart,
          size: 16,
          color: liked ? accent : null),
      onPressed: () => toggleLike(
        ref,
        context,
        title: track.title,
        artist: track.artist,
        artworkUrl: track.artworkUrl,
        videoId: track.videoId,
      ),
    );
  }
}

class _LedgerActions extends ConsumerWidget {
  final PlayableTrack track;
  const _LedgerActions({required this.track});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier =
        ref.read(playbackServiceProvider.notifier);
    final accent = Theme.of(context).colorScheme.primary;
    final liked = ref
        .watch(playlistRepositoryProvider.notifier)
        .likedKeys()
        .contains(track.queueKey);
    final sleep = ref.watch(playbackServiceProvider
        .select((s) => s.sleepRemaining != null));
    Widget btn(
        {required IconData icon,
        required String tip,
        required VoidCallback onTap,
        bool active = false}) {
      return LwIconButton(
        tooltip: tip,
        icon: Icon(icon,
            size: 16,
            color: active ? accent : null),
        selected: active,
        onPressed: onTap,
      );
    }

    return Row(
      children: [
        btn(
          icon: LucideIcons.heart,
          tip: liked ? 'Unlike' : 'Like',
          active: liked,
          onTap: () => toggleLike(
            ref,
            context,
            title: track.title,
            artist: track.artist,
            artworkUrl: track.artworkUrl,
            videoId: track.videoId,
          ),
        ),
        btn(
          icon: LucideIcons.download,
          tip: 'Download',
          onTap: () {
            ref
                .read(downloadManagerProvider.notifier)
                .downloadTrack(
                  title: track.title,
                  artist: track.artist,
                  album: track.album,
                  artworkUrl: track.artworkUrl,
                );
            showToast(context, 'Download started.');
          },
        ),
        btn(
          icon: LucideIcons.listPlus,
          tip: 'Add to playlist',
          onTap: () =>
              _addToPlaylist(context, ref, track),
        ),
        btn(
          icon: LucideIcons.micVocal,
          tip: 'Lyrics',
          onTap: () => context.go('/lyrics'),
        ),
        btn(
          icon: LucideIcons.timer,
          tip: 'Sleep timer',
          active: sleep,
          onTap: () =>
              _sleepDialog(context, notifier),
        ),
      ],
    );
  }

  Future<void> _addToPlaylist(BuildContext context,
      WidgetRef ref, PlayableTrack current) async {
    final playlists =
        ref.read(playlistRepositoryProvider);
    final id = await showLwDialog<int>(
      context: context,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment:
            CrossAxisAlignment.stretch,
        children: [
          const Text('Add to playlist',
              style: LwType.headline),
          const SizedBox(height: LwSpacing.sm),
          for (final p in playlists)
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () =>
                    Navigator.of(context).pop(p.id),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      vertical: 9),
                  child: Row(
                    children: [
                      const Icon(
                          LucideIcons.listMusic,
                          size: 15),
                      const SizedBox(
                          width: LwSpacing.sm),
                      Expanded(
                          child: Text(p.title,
                              style: LwType.body)),
                    ],
                  ),
                ),
              ),
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
      if (context.mounted) {
        showToast(context, 'Added to playlist.');
      }
    }
  }

  Future<void> _sleepDialog(
      BuildContext context, PlaybackService notifier) async {
    final choice = await showLwDialog<Duration?>(
      context: context,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment:
            CrossAxisAlignment.stretch,
        children: [
          const Text('Sleep timer',
              style: LwType.headline),
          const SizedBox(height: LwSpacing.sm),
          for (final m in [15, 30, 60])
            _DialogOption(
              label: '$m minutes',
              onTap: () => Navigator.of(context)
                  .pop(Duration(minutes: m)),
            ),
          _DialogOption(
            label: 'Off',
            onTap: () =>
                Navigator.of(context).pop(Duration.zero),
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

class _DialogOption extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _DialogOption(
      {required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(LwRadius.sm),
        child: Padding(
          padding: const EdgeInsets.symmetric(
              vertical: 10, horizontal: LwSpacing.xs),
          child: Row(children: [
            Expanded(
                child:
                    Text(label, style: LwType.body)),
            const Icon(LucideIcons.chevronRight,
                size: 14, color: LwColors.textTertiary),
          ]),
        ),
      ),
    );
  }
}

/// Flat stream facts ledger (no card): definition rows with dividers.
class _StreamLedger extends ConsumerWidget {
  const _StreamLedger();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final player = ref.watch(playbackServiceProvider.select(
        (s) => (stream: s.stream, speed: s.speed)));
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const EdKicker('Stream'),
        const SizedBox(height: LwSpacing.xs),
        ...rows.entries.map((e) => Padding(
              padding: const EdgeInsets.symmetric(
                  vertical: 5),
              child: Row(
                children: [
                  SizedBox(
                    width: 110,
                    child: Text(e.key,
                        style: LwType.caption.copyWith(
                            color: dark
                                ? LwColors.textTertiary
                                : LwColors
                                    .lightTextTertiary)),
                  ),
                  Expanded(
                      child: Text(e.value,
                          style: LwType.body)),
                ],
              ),
            )),
      ],
    );
  }
}

class _Reader extends StatelessWidget {
  final String pane;
  final ValueChanged<String> onPane;
  const _Reader({required this.pane, required this.onPane});
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        EdSegmented<String>(
          value: pane,
          options: const [
            ('lyrics', 'Lyrics'),
            ('queue', 'Up next'),
          ],
          onChanged: onPane,
        ),
        const SizedBox(height: LwSpacing.sm),
        const LwSeparator.horizontal(),
        Expanded(
          child: pane == 'lyrics'
              ? const _ReaderLyrics()
              : const _UpNextLedger(),
        ),
      ],
    );
  }
}

class _ReaderLyrics extends ConsumerWidget {
  const _ReaderLyrics();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(
        playbackServiceProvider.select((s) => s.current))!;
    return LyricsColumn(
      key: ValueKey(current.queueKey),
      track: current,
    );
  }
}

class _UpNextLedger extends ConsumerWidget {
  const _UpNextLedger();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playbackServiceProvider.select(
        (s) => (queue: s.queue, currentIndex: s.currentIndex)));
    final notifier =
        ref.read(playbackServiceProvider.notifier);
    final upcoming = player.currentIndex >= 0
        ? player.queue
            .skip(player.currentIndex + 1)
            .take(12)
            .toList()
        : const [];
    if (upcoming.isEmpty) {
      return const Center(
        child: Text(
            'Queue ends here — enable Mix radio from any track.',
            style: LwType.caption),
      );
    }
    return ListView(
      children: [
        const EdLedgerHeader(metaLabel: ''),
        ...upcoming.asMap().entries.map((e) {
          final t = e.value;
          return TrackTile(
            index: e.key + 1,
            title: t.title,
            subtitle: t.artist,
            artworkUrl: t.artworkUrl,
            onTap: () => notifier.seekToQueueItem(
                player.currentIndex + 1 + e.key),
            menu: trackMenuItems(
              ref: ref,
              title: t.title,
              artist: t.artist,
              artworkUrl: t.artworkUrl,
              videoId: t.videoId,
              playable: t,
            ),
          );
        }),
      ],
    );
  }
}
