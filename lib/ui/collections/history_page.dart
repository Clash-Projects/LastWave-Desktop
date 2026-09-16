import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

import '../../app/track_actions.dart'
    show playGenerated, relativeTime;
import '../../features/feed/feed_repository.dart';
import '../../features/lastfm/home_repository.dart';
import '../../features/player/playback_service.dart';
import '../components/states.dart';
import '../components/track_row.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';

final _waveHistoryProvider =
    FutureProvider<List<HomeTrack>>((ref) {
  final viewing = ref.watch(viewingProfileProvider);
  return ref
      .watch(homeRepositoryProvider)
      .fetchRecentTracks(viewingAs: viewing, limit: 100);
});

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

/// History: LAST.FM overline + count header + date groups
/// (Today / Yesterday / Earlier) with relative timestamps.
class WaveHistoryPage extends ConsumerWidget {
  const WaveHistoryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(_waveHistoryProvider);
    return history.when(
      loading: () => const WaveLoading(
        label: 'Loading history…',
      ),
      error: (e, _) => WaveError(
        title: 'Could not load history',
        message: '$e',
        onRetry: () =>
            ref.invalidate(_waveHistoryProvider),
      ),
      data: (tracks) {
        final playingKey = ref.watch(
          playbackServiceProvider.select(
            (s) => s.current?.queueKey,
          ),
        );
        // Group by date, preserving order.
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
        final orderedGroups = [
          if (groups.containsKey('Today')) 'Today',
          if (groups.containsKey('Yesterday'))
            'Yesterday',
          if (groups.containsKey('Earlier')) 'Earlier',
        ];
        return WaveEntranceGroup(
          child: CustomScrollView(
            slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  24,
                  20,
                  24,
                  4,
                ),
                child: WaveEntrance(
                  rise: 10,
                  child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    Text(
                      'LAST.FM',
                      style: WaveType.overline.copyWith(
                        color: waveAccent(context),
                      ),
                    ),
                    const Text(
                      'History',
                      style: WaveType.pageTitle,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${tracks.length} scrobbles · most recent first',
                      style: WaveType.body.copyWith(
                        color: waveTextSecondary(context),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const WaveTrackTableHeader(
                      showAlbum: false,
                    ),
                  ],
                  ),
                ),
              ),
            ),
            if (tracks.isEmpty)
              const SliverToBoxAdapter(
                child: WaveEmpty(
                  icon: FluentIcons.history,
                  title: 'No history yet',
                  subtitle:
                      'Scrobbled tracks will appear here once you connect Last.fm.',
                ),
              )
            else
              for (final g in orderedGroups) ...[
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                        24, 12, 24, 2),
                    child: WaveEntrance(
                      index: groups[g]!.first,
                      rise: 8,
                      child: Text(g,
                          style: WaveType.sectionTitle
                              .copyWith(fontSize: 13)),
                    ),
                  ),
                ),
                SuperSliverList.builder(
                  itemCount: groups[g]!.length,
                  itemBuilder: (context, j) {
                    final i = groups[g]![j];
                    final t = tracks[i];
                    final when = t.timestampMillis ==
                            null
                        ? ''
                        : relativeTime(
                            DateTime
                                .fromMillisecondsSinceEpoch(
                              t.timestampMillis!,
                            ),
                          );
                    return WaveEntrance(
                      index: i,
                      rise: 10,
                      child: Padding(
                      padding:
                          const EdgeInsets.symmetric(
                        horizontal: 16,
                      ),
                      child: WaveTrackRow(
                        index: i + 1,
                        title: t.name,
                        artist: t.artist,
                        artworkUrl: t.artworkUrl,
                        meta: when,
                        playing: playingKey == t.key,
                        isCurrent: playingKey == t.key,
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
                      ),
                      ),
                    );
                  },
                ),
              ],
            const SliverToBoxAdapter(
              child: SizedBox(height: 24),
            ),
            ],
          ),
        );
      },
    );
  }
}
