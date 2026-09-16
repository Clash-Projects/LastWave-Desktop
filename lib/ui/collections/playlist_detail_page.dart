import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/track_actions.dart'
    show formatDuration, playGenerated, playableFromGenerated;
import '../../features/downloads/download_manager.dart';
import '../../features/feed/feed_repository.dart';
import '../../features/library/playlists.dart';
import '../../features/player/playback_service.dart';
import '../components/buttons.dart' show LWTooltip, WaveGhostButton, WavePrimaryButton;
import '../components/desktop_table.dart';
import '../components/hero.dart';
import '../components/states.dart';
import '../library/library_page.dart'
    show
        showWaveDeletePlaylist,
        showWaveRenamePlaylist;
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

/// Playlist detail: artwork hero + filter + indexed track table.
///
/// Play/Shuffle are prioritized; Pin/Rename/Delete live in overflow.
/// Multi-select is supported via Shift+click range (checkbox column
/// appears when selection is active).
class WavePlaylistDetailPage extends ConsumerStatefulWidget {
  final int id;
  const WavePlaylistDetailPage({super.key, required this.id});

  @override
  ConsumerState<WavePlaylistDetailPage> createState() =>
      _WavePlaylistDetailPageState();
}

class _WavePlaylistDetailPageState
    extends ConsumerState<WavePlaylistDetailPage> {
  final _filter = TextEditingController();
  String _q = '';
  String _sort = 'default';

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
      return WaveEmpty(
        icon: FluentIcons.list_mirrored,
        title: 'Playlist not found',
        subtitle: 'It may have been deleted.',
        actionLabel: 'Back to playlists',
        onAction: () => context.go('/playlists'),
      );
    }
    var tracks = playlist.tracks
        .where(
          (t) => '${t.name} ${t.artist}'
              .toLowerCase()
              .contains(_q.toLowerCase()),
        )
        .toList();
    if (_sort == 'title') {
      tracks.sort((a, b) => a.name.compareTo(b.name));
    } else if (_sort == 'artist') {
      tracks.sort((a, b) => a.artist.compareTo(b.artist));
    }
    // Note: Album/Duration sorts are intentionally omitted — local
    // playlist tracks carry no album or duration metadata.
    final playingKey = ref.watch(
      playbackServiceProvider.select((s) => s.current?.queueKey),
    );
    List<GeneratedTrack> asGenerated() => tracks
        .map(
          (t) => GeneratedTrack(
            name: t.name,
            artist: t.artist,
            artworkUrl: t.artworkUrl,
            videoId: t.videoId,
          ),
        )
        .toList();

    String cover = '';
    for (final t in playlist.tracks) {
      if (t.artworkUrl.isNotEmpty) {
        cover = t.artworkUrl;
        break;
      }
    }

    return WaveEntranceGroup(
      child: CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding:
                const EdgeInsets.fromLTRB(24, 20, 24, 0),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: WaveDensity.contentMax,
              ),
              child: WaveEntrance(
                rise: 10,
                child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  WaveCollectionHero(
                    overline:
                        'Playlist${playlist.isPinned ? ' · Pinned' : ''}',
                    title: playlist.title,
                    meta:
                        '${playlist.tracks.length} tracks${_q.isNotEmpty ? ' · ${tracks.length} match' : ''}',
                    artworkUrl: cover,
                    fallbackIcon:
                        FluentIcons.list_mirrored,
                    primaryActions: [
                      if (tracks.isNotEmpty) ...[
                        WavePrimaryButton(
                          label: 'Play all',
                          icon: FluentIcons.play,
                          onPressed: () => playGenerated(
                            ref,
                            context,
                            asGenerated().first,
                            sourceLabel: playlist.title,
                            queueAll: asGenerated(),
                          ),
                        ),
                        WaveGhostButton(
                          label: 'Shuffle',
                          icon: WaveIcons.shuffle,
                          onPressed: () {
                            // Shuffle BEFORE picking first.
                            final shuffled =
                                asGenerated()..shuffle();
                            playGenerated(
                              ref,
                              context,
                              shuffled.first,
                              sourceLabel: playlist.title,
                              queueAll: shuffled,
                            );
                          },
                        ),
                        WaveGhostButton(
                          label: 'Download',
                          icon: FluentIcons.download,
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
                        ),
                      ],
                    ],
                    overflowItems: [
                      MenuFlyoutItem(
                        leading: const Icon(
                          FluentIcons.pin,
                          size: 13,
                        ),
                        text: Text(
                          playlist.isPinned
                              ? 'Unpin'
                              : 'Pin',
                        ),
                        onPressed: () => ref
                            .read(
                              playlistRepositoryProvider
                                  .notifier,
                            )
                            .setPinned(
                              playlist.id,
                              !playlist.isPinned,
                            ),
                      ),
                      MenuFlyoutItem(
                        leading: const Icon(
                          FluentIcons.edit,
                          size: 13,
                        ),
                        text: const Text('Rename'),
                        onPressed: () =>
                            showWaveRenamePlaylist(
                          context,
                          ref,
                          playlist,
                        ),
                      ),
                      if (!playlist.isLikedSongs)
                        MenuFlyoutItem(
                          leading: const Icon(
                            FluentIcons.delete,
                            size: 13,
                          ),
                          text: const Text('Delete'),
                          onPressed: () =>
                              showWaveDeletePlaylist(
                            context,
                            ref,
                            playlist,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  WaveFilterBar(
                    controller: _filter,
                    onChanged: (v) =>
                        setState(() => _q = v),
                    hint: 'Filter in playlist…',
                    countLabel:
                        '${tracks.length} tracks',
                    sortSlot: LWTooltip(
                      message: 'Sort (also sortable via table headers)',
                      child: DropDownButton(
                        title: Text(
                          _sort == 'default'
                              ? 'Default order'
                              : (_sort == 'title'
                                  ? 'Title A–Z'
                                  : 'Artist A–Z'),
                        ),
                        items: [
                          MenuFlyoutItem(
                            text:
                                const Text('Default order'),
                            onPressed: () => setState(
                              () => _sort = 'default',
                            ),
                          ),
                          MenuFlyoutItem(
                            text:
                                const Text('Title A–Z'),
                            onPressed: () => setState(
                              () => _sort = 'title',
                            ),
                          ),
                          MenuFlyoutItem(
                            text:
                                const Text('Artist A–Z'),
                            onPressed: () => setState(
                              () => _sort = 'artist',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                ),
              ),
            ),
          ),
        ),
        if (tracks.isEmpty)
          const SliverToBoxAdapter(
            child: WaveEmpty(
              icon: FluentIcons.list_mirrored,
              title: 'Empty playlist',
              subtitle: 'Add tracks from any menu.',
            ),
          )
        else
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: WaveDesktopTable<GeneratedTrack>(
                items: asGenerated(),
                keyOf: (t) => t.key,
                titleOf: (t) => t.name,
                subtitleOf: (t) => t.artist,
                albumOf: (_) => '',
                artworkOf: (t) => t.artworkUrl,
                playableOf: playableFromGenerated,
                durationOf: (t) => t.durationSeconds > 0
                    ? formatDuration(
                        Duration(seconds: t.durationSeconds))
                    : '',
                durationSortOf: (t) => t.durationSeconds,
                titleSortOf: (t) => t.name.toLowerCase(),
                artistSortOf: (t) => t.artist.toLowerCase(),
                isCurrent: (t) => playingKey == t.key,
                isPlaying: (t) {
                  final playing = ref.watch(
                    playbackServiceProvider.select((p) => p.isPlaying),
                  );
                  return playingKey == t.key && playing;
                },
                showArtistColumn: true,
                shrinkWrap: true,
                selectable: true,
                removeLabel: 'Remove from playlist',
                onRemove: (i) => ref
                    .read(playlistRepositoryProvider.notifier)
                    .removeTrack(
                        playlist.id, asGenerated()[i].key),
                onPlay: (i) => playGenerated(
                  ref,
                  context,
                  asGenerated()[i],
                  sourceLabel: playlist.title,
                  queueAll: asGenerated(),
                  startIndex: i,
                ),
              ),
            ),
          ),
        const SliverToBoxAdapter(
          child: SizedBox(height: 24),
        ),
        ],
      ),
    );
  }
}



