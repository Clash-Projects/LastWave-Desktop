import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

import '../../app/track_actions.dart';
import '../../design_system/components.dart';
import '../../design_system/icons.dart';
import '../../design_system/tokens.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/skeletons.dart';
import '../../widgets/track_tile.dart';
import '../feed/feed_repository.dart';
import '../lastfm/home_repository.dart';
import '../library/playlists.dart';
import '../player/playback_service.dart';

final _historyProvider = FutureProvider.autoDispose<List<HomeTrack>>(
    (ref) {
  final viewing = ref.watch(viewingProfileProvider);
  return ref
      .watch(homeRepositoryProvider)
      .fetchRecentTracks(viewingAs: viewing, limit: 100);
});

/// Editorial history: masthead + time-ledger rows.
/// Replaces boxed list with indexed time ledger.
class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(_historyProvider);
    return history.when(
      loading: () => ListView(
        padding: const EdgeInsets.all(LwSpacing.xl),
        children: const [
          SkeletonBox(width: 200, height: 26),
          SizedBox(height: LwSpacing.md),
          SkeletonRow(count: 10),
        ],
      ),
      error: (e, _) => EmptyState(
        icon: LucideIcons.cloudOff,
        title: 'Could not load history',
        subtitle: e.toString(),
        actionLabel: 'Retry',
        onAction: () => ref.invalidate(_historyProvider),
      ),
      data: (tracks) {
        final likedKeys = ref
            .watch(playlistRepositoryProvider.notifier)
            .likedKeys();
        final playingKey = ref
            .watch(playbackServiceProvider.select((s) => s.current?.queueKey));
        final groups = <String, List<int>>{};
        for (var i = 0; i < tracks.length; i++) {
          final t = tracks[i];
          final dt = t.timestampMillis == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(
                  t.timestampMillis!);
          final g = _dayGroup(dt);
          (groups[g] ??= []).add(i);
        }
        final ordered = [
          if (groups.containsKey('Today')) 'Today',
          if (groups.containsKey('Yesterday')) 'Yesterday',
          if (groups.containsKey('Earlier')) 'Earlier',
        ];
        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                    LwSpacing.xl,
                    LwSpacing.lg,
                    LwSpacing.xl,
                    LwSpacing.sm),
                child: EdPage(
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      const EdKicker('Last.fm'),
                      const Text('History',
                          style: LwType.display),
                      const SizedBox(height: 4),
                      Text(
                          '${tracks.length} scrobbles · most recent first',
                          style: LwType.body.copyWith(
                              color: LwColors
                                  .textSecondary)),
                      const SizedBox(
                          height: LwSpacing.sm),
                      const EdLedgerHeader(
                          metaLabel: 'Played'),
                    ],
                  ),
                ),
              ),
            ),
            if (tracks.isEmpty)
              const SliverToBoxAdapter(
                child: EmptyState(
                  icon: LucideIcons.history,
                  title: 'No history yet',
                  subtitle:
                      'Scrobbled tracks will appear here once you connect Last.fm.',
                ),
              )
            else
              for (final g in ordered) ...[
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                        LwSpacing.xl, LwSpacing.sm,
                        LwSpacing.xl, 2),
                    child: Text(g,
                        style: LwType.title.copyWith(
                            fontSize: 13,
                            fontWeight:
                                FontWeight.w700)),
                  ),
                ),
                SuperSliverList.builder(
                  itemCount: groups[g]!.length,
                  itemBuilder: (context, j) {
                    final i = groups[g]![j];
                    final t = tracks[i];
                  final when = t.timestampMillis == null
                      ? ''
                      : relativeTime(
                          DateTime
                              .fromMillisecondsSinceEpoch(
                                  t.timestampMillis!));
                  return Padding(
                    padding: const EdgeInsets
                        .symmetric(
                            horizontal:
                                LwSpacing.lg),
                    child: TrackTile(
                      index: i + 1,
                      title: t.name,
                      subtitle: t.artist,
                      artworkUrl: t.artworkUrl,
                      meta: when,
                      playing: playingKey == t.key,
                      showLike: true,
                      isLiked:
                          likedKeys.contains(t.key),
                      onToggleLike: () => toggleLike(
                        ref,
                        context,
                        title: t.name,
                        artist: t.artist,
                        artworkUrl: t.artworkUrl,
                      ),
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
                      menu: trackMenuItems(
                        ref: ref,
                        title: t.name,
                        artist: t.artist,
                        artworkUrl: t.artworkUrl,
                      ),
                    ),
                  );
                },
              ),
              ],
            const SliverToBoxAdapter(
                child: SizedBox(height: 96)),
          ],
        );
      },
    );
  }
}

String _dayGroup(DateTime? dt) {
  if (dt == null) return 'Earlier';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(dt.year, dt.month, dt.day);
  final diff = today.difference(day).inDays;
  if (diff <= 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  return 'Earlier';
}
