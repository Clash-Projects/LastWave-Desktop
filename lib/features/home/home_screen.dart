import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../design_system/icons.dart';

import '../../app/track_actions.dart';
import '../../core/audio/stream_models.dart';
import '../../design_system/components.dart';
import '../../design_system/tokens.dart';
import '../feed/feed_repository.dart';
import '../player/playback_service.dart';

final _feedProvider = FutureProvider.autoDispose<FeedData>((ref) {
  return ref.watch(feedRepositoryProvider).loadFeed();
});

/// Desktop home: dense personalised feed with horizontal rails and
/// compact quick-pick rows. Mirrors Android feed sections.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(_feedProvider);
    return feed.when(
      loading: () => const _HomeSkeleton(),
      error: (e, _) => EmptyState(
        icon: LwIcons.cloudOff,
        title: 'Could not load your feed',
        subtitle: e.toString(),
        actionLabel: 'Retry',
        onAction: () => ref.invalidate(_feedProvider),
      ),
      data: (data) {
        if (data.isEmpty) {
          return EmptyState(
            icon: LwIcons.sparkles,
            title: 'Connect Last.fm for your mix',
            subtitle:
                'Charts and new releases will appear here meanwhile.',
            actionLabel: 'Open settings',
            onAction: () {},
          );
        }
        return RefreshIndicator(
          onRefresh: () async =>
              ref.invalidate(_feedProvider),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
                LwSpacing.lg, LwSpacing.lg, LwSpacing.lg, 96),
            children: [
              const Text('Good listening',
                  style: LwType.display),
              const SizedBox(height: 4),
              Text(
                'Picked from your taste profile, charts and fresh releases.',
                style: LwType.body.copyWith(
                    color: LwColors.textSecondary),
              ),
              const SizedBox(height: LwSpacing.lg),
              if (data.quickPicks.isNotEmpty) ...[
                const SectionHeader(title: 'Quick picks'),
                const SizedBox(height: LwSpacing.xs),
                _QuickPickGrid(tracks: data.quickPicks),
                const SizedBox(height: LwSpacing.lg),
              ],
              if (data.newReleases.isNotEmpty)
                _Rail(
                  title: 'New releases',
                  tracks: data.newReleases,
                ),
              if (data.heavyRotation.isNotEmpty)
                _Rail(
                  title: 'Heavy rotation',
                  tracks: data.heavyRotation,
                ),
              if (data.freshFinds.isNotEmpty)
                _Rail(
                  title: 'Fresh finds',
                  tracks: data.freshFinds,
                ),
              if (data.becauseYouListened.isNotEmpty)
                _Rail(
                  title: 'Because you listened',
                  tracks: data.becauseYouListened,
                ),
              if (data.jumpBackIn.isNotEmpty) ...[
                const SectionHeader(title: 'Jump back in'),
                const SizedBox(height: LwSpacing.xs),
                ...data.jumpBackIn
                    .take(6)
                    .map((t) => _FeedTrackRow(track: t)),
                const SizedBox(height: LwSpacing.lg),
              ],
              if (data.charts.isNotEmpty)
                _Rail(title: 'Trending now', tracks: data.charts),
            ],
          ),
        );
      },
    );
  }
}

Future<void> playGenerated(
  WidgetRef ref,
  BuildContext context,
  GeneratedTrack track, {
  String sourceLabel = 'Home',
  List<GeneratedTrack>? queueAll,
  int startIndex = 0,
}) async {
  final player = ref.read(playbackServiceProvider.notifier);
  List<GeneratedTrack> list = queueAll ?? [track];
  var index = queueAll == null ? 0 : startIndex;
  // Resolve missing videoIds (bounded).
  final repo = ref.read(feedRepositoryProvider);
  try {
    list = await repo.resolveVideos(list, limit: 40);
  } catch (_) {}
  final resolved = list[index];
  PlayableTrack playable = playableFromGenerated(resolved);
  if (playable.videoId.isEmpty) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('Could not resolve a playable stream.')),
    );
    return;
  }
  final queue =
      list.map(playableFromGenerated).toList();
  await player.playQueue(queue, index,
      sourceLabel: sourceLabel);
}

class _QuickPickGrid extends ConsumerWidget {
  final List<GeneratedTrack> tracks;
  const _QuickPickGrid({required this.tracks});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cols = constraints.maxWidth > 900 ? 3 : 2;
        final rows = (tracks.take(9).length / cols).ceil();
        return Column(
          children: List.generate(rows, (r) {
            return Row(
              children: List.generate(cols, (c) {
                final i = r * cols + c;
                if (i >= tracks.length || i >= 9) {
                  return const Expanded(child: SizedBox());
                }
                return Expanded(
                    child: _FeedTrackRow(
                        track: tracks[i],
                        queueAll: tracks,
                        index: i));
              }),
            );
          }),
        );
      },
    );
  }
}

class _FeedTrackRow extends ConsumerWidget {
  final GeneratedTrack track;
  final List<GeneratedTrack>? queueAll;
  final int index;
  const _FeedTrackRow({
    required this.track,
    this.queueAll,
    this.index = 0,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playbackServiceProvider);
    final playing = player.current?.queueKey == track.key &&
        player.isPlaying;
    return GestureDetector(
      onSecondaryTapDown: (d) => showTrackMenu(
        context: context,
        ref: ref,
        position: d.globalPosition,
        title: track.name,
        artist: track.artist,
        artworkUrl: track.artworkUrl,
        toPlayable: () => playableFromGenerated(track),
      ),
      child: TrackTile(
        title: track.name,
        subtitle: track.artist,
        artworkUrl: track.artworkUrl,
        playing: playing,
        onTap: () => playGenerated(ref, context, track,
            queueAll: queueAll ?? [track],
            startIndex: queueAll == null ? 0 : index),
        onMore: () {},
      ),
    );
  }
}

class _Rail extends ConsumerWidget {
  final String title;
  final List<GeneratedTrack> tracks;
  const _Rail({required this.title, required this.tracks});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: title,
          actionLabel: 'Play all',
          onAction: () {
            if (tracks.isNotEmpty) {
              playGenerated(ref, context, tracks.first,
                  sourceLabel: title,
                  queueAll: tracks,
                  startIndex: 0);
            }
          },
        ),
        const SizedBox(height: LwSpacing.xs),
        SizedBox(
          height: 208,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: tracks.length,
            separatorBuilder: (_, _) =>
                const SizedBox(width: 4),
            itemBuilder: (context, i) {
              final t = tracks[i];
              return MediaCard(
                title: t.name,
                subtitle: t.artist,
                artworkUrl: t.artworkUrl,
                onTap: () => playGenerated(ref, context, t,
                    sourceLabel: title,
                    queueAll: tracks,
                    startIndex: i),
              );
            },
          ),
        ),
        const SizedBox(height: LwSpacing.lg),
      ],
    );
  }
}

class _HomeSkeleton extends StatelessWidget {
  const _HomeSkeleton();
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(LwSpacing.lg),
      children: const [
        SkeletonBox(width: 280, height: 28),
        SizedBox(height: 8),
        SkeletonBox(width: 360, height: 14),
        SizedBox(height: 24),
        SkeletonRow(count: 8),
      ],
    );
  }
}
