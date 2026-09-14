import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

import '../../app/track_actions.dart';
import '../../design_system/components.dart';
import '../../design_system/icons.dart';
import '../../design_system/tokens.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/section.dart';
import '../../widgets/track_tile.dart';
import '../feed/feed_repository.dart';
import '../library/playlists.dart';
import '../player/playback_service.dart';

/// Editorial Liked Songs: masthead ledger + filter + indexed ledger rows.
/// Replaces gradient tile header + boxed list with flat collection
/// hierarchy (kicker / title / meta / primary Play / ledger header).
class LikedScreen extends ConsumerStatefulWidget {
  const LikedScreen({super.key});
  @override
  ConsumerState<LikedScreen> createState() =>
      _LikedScreenState();
}

class _LikedScreenState
    extends ConsumerState<LikedScreen> {
  final _filter = TextEditingController();
  String _q = '';
  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playlists = ref.watch(playlistRepositoryProvider);
    final liked =
        playlists.where((p) => p.isLikedSongs).firstOrNull;
    final all = liked?.tracks ?? const [];
    final tracks = all
        .where((t) =>
            '${t.name} ${t.artist}'
                .toLowerCase()
                .contains(_q.toLowerCase()))
        .toList();
    final likedKeys = ref
        .watch(playlistRepositoryProvider.notifier)
        .likedKeys();
    final playingKey =
        ref.watch(playbackServiceProvider.select((s) => s.current?.queueKey));

    List<GeneratedTrack> asGenerated() => tracks
        .map((t) => GeneratedTrack(
              name: t.name,
              artist: t.artist,
              artworkUrl: t.artworkUrl,
              videoId: t.videoId,
            ))
        .toList();

    String cover = '';
    for (final t in all) {
      if (t.artworkUrl.isNotEmpty) {
        cover = t.artworkUrl;
        break;
      }
    }

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
                LwSpacing.xl, LwSpacing.lg, LwSpacing.xl, 0),
            child: EdPage(
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  CollectionHeader(
                    kicker: 'Collect · Playlist',
                    title: 'Liked Songs',
                    meta:
                        '${all.length} tracks${_q.isNotEmpty ? ' · ${tracks.length} match' : ''}',
                    artworkUrl: cover,
                    fallbackIcon: LucideIcons.heart,
                    primaryActions: [
                      if (tracks.isNotEmpty)
                        LwButton(
                          onPressed: () =>
                              playGenerated(
                            ref,
                            context,
                            asGenerated().first,
                            sourceLabel:
                                'Liked Songs',
                            queueAll: asGenerated(),
                          ),
                          leading: const Icon(
                              LucideIcons.play,
                              size: 14),
                          child:
                              const Text('Play all'),
                        ),
                      LwButton.outline(
                        onPressed: tracks.isEmpty
                            ? null
                            : () {
                                // Shuffle BEFORE picking first.
                                final shuffled =
                                    asGenerated()..shuffle();
                                playGenerated(
                                  ref,
                                  context,
                                  shuffled.first,
                                  sourceLabel:
                                      'Liked Songs',
                                  queueAll: shuffled,
                                );
                              },
                        child: const Text('Shuffle'),
                      ),
                    ],
                  ),
                  const SizedBox(
                      height: LwSpacing.md),
                  LedgerFilterBar(
                    controller: _filter,
                    onChanged: (v) =>
                        setState(() => _q = v),
                    hint:
                        'Filter liked songs…',
                    countLabel:
                        '${tracks.length} tracks',
                  ),
                  const SizedBox(
                      height: LwSpacing.xs),
                  const EdLedgerHeader(
                      metaLabel: ''),
                ],
              ),
            ),
          ),
        ),
        if (tracks.isEmpty)
          const SliverToBoxAdapter(
            child: EmptyState(
              icon: LucideIcons.heart,
              title: 'No liked songs yet',
              subtitle:
                  'Tap the heart on any track to save it here.',
            ),
          )
        else
          SuperSliverList.builder(
            itemCount: tracks.length,
            itemBuilder: (context, i) {
              final t = asGenerated()[i];
              return Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: LwSpacing.lg),
                child: TrackTile(
                  index: i + 1,
                  title: t.name,
                  subtitle: t.artist,
                  artworkUrl: t.artworkUrl,
                  playing: playingKey == t.key,
                  showLike: true,
                  isLiked: likedKeys.contains(t.key),
                  onToggleLike: () => toggleLike(
                    ref,
                    context,
                    title: t.name,
                    artist: t.artist,
                    artworkUrl: t.artworkUrl,
                    videoId: t.videoId,
                  ),
                  onTap: () => playGenerated(
                      ref, context, t,
                      sourceLabel: 'Liked Songs',
                      queueAll: asGenerated(),
                      startIndex: i),
                  menu: trackMenuItems(
                    ref: ref,
                    title: t.name,
                    artist: t.artist,
                    artworkUrl: t.artworkUrl,
                    videoId: t.videoId,
                  ),
                ),
              );
            },
          ),
        const SliverToBoxAdapter(
            child: SizedBox(height: 96)),
      ],
    );
  }
}
