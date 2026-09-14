import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/track_actions.dart';
import '../../design_system/components.dart';
import '../../design_system/icons.dart';
import '../../design_system/tokens.dart';
import '../../widgets/artwork.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/skeletons.dart';
import '../../widgets/track_tile.dart';
import '../feed/feed_repository.dart';
import '../lastfm/auth_repository.dart';
import '../lastfm/home_repository.dart';
import '../library/playlists.dart';

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

/// Editorial profile: masthead ledger + inline stat strip + underline
/// segments + ledger rows. Replaces stat cards + chip tabs + boxed rows.
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
    final dark = Theme.of(context).brightness == Brightness.dark;
    final auth = ref.watch(authRepositoryProvider);
    final viewing = ref.watch(viewingProfileProvider);
    final name =
        viewing ?? (auth.username.isEmpty ? null : auth.username);
    if (name == null) {
      return EmptyState(
        icon: LucideIcons.circleUserRound,
        title: 'Not connected',
        subtitle:
            'Connect Last.fm to see your profile, stats and friends.',
        actionLabel: 'Connect Last.fm',
        onAction: () => context.go('/welcome'),
      );
    }
    final stats = ref.watch(_statsProvider);
    final top = ref.watch(_topProvider(_period));
    final recent = ref.watch(_recentProvider);
    final likedKeys = ref
        .watch(playlistRepositoryProvider.notifier)
        .likedKeys();

    return ListView(
      padding: const EdgeInsets.fromLTRB(
          LwSpacing.xl, LwSpacing.lg, LwSpacing.xl, 96),
      children: [
        EdPage(
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (viewing != null)
                    LwIconButton(
                      tooltip: 'Back to my profile',
                      icon: const Icon(
                          LucideIcons.arrowLeft,
                          size: 17),
                      onPressed: () => ref
                          .read(viewingProfileProvider
                              .notifier)
                          .clear(),
                    ),
                  _ProfileAvatar(name: name),
                  const SizedBox(
                      width: LwSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        EdKicker(viewing != null
                            ? 'Friend · Last.fm'
                            : 'Your Last.fm profile'),
                        Text(name,
                            style: LwType.display
                                .copyWith(
                                    fontSize: 24)),
                      ],
                    ),
                  ),
                  if (viewing == null)
                    LwButton.outline(
                      onPressed: () =>
                          context.go('/friends'),
                      leading: const Icon(
                          LucideIcons.users,
                          size: 14),
                      child:
                          const Text('Friends'),
                    ),
                ],
              ),
              const SizedBox(height: LwSpacing.md),
              stats.when(
                loading: () => const Row(
                  children: [
                    Expanded(
                        child: SkeletonBox(
                            width: 120,
                            height: 48)),
                    SizedBox(width: LwSpacing.md),
                    Expanded(
                        child: SkeletonBox(
                            width: 120,
                            height: 48)),
                    SizedBox(width: LwSpacing.md),
                    Expanded(
                        child: SkeletonBox(
                            width: 120,
                            height: 48)),
                    SizedBox(width: LwSpacing.md),
                    Expanded(
                        child: SkeletonBox(
                            width: 120,
                            height: 48)),
                  ],
                ),
                error: (_, _) =>
                    const SizedBox.shrink(),
                data: (s) => Container(
                  padding:
                      const EdgeInsets.symmetric(
                          vertical: LwSpacing.sm),
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(
                          color: dark
                              ? LwColors.outlineSoft
                              : LwColors
                                  .lightOutlineSoft),
                      bottom: BorderSide(
                          color: dark
                              ? LwColors.outlineSoft
                              : LwColors
                                  .lightOutlineSoft),
                    ),
                  ),
                  child: Row(
                    children: [
                      _StatInline(
                          label: 'Scrobbles',
                          value: _compact(
                              s.scrobbles)),
                      _StatInline(
                          label: 'Artists',
                          value: _compact(
                              s.artistCount)),
                      _StatInline(
                          label: 'Albums',
                          value:
                              _compact(s.albumCount)),
                      _StatInline(
                          label: 'Tracks',
                          value:
                              _compact(s.trackCount),
                          last: true),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: LwSpacing.lg),
              Row(
                children: [
                  const Text('Top tracks',
                      style: LwType.headline),
                  const Spacer(),
                  EdSegmented<String>(
                    value: _period,
                    options: [
                      for (final p in _periods)
                        (p.$1, p.$2)
                    ],
                    onChanged: (p) =>
                        setState(() => _period = p),
                  ),
                ],
              ),
              const SizedBox(height: LwSpacing.xs),
              const EdLedgerHeader(
                  metaLabel: 'Plays'),
              top.when(
                loading: () =>
                    const SkeletonRow(count: 6),
                error: (e, _) => Text('Failed: $e',
                    style: LwType.caption),
                data: (tracks) => Column(
                  children: tracks
                      .asMap()
                      .entries
                      .map((e) {
                    final t = e.value;
                    return TrackTile(
                      index: e.key + 1,
                      title: t.name,
                      subtitle: t.artist,
                      artworkUrl: t.artworkUrl,
                      meta: '${t.playCount}',
                      showLike: true,
                      isLiked: likedKeys
                          .contains(t.key),
                      onToggleLike: () =>
                          toggleLike(
                        ref,
                        context,
                        title: t.name,
                        artist: t.artist,
                        artworkUrl: t.artworkUrl,
                      ),
                      onTap: () =>
                          playGenerated(
                        ref,
                        context,
                        GeneratedTrack(
                            name: t.name,
                            artist: t.artist,
                            artworkUrl:
                                t.artworkUrl),
                        sourceLabel:
                            'Top tracks',
                      ),
                      menu: trackMenuItems(
                        ref: ref,
                        title: t.name,
                        artist: t.artist,
                        artworkUrl: t.artworkUrl,
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
                loading: () =>
                    const SkeletonRow(count: 4),
                error: (_, _) =>
                    const SizedBox.shrink(),
                data: (tracks) => Column(
                  children: tracks
                      .map((t) => TrackTile(
                            title: t.name,
                            subtitle: t.artist,
                            artworkUrl: t.artworkUrl,
                            meta: t.timestampMillis ==
                                    null
                                ? null
                                : relativeTime(DateTime
                                    .fromMillisecondsSinceEpoch(
                                        t.timestampMillis!)),
                            onTap: () =>
                                playGenerated(
                              ref,
                              context,
                              GeneratedTrack(
                                  name: t.name,
                                  artist: t.artist,
                                  artworkUrl:
                                      t.artworkUrl),
                              sourceLabel: 'Recent',
                            ),
                            menu: trackMenuItems(
                              ref: ref,
                              title: t.name,
                              artist: t.artist,
                              artworkUrl: t.artworkUrl,
                            ),
                          ))
                      .toList(),
                ),
              ),
            ],
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

class _ProfileAvatar extends ConsumerWidget {
  final String name;
  const _ProfileAvatar({required this.name});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url =
        ref.watch(_statsProvider).valueOrNull?.avatarUrl ?? '';
    if (url.isEmpty) {
      return CircleAvatar(
        radius: 32,
        backgroundColor: LwColors.surfaceOverlay,
        child: Text(name[0].toUpperCase(),
            style: LwType.display),
      );
    }
    return Artwork(
        url: url, size: 64, radius: LwRadius.pill);
  }
}

class _StatInline extends StatelessWidget {
  final String label;
  final String value;
  final bool last;
  const _StatInline(
      {required this.label,
      required this.value,
      this.last = false});
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Expanded(
      child: Container(
        decoration: last
            ? null
            : BoxDecoration(
                border: Border(
                  right: BorderSide(
                      color: dark
                          ? LwColors.outlineSoft
                          : LwColors
                              .lightOutlineSoft),
                ),
              ),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            Text(value,
                style: LwType.headline.copyWith(
                    fontSize: 18,
                    fontFeatures: const [
                      FontFeature.tabularFigures()
                    ])),
            Text(label,
                style: LwType.caption.copyWith(
                    color: dark
                        ? LwColors.textTertiary
                        : LwColors
                            .lightTextTertiary)),
          ],
        ),
      ),
    );
  }
}
