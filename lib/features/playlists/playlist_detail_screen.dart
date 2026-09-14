import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

import '../../app/track_actions.dart';
import '../../design_system/components.dart';
import '../../design_system/icons.dart';
import '../../design_system/tokens.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/section.dart';
import '../../widgets/track_tile.dart';
import '../downloads/download_manager.dart';
import '../feed/feed_repository.dart';
import '../library/library_screen.dart'
    show renamePlaylistDialog, deletePlaylistDialog;
import '../library/playlists.dart';
import '../player/playback_service.dart';

/// Editorial playlist detail: masthead ledger (144 art + kicker +
/// title + meta + Play primary / Shuffle ghost / overflow) + filter +
/// indexed ledger rows.
///
/// Replaces 120-art header + row of equally prominent outlined buttons
/// (Play/Rename/Pin/Delete) with prioritized actions.
class PlaylistDetailScreen extends ConsumerStatefulWidget {
  final int id;
  const PlaylistDetailScreen(
      {super.key, required this.id});
  @override
  ConsumerState<PlaylistDetailScreen> createState() =>
      _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState
    extends ConsumerState<PlaylistDetailScreen> {
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
    final playlist =
        playlists.where((p) => p.id == widget.id).firstOrNull;
    if (playlist == null) {
      return EmptyState(
        icon: LucideIcons.listMusic,
        title: 'Playlist not found',
        subtitle: 'It may have been deleted.',
        actionLabel: 'Back to playlists',
        onAction: () => context.go('/playlists'),
      );
    }
    final all = playlist.tracks;
    final tracks = all
        .where((t) => '${t.name} ${t.artist}'
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
                    kicker:
                        'Collect · Playlist${playlist.isPinned ? ' · Pinned' : ''}',
                    title: playlist.title,
                    meta:
                        '${all.length} tracks${_q.isNotEmpty ? ' · ${tracks.length} match' : ''}',
                    artworkUrl: cover,
                    fallbackIcon:
                        LucideIcons.listMusic,
                    primaryActions: [
                      if (tracks.isNotEmpty)
                        LwButton(
                          onPressed: () =>
                              playGenerated(
                            ref,
                            context,
                            asGenerated().first,
                            sourceLabel:
                                playlist.title,
                            queueAll: asGenerated(),
                          ),
                          leading: const Icon(
                              LucideIcons.play,
                              size: 14),
                          child:
                              const Text('Play all'),
                        ),
                      if (tracks.isNotEmpty)
                        LwButton.outline(
                          onPressed: () {
                            // Shuffle BEFORE picking first.
                            final shuffled =
                                asGenerated()
                                  ..shuffle();
                            playGenerated(
                              ref,
                              context,
                              shuffled.first,
                              sourceLabel:
                                  playlist.title,
                              queueAll: shuffled,
                            );
                          },
                          child:
                              const Text('Shuffle'),
                        ),
                      if (tracks.isNotEmpty)
                        LwButton.outline(
                          onPressed: () {
                            final manager = ref.read(
                                downloadManagerProvider
                                    .notifier);
                            for (final t
                                in asGenerated()) {
                              manager.downloadTrack(
                                title: t.name,
                                artist: t.artist,
                                artworkUrl: t.artworkUrl,
                              );
                            }
                          },
                          child: const Text(
                              'Download all'),
                        ),
                    ],
                    overflow: [
                      LwMenuItem(
                        label: playlist.isPinned
                            ? 'Unpin'
                            : 'Pin',
                        icon: playlist.isPinned
                            ? LucideIcons.pinOff
                            : LucideIcons.pin,
                        onSelected: () => ref
                            .read(
                                playlistRepositoryProvider
                                    .notifier)
                            .setPinned(playlist.id,
                                !playlist.isPinned),
                      ),
                      LwMenuItem(
                        label: 'Rename',
                        icon: LucideIcons.pencil,
                        onSelected: () =>
                            renamePlaylistDialog(
                                context,
                                ref,
                                playlist),
                      ),
                      if (!playlist.isLikedSongs)
                        LwMenuItem(
                          label: 'Delete',
                          icon: LucideIcons.trash2,
                          destructive: true,
                          onSelected: () =>
                              deletePlaylistDialog(
                                  context,
                                  ref,
                                  playlist),
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
                        'Filter in playlist…',
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
          SliverToBoxAdapter(
            child: EmptyState(
              icon: LucideIcons.listMusic,
              title: _q.isEmpty
                  ? 'Empty playlist'
                  : 'No matches',
              subtitle: _q.isEmpty
                  ? 'Add tracks from any menu.'
                  : 'Try a different filter.',
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
                  isLiked:
                      likedKeys.contains(t.key),
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
                      sourceLabel: playlist.title,
                      queueAll: asGenerated(),
                      startIndex: i),
                  menu: [
                    ...trackMenuItems(
                      ref: ref,
                      title: t.name,
                      artist: t.artist,
                      artworkUrl: t.artworkUrl,
                      videoId: t.videoId,
                    ),
                    TrackMenuItem(
                      label:
                          'Remove from playlist',
                      icon: LucideIcons.trash2,
                      onSelected: () => ref
                          .read(playlistRepositoryProvider
                              .notifier)
                          .removeTrack(
                              playlist.id, t.key),
                    ),
                  ],
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
