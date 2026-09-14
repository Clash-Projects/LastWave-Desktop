import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/track_actions.dart';
import '../../design_system/components.dart';
import '../../design_system/icons.dart';
import '../../design_system/tokens.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/section.dart';
import '../../widgets/skeletons.dart';
import '../../widgets/toast.dart';
import '../../widgets/track_tile.dart';
import '../feed/feed_repository.dart';
import '../library/playlists.dart';
import '../player/playback_service.dart';

final _mixProvider = FutureProvider.autoDispose
    .family<List<GeneratedTrack>, ({int total, int nonce})>(
        (ref, args) {
  return ref
      .watch(feedRepositoryProvider)
      .fetchMix(total: args.total);
});

/// Editorial Mix Lab: masthead + inline size segments + ledger rows.
/// Replaces boxed controls + card list with flat lab ledger.
class GenerateScreen extends ConsumerStatefulWidget {
  const GenerateScreen({super.key});
  @override
  ConsumerState<GenerateScreen> createState() =>
      _GenerateScreenState();
}

class _GenerateScreenState
    extends ConsumerState<GenerateScreen> {
  int _total = 32;
  int _nonce = 0;
  final _filter = TextEditingController();
  String _q = '';

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final data =
        ref.watch(_mixProvider((total: _total, nonce: _nonce)));
    final likedKeys = ref
        .watch(playlistRepositoryProvider.notifier)
        .likedKeys();
    final playingKey =
        ref.watch(playbackServiceProvider.select((s) => s.current?.queueKey));
    return ListView(
      padding: const EdgeInsets.fromLTRB(
          LwSpacing.xl, LwSpacing.lg, LwSpacing.xl, 96),
      children: [
        EdPage(
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              CollectionHeader(
                kicker: 'Lab',
                title: 'Mix Lab',
                meta:
                    'A fresh $_total-track mix from your taste — obsessions, staples, discovery branches.',
                fallbackIcon:
                    LucideIcons.wandSparkles,
                artworkSize: 96,
                primaryActions: [
                  EdSegmented<int>(
                    value: _total,
                    options: const [
                      (24, '24'),
                      (32, '32'),
                      (40, '40'),
                    ],
                    onChanged: (n) =>
                        setState(() => _total = n),
                  ),
                  LwButton.outline(
                    onPressed: () =>
                        setState(() => _nonce++),
                    leading: const Icon(
                        LucideIcons.refreshCw,
                        size: 14),
                    child:
                        const Text('Regenerate'),
                  ),
                ],
              ),
              const SizedBox(height: LwSpacing.md),
              data.when(
                loading: () =>
                    const SkeletonRow(count: 10),
                error: (e, _) => EmptyState(
                  icon: LucideIcons.cloudOff,
                  title: 'Mix failed',
                  subtitle: e.toString(),
                  actionLabel: 'Retry',
                  onAction: () =>
                      setState(() => _nonce++),
                ),
                data: (all) {
                  final tracks = all
                      .where((t) => '${t.name} ${t.artist}'
                          .toLowerCase()
                          .contains(
                              _q.toLowerCase()))
                      .toList();
                  if (all.isEmpty) {
                    return const EmptyState(
                      icon: LucideIcons.wandSparkles,
                      title: 'No mix yet',
                      subtitle:
                          'Connect Last.fm or play more music first.',
                    );
                  }
                  return Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          LwButton(
                            onPressed: () =>
                                playGenerated(
                              ref,
                              context,
                              tracks.isNotEmpty
                                  ? tracks.first
                                  : all.first,
                              sourceLabel: 'Mix Lab',
                              queueAll: tracks.isNotEmpty
                                  ? tracks
                                  : all,
                            ),
                            leading: const Icon(
                                LucideIcons.play,
                                size: 14),
                            child: const Text(
                                'Play mix'),
                          ),
                          const SizedBox(
                              width: LwSpacing.xs),
                          TextButton(
                            onPressed: () =>
                                _saveAsPlaylist(all),
                            child: const Text(
                                'Save as playlist'),
                          ),
                          const Spacer(),
                          SizedBox(
                            width: 200,
                            height: 34,
                            child: TextField(
                              controller: _filter,
                              onChanged: (v) =>
                                  setState(
                                      () => _q = v),
                              style: LwType.body,
                              decoration:
                                  InputDecoration(
                                hintText:
                                    'Filter mix…',
                                prefixIcon: Icon(
                                    LucideIcons
                                        .search,
                                    size: 13,
                                    color: dark
                                        ? LwColors
                                            .textTertiary
                                        : LwColors
                                            .lightTextTertiary),
                                isDense: true,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(
                          height: LwSpacing.xs),
                      const EdLedgerHeader(
                          metaLabel: ''),
                      ...tracks
                          .asMap()
                          .entries
                          .map((e) {
                        final t = e.value;
                        return TrackTile(
                          index: e.key + 1,
                          title: t.name,
                          subtitle: t.artist,
                          artworkUrl: t.artworkUrl,
                          playing:
                              playingKey == t.key,
                          showLike: true,
                          isLiked: likedKeys
                              .contains(t.key),
                          onToggleLike: () =>
                              toggleLike(
                            ref,
                            context,
                            title: t.name,
                            artist: t.artist,
                            artworkUrl:
                                t.artworkUrl,
                            videoId: t.videoId,
                          ),
                          onTap: () =>
                              playGenerated(
                                  ref, context, t,
                                  sourceLabel:
                                      'Mix Lab',
                                  queueAll: tracks,
                                  startIndex: e.key),
                          menu: trackMenuItems(
                            ref: ref,
                            title: t.name,
                            artist: t.artist,
                            artworkUrl: t.artworkUrl,
                            videoId: t.videoId,
                          ),
                        );
                      }),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _saveAsPlaylist(
      List<GeneratedTrack> tracks) async {
    final created = await ref
        .read(playlistRepositoryProvider.notifier)
        .createCustom(
            'Mix · ${DateTime.now().day}/${DateTime.now().month}');
    final notifier =
        ref.read(playlistRepositoryProvider.notifier);
    for (final t in tracks) {
      await notifier.addTrack(
        created.id,
        StoredTrack(
          name: t.name,
          artist: t.artist,
          artworkUrl: t.artworkUrl,
          videoId: t.videoId,
        ),
      );
    }
    if (mounted) {
      showToast(context,
          'Saved ${tracks.length} tracks to ${created.title}.');
    }
  }
}
