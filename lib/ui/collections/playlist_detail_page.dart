import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/track_actions.dart'
    show formatDuration, playGenerated, playableFromGenerated;
import '../../features/downloads/download_manager.dart';
import '../../features/feed/feed_repository.dart';
import '../../features/library/playlist_file.dart';
import '../../features/library/playlists.dart';
import '../../core/storage/prefs.dart';
import '../../features/player/playback_service.dart';
import '../components/buttons.dart' show LWTooltip, WaveGhostButton, WaveIconButton, WavePrimaryButton;
import '../components/desktop_table.dart';
import '../components/hero.dart';
import '../components/menus.dart';
import '../components/select.dart';
import '../components/states.dart';
import 'playlist_dialogs.dart'
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
  late String _sort;
  late bool _asc;

  @override
  void initState() {
    super.initState();
    final saved = ref.read(prefsProvider).playlistSort(widget.id).split(':');
    _sort = saved.first;
    _asc = saved.last != 'desc';
  }

  void _setSort(String sort, bool asc) {
    setState(() {
      _sort = sort;
      _asc = asc;
    });
    ref
        .read(prefsProvider)
        .setPlaylistSort(widget.id, '$sort:${asc ? 'asc' : 'desc'}');
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  Future<void> _export(SavedPlaylist playlist, {required bool csv}) async {
    final rows = [
      for (final t in playlist.tracks)
        PlaylistFileRow(
          title: t.name,
          artist: t.artist,
          album: t.album.isEmpty ? null : t.album,
          videoId: t.videoId.isEmpty ? null : t.videoId,
        ),
    ];
    final safe = playlist.title
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .trim();
    final base = safe.isEmpty ? 'playlist' : safe;
    await FilePicker.saveFile(
      dialogTitle: csv ? 'Export CSV' : 'Export M3U',
      fileName: '$base.${csv ? 'csv' : 'm3u'}',
      bytes: utf8.encode(
        csv
            ? exportPlaylistCsv(rows)
            : exportPlaylistM3u(playlist.title, rows),
      ),
      type: FileType.custom,
      allowedExtensions: [csv ? 'csv' : 'm3u'],
    );
  }

  Future<void> _changeCover(SavedPlaylist playlist) async {
    final file = await FilePicker.pickFile(
      dialogTitle: 'Playlist cover',
      type: FileType.image,
    );
    final path = file?.path;
    if (path == null || path.isEmpty) return;
    await ref
        .read(playlistRepositoryProvider.notifier)
        .setCustomCover(playlist.id, path);
  }

  @override
  Widget build(BuildContext context) {
    final playlists = ref.watch(playlistRepositoryProvider);
    final playlist =
        playlists.where((p) => p.id == widget.id).firstOrNull;
    if (playlist == null) {
      return WaveEmpty(
        icon: WaveIcons.playlists,
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
    if (_sort == 'added') {
      tracks.sort((a, b) {
        if (a.addedAtMillis == 0 && b.addedAtMillis == 0) return 0;
        if (a.addedAtMillis == 0) return 1;
        if (b.addedAtMillis == 0) return -1;
        return b.addedAtMillis.compareTo(a.addedAtMillis);
      });
    } else if (_sort == 'title') {
      tracks.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    } else if (_sort == 'artist') {
      tracks.sort(
          (a, b) => a.artist.toLowerCase().compareTo(b.artist.toLowerCase()));
    }
    // Reverses whichever sort is active (custom order, date, title, artist).
    if (!_asc) tracks = tracks.reversed.toList();
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
            album: t.album,
            artworkUrl: t.artworkUrl,
            videoId: t.videoId,
            durationSeconds: t.durationSeconds,
            playbackUrl: t.playbackUrl,
          ),
        )
        .toList();

    String cover = playlist.customCoverUri;
    if (cover.isEmpty) {
      for (final t in playlist.tracks) {
        if (t.artworkUrl.isNotEmpty) {
          cover = t.artworkUrl;
          break;
        }
      }
    }
    final downloadKeys = {
      for (final t in playlist.tracks)
        DownloadManager.keyOf(t.name, t.artist),
    };
    final downloading = ref.watch(downloadManagerProvider).any((entry) =>
        downloadKeys.contains(entry.key) &&
        (entry.status == DownloadStatus.downloading ||
            entry.status == DownloadStatus.queued));

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
                    flightKind: 'playlist',
                    flightId: '${playlist.id}',
                    overline:
                        'Playlist${playlist.isPinned ? ' · Pinned' : ''}',
                    title: playlist.title,
                    meta:
                        '${playlist.tracks.length} tracks${_q.isNotEmpty ? ' · ${tracks.length} match' : ''}',
                    artworkUrl: cover,
                    fallbackIcon:
                        WaveIcons.playlists,
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
                          label: downloading ? 'Cancel' : 'Download',
                          icon: downloading
                              ? FluentIcons.cancel
                              : FluentIcons.download,
                          onPressed: downloading
                              ? () {
                                  final manager = ref.read(
                                      downloadManagerProvider.notifier);
                                  for (final key in downloadKeys) {
                                    manager.cancelDownload(key);
                                  }
                                }
                              : () {
                                  final manager = ref.read(
                                      downloadManagerProvider.notifier);
                                  for (final t in asGenerated()) {
                                    if (t.playbackUrl.isNotEmpty) continue;
                                    manager.downloadTrack(
                                      title: t.name,
                                      artist: t.artist,
                                      album: t.album,
                                      artworkUrl: t.artworkUrl,
                                    );
                                  }
                                },
                        ),
                      ],
                    ],
                    overflowItems: [
                      WaveMenuAction(
                        leading: const Icon(FluentIcons.photo, size: 13),
                        label: 'Change cover',
                        onPressed: () => _changeCover(playlist),
                      ),
                      WaveMenuAction(
                        leading: const Icon(FluentIcons.page, size: 13),
                        label: 'Export CSV',
                        onPressed: () => _export(playlist, csv: true),
                      ),
                      WaveMenuAction(
                        leading: const Icon(FluentIcons.page, size: 13),
                        label: 'Export M3U',
                        onPressed: () => _export(playlist, csv: false),
                      ),
                      WaveMenuAction(
                        leading: const Icon(
                          FluentIcons.pin,
                          size: 13,
                        ),
                        label: playlist.isPinned
                            ? 'Unpin'
                            : 'Pin',
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
                      WaveMenuAction(
                        leading: const Icon(
                          FluentIcons.edit,
                          size: 13,
                        ),
                        label: 'Rename',
                        onPressed: () =>
                            showWaveRenamePlaylist(
                          context,
                          ref,
                          playlist,
                        ),
                      ),
                      if (!playlist.isLikedSongs)
                        WaveMenuAction(
                          leading: const Icon(
                            FluentIcons.delete,
                            size: 13,
                          ),
                          label: 'Delete',
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
                    sortSlot: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        LWTooltip(
                          message: 'Sort (also sortable via table headers)',
                          child: WaveSelect<String>(
                            value: _sort,
                            options: const [
                              WaveSelectOption(
                                  value: 'default', label: 'Default order'),
                              WaveSelectOption(
                                  value: 'added', label: 'Date added'),
                              WaveSelectOption(
                                  value: 'title', label: 'Title A–Z'),
                              WaveSelectOption(
                                  value: 'artist', label: 'Artist A–Z'),
                            ],
                            onChanged: (v) => _setSort(v, _asc),
                          ),
                        ),
                        const SizedBox(width: 4),
                        WaveIconButton(
                          tooltip: _asc ? 'Reverse order' : 'Normal order',
                          selected: !_asc,
                          icon: Icon(
                            _asc ? WaveIcons.sortUp : WaveIcons.sortDown,
                            size: 14,
                          ),
                          onPressed: () => _setSort(_sort, !_asc),
                        ),
                      ],
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
              icon: WaveIcons.playlists,
              title: 'Empty playlist',
              subtitle: 'Add tracks from any menu.',
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: WaveDesktopTable<GeneratedTrack>(
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
              sliver: true,
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
        const SliverToBoxAdapter(
          child: SizedBox(height: 24),
        ),
        ],
      ),
    );
  }
}



