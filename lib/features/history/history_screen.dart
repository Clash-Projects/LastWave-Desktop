import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../design_system/icons.dart';

import '../../app/track_actions.dart';
import '../../design_system/components.dart';
import '../../design_system/tokens.dart';
import '../feed/feed_repository.dart' show GeneratedTrack;
import '../home/home_screen.dart' show playGenerated;
import '../lastfm/home_repository.dart';
import '../player/playback_service.dart';

final _historyProvider = FutureProvider.autoDispose<List<HomeTrack>>(
    (ref) {
  final viewing = ref.watch(viewingProfileProvider);
  return ref
      .watch(homeRepositoryProvider)
      .fetchRecentTracks(viewingAs: viewing, limit: 50);
});

/// Listening history (Last.fm recent tracks).
class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(_historyProvider);
    return history.when(
      loading: () => ListView(
        padding: const EdgeInsets.all(LwSpacing.lg),
        children: const [
          SkeletonBox(width: 200, height: 26),
          SizedBox(height: 16),
          SkeletonRow(count: 10),
        ],
      ),
      error: (e, _) => EmptyState(
        icon: LwIcons.cloudOff,
        title: 'Could not load history',
        subtitle: e.toString(),
        actionLabel: 'Retry',
        onAction: () => ref.invalidate(_historyProvider),
      ),
      data: (tracks) => ListView(
        padding: const EdgeInsets.fromLTRB(
            LwSpacing.lg, LwSpacing.lg, LwSpacing.lg, 96),
        children: [
          const Text('History',
              style: LwType.display),
          const SizedBox(height: LwSpacing.sm),
          if (tracks.isEmpty)
            const EmptyState(
              icon: LwIcons.history,
              title: 'No history yet',
              subtitle:
                'Scrobbled tracks will appear here once you connect Last.fm.',
            )
          else
            ...tracks.map((t) {
              final playing = ref
                      .watch(playbackServiceProvider)
                      .current
                      ?.queueKey ==
                  t.key;
              final when =
                  t.timestampMillis == null
                      ? ''
                      : relativeTime(
                          DateTime.fromMillisecondsSinceEpoch(
                              t.timestampMillis!));
              return TrackTile(
                title: t.name,
                subtitle: t.artist,
                artworkUrl: t.artworkUrl,
                trailing: when,
                playing: playing,
                onTap: () => playGenerated(
                  ref,
                  context,
                  GeneratedTrack(
                    name: t.name,
                    artist: t.artist,
                    artworkUrl: t.artworkUrl,
                  ),
                  sourceLabel: 'History',
                ),
              );
            }),
        ],
      ),
    );
  }
}
