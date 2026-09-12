import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../design_system/icons.dart';

import '../../app/track_actions.dart';
import '../../design_system/components.dart';
import '../../design_system/tokens.dart';
import '../feed/feed_repository.dart' show GeneratedTrack;
import '../home/home_screen.dart' show playGenerated;
import '../lastfm/auth_repository.dart';
import '../lastfm/home_repository.dart';

final _statsProvider =
    FutureProvider.autoDispose<HomeStats>((ref) {
  final viewing = ref.watch(viewingProfileProvider);
  return ref
      .watch(homeRepositoryProvider)
      .fetchStats(viewingAs: viewing);
});

final _topProvider = FutureProvider.autoDispose
    .family<List<HomeTrack>, String>((ref, period) {
  final viewing = ref.watch(viewingProfileProvider);
  return ref.watch(homeRepositoryProvider).fetchTopTracks(
      viewingAs: viewing, period: period, limit: 15);
});

final _recentProvider =
    FutureProvider.autoDispose<List<HomeTrack>>((ref) {
  final viewing = ref.watch(viewingProfileProvider);
  return ref
      .watch(homeRepositoryProvider)
      .fetchRecentTracks(viewingAs: viewing, limit: 10);
});

const _periods = [
  ('7day', 'Week'),
  ('1month', 'Month'),
  ('12month', 'Year'),
  ('overall', 'All time'),
];

/// Last.fm profile: stats, top tracks, recent — own or friend
/// (via [viewingProfileProvider]).
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});
  @override
  ConsumerState<ProfileScreen> createState() =>
      _ProfileScreenState();
}

class _ProfileScreenState
    extends ConsumerState<ProfileScreen> {
  String _period = '7day';

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authRepositoryProvider);
    final viewing = ref.watch(viewingProfileProvider);
    final name =
        viewing ?? (auth.username.isEmpty ? null : auth.username);
    final stats = ref.watch(_statsProvider);
    final top = ref.watch(_topProvider(_period));
    final recent = ref.watch(_recentProvider);

    if (name == null) {
      return EmptyState(
        icon: LwIcons.user,
        title: 'Not connected',
        subtitle:
            'Connect Last.fm to see your profile, stats and friends.',
        actionLabel: 'Connect Last.fm',
        onAction: () => context.go('/login'),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(
          LwSpacing.lg, LwSpacing.lg, LwSpacing.lg, 96),
      children: [
        Row(
          children: [
            if (viewing != null)
              IconButton(
                onPressed: () => ref
                    .read(viewingProfileProvider.notifier)
                    .clear(),
                icon: const Icon(LwIcons.arrowLeft,
                    size: 18),
                tooltip: 'Back to my profile',
              ),
            CircleAvatar(
              radius: 34,
              backgroundColor: LwColors.surfaceOverlay,
              backgroundImage:
                  stats.valueOrNull?.avatarUrl.isNotEmpty ==
                          true
                      ? NetworkImage(
                          stats.value!.avatarUrl)
                      : null,
              child: stats.valueOrNull?.avatarUrl
                          .isNotEmpty ==
                      true
                  ? null
                  : Text(name[0].toUpperCase(),
                      style: LwType.display),
            ),
            const SizedBox(width: LwSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  Text(name, style: LwType.display),
                  Text(
                    viewing != null
                        ? 'Friend · Last.fm'
                        : 'Your Last.fm profile',
                    style: LwType.body.copyWith(
                        color: LwColors.textSecondary),
                  ),
                ],
              ),
            ),
            if (viewing == null)
              OutlinedButton.icon(
                onPressed: () => context.go('/friends'),
                icon: const Icon(LwIcons.users,
                    size: 14),
                label: const Text('Friends'),
              ),
          ],
        ),
        const SizedBox(height: LwSpacing.lg),
        stats.when(
          loading: () => const SkeletonRow(count: 2),
          error: (_, _) => const SizedBox.shrink(),
          data: (s) => Row(
            children: [
              _Stat(
                  label: 'Scrobbles',
                  value: _compact(s.scrobbles)),
              _Stat(
                  label: 'Artists',
                  value: _compact(s.artistCount)),
              _Stat(
                  label: 'Albums',
                  value: _compact(s.albumCount)),
              _Stat(
                  label: 'Tracks',
                  value: _compact(s.trackCount)),
            ],
          ),
        ),
        const SizedBox(height: LwSpacing.lg),
        Row(
          children: [
            const Text('Top tracks',
                style: LwType.headline),
            const Spacer(),
            SegmentedButton<String>(
              segments: _periods
                  .map((p) => ButtonSegment(
                      value: p.$1, label: Text(p.$2)))
                  .toList(),
              selected: {_period},
              onSelectionChanged: (s) =>
                  setState(() => _period = s.first),
              style: SegmentedButton.styleFrom(
                textStyle: LwType.label,
                visualDensity: VisualDensity.compact,
              ),
            ),
          ],
        ),
        const SizedBox(height: LwSpacing.xs),
        top.when(
          loading: () => const SkeletonRow(count: 6),
          error: (e, _) => Text('Failed: $e',
              style: LwType.caption),
          data: (tracks) => Column(
            children: tracks.asMap().entries.map((e) {
              final t = e.value;
              return TrackTile(
                title: t.name,
                subtitle: t.artist,
                artworkUrl: t.artworkUrl,
                trailing: '${e.key + 1} · ${t.playCount}',
                onTap: () => playGenerated(
                  ref,
                  context,
                  GeneratedTrack(
                      name: t.name,
                      artist: t.artist,
                      artworkUrl: t.artworkUrl),
                  sourceLabel: 'Top tracks',
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: LwSpacing.lg),
        const Text('Recently played',
            style: LwType.headline),
        const SizedBox(height: LwSpacing.xs),
        recent.when(
          loading: () => const SkeletonRow(count: 4),
          error: (_, _) => const SizedBox.shrink(),
          data: (tracks) => Column(
            children: tracks.map((t) {
              final when = t.timestampMillis == null
                  ? ''
                  : relativeTime(
                      DateTime.fromMillisecondsSinceEpoch(
                          t.timestampMillis!));
              return TrackTile(
                title: t.name,
                subtitle: t.artist,
                artworkUrl: t.artworkUrl,
                trailing: when,
                onTap: () => playGenerated(
                  ref,
                  context,
                  GeneratedTrack(
                      name: t.name,
                      artist: t.artist,
                      artworkUrl: t.artworkUrl),
                  sourceLabel: 'Recent',
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  String _compact(int n) {
    if (n >= 1000000) {
      return '${(n / 1000000).toStringAsFixed(1)}M';
    }
    if (n >= 1000) {
      return '${(n / 1000).toStringAsFixed(1)}k';
    }
    return '$n';
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  const _Stat({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.all(LwSpacing.md),
        decoration: BoxDecoration(
          color: LwColors.surfaceRaised,
          borderRadius:
              BorderRadius.circular(LwRadius.md),
          border:
              Border.all(color: LwColors.outlineSoft),
        ),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            Text(value, style: LwType.headline),
            Text(label,
                style: LwType.caption.copyWith(
                    color: LwColors.textSecondary)),
          ],
        ),
      ),
    );
  }
}
