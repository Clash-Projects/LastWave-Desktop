import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/track_actions.dart' show formatDuration;
import '../../core/audio/stream_models.dart';
import '../../core/storage/prefs.dart';
import '../../features/downloads/download_manager.dart';
import '../../features/khinsider/khinsider_client.dart';
import '../../features/khinsider/khinsider_parser.dart';
import '../../features/library/playlists.dart';
import '../../features/player/playback_service.dart';
import '../components/ambient.dart';
import '../components/artwork.dart';
import '../components/command_bar.dart';
import '../components/desktop_table.dart';
import '../components/menus.dart';
import '../components/skeletons.dart';
import '../components/states.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';

final _khAlbumProvider = FutureProvider.autoDispose.family<KhAlbum, String>((
  ref,
  id,
) {
  return ref.watch(khInsiderClientProvider).album(id);
});

/// KHInsider has no per-track artist: the album name stands in (tags, file
/// names, scrobbles), as on LastWave-Native.
PlayableTrack khPlayable(KhAlbum album, KhTrack t) => PlayableTrack(
  title: t.name,
  artist: album.name,
  album: album.name,
  artworkUrl: album.coverUrl ?? '',
  playbackUrl: KhInsiderParser.playbackUri(t.pagePath),
  duration: Duration(seconds: t.durationSeconds ?? 0),
);

/// Saves a KHInsider track as `<album>/NN. Title.<flac|mp3>`, tagged.
void downloadKhTrack(WidgetRef ref, PlayableTrack t, {int number = 0}) {
  final client = ref.read(khInsiderClientProvider);
  ref
      .read(downloadManagerProvider.notifier)
      .downloadTrack(
        title: t.title,
        artist: t.artist,
        album: t.album,
        artworkUrl: t.artworkUrl,
        directSource: () => client.resolveStream(t.playbackUrl),
        folder: t.album,
        fileName: number > 0
            ? '${number.toString().padLeft(2, '0')}. ${t.title}'
            : t.title,
        trackNumber: number,
      );
}

/// A KHInsider album: cover + platforms / year / type, FLAC or MP3, Play,
/// Shuffle, Download, Add to playlist, then the track table.
class WaveKhAlbumPage extends ConsumerStatefulWidget {
  final String albumId;
  const WaveKhAlbumPage({super.key, required this.albumId});

  @override
  ConsumerState<WaveKhAlbumPage> createState() => _WaveKhAlbumPageState();
}

class _WaveKhAlbumPageState extends ConsumerState<WaveKhAlbumPage> {
  @override
  Widget build(BuildContext context) {
    return ref
        .watch(_khAlbumProvider(widget.albumId))
        .when(
          loading: () => const Padding(
            padding: EdgeInsets.all(28),
            child: SkeletonRow(count: 8),
          ),
          error: (e, _) => WaveError(
            title: 'Could not load album',
            message: '$e',
            onRetry: () => ref.invalidate(_khAlbumProvider(widget.albumId)),
          ),
          data: _body,
        );
  }

  void _play(KhAlbum album, List<KhTrack> order, int index) {
    ref
        .read(playbackServiceProvider.notifier)
        .playQueue(
          [for (final t in order) khPlayable(album, t)],
          index,
          sourceLabel: album.name,
        );
  }

  List<WaveMenuEntry> _addAlbumToPlaylist(KhAlbum album) {
    final library = ref.read(playlistRepositoryProvider.notifier);
    final stored = [
      for (final t in album.tracks)
        StoredTrack(
          name: t.name,
          artist: album.name,
          artworkUrl: album.coverUrl ?? '',
          album: album.name,
          durationSeconds: t.durationSeconds ?? 0,
          playbackUrl: KhInsiderParser.playbackUri(t.pagePath),
        ),
    ];
    Future<void> addAll(int id) async {
      for (final t in stored) {
        await library.addTrack(id, t);
      }
    }

    final userPlaylists = ref
        .read(playlistRepositoryProvider)
        .where((p) => !p.isLikedSongs)
        .toList();
    return [
      WaveMenuSubmenu(
        leading: const Icon(FluentIcons.list_mirrored, size: 15),
        label: 'Add album to playlist',
        items: () => [
          for (final p in userPlaylists)
            WaveMenuAction(
              leading: const Icon(FluentIcons.list_mirrored, size: 15),
              label: p.title,
              onPressed: () => addAll(p.id),
            ),
          if (userPlaylists.isNotEmpty) const WaveMenuSeparator(),
          WaveMenuAction(
            leading: const Icon(FluentIcons.add, size: 15),
            label: 'New playlist "${album.name}"',
            onPressed: () async =>
                addAll((await library.createCustom(album.name)).id),
          ),
        ],
      ),
    ];
  }

  Widget _body(KhAlbum album) {
    final order = album.tracks;
    final art = album.coverUrl ?? '';
    final client = ref.read(khInsiderClientProvider);
    // Watched so the format switch below rebuilds the page.
    ref.watch(prefsProvider);
    final playingUrl = ref.watch(
      playbackServiceProvider.select((s) => s.current?.playbackUrl),
    );
    final isPlaying = ref.watch(
      playbackServiceProvider.select((p) => p.isPlaying),
    );
    final meta = [
      if (album.platforms.isNotEmpty) album.platforms.join(', '),
      if (album.year != null) album.year!,
      if (album.type != null) album.type!,
      if (album.publisher != null) album.publisher!,
      '${order.length} tracks',
    ].join(' • ');

    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'GAME SOUNDTRACK · KHINSIDER',
          style: WaveType.overline.copyWith(
            fontSize: 10,
            color: waveTextTertiary(context),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          album.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: WaveType.pageTitle.copyWith(fontSize: 28),
        ),
        const SizedBox(height: 4),
        Text(
          meta,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: WaveType.meta.copyWith(color: waveTextTertiary(context)),
        ),
        const SizedBox(height: 14),
        WaveCommandBar(
          onPlay: order.isEmpty ? null : () => _play(album, order, 0),
          onShuffle: order.isEmpty
              ? null
              : () => _play(album, List.of(order)..shuffle(), 0),
          onDownload: order.isEmpty
              ? null
              : () {
                  for (final t in order) {
                    downloadKhTrack(
                      ref,
                      khPlayable(album, t),
                      number: t.number ?? 0,
                    );
                  }
                },
          overflowItems: order.isEmpty ? const [] : _addAlbumToPlaylist(album),
          trailing: [
            // MP3 is always there; FLAC only on some albums.
            ComboBox<KhFormat>(
              value: album.hasFlac ? client.format : KhFormat.mp3,
              items: [
                for (final f in KhFormat.values)
                  if (f == KhFormat.mp3 || album.hasFlac)
                    ComboBoxItem(
                      value: f,
                      child: Text(f.extension.toUpperCase()),
                    ),
              ],
              onChanged: (f) async {
                if (f == null) return;
                await client.setFormat(f);
                if (mounted) setState(() {});
              },
            ),
          ],
        ),
      ],
    );

    return WaveEntranceGroup(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(28, 24, 28, 32),
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: WaveDensity.contentMax),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                WaveEntrance(
                  index: 0,
                  rise: 10,
                  child: WaveAmbientBand(
                    artworkUrl: art,
                    child: LayoutBuilder(
                      builder: (context, c) {
                        final narrow = c.maxWidth < 640;
                        final cover = WaveArtwork(
                          url: art,
                          size: narrow ? 180 : 200,
                          radius: WaveRadius.artwork,
                          title: album.name,
                          label: album.name,
                          kind: ArtworkKind.album,
                        );
                        return narrow
                            ? Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  cover,
                                  const SizedBox(height: 16),
                                  header,
                                ],
                              )
                            : Row(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  cover,
                                  const SizedBox(width: 22),
                                  Expanded(child: header),
                                ],
                              );
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                WaveEntrance(
                  index: 1,
                  rise: 10,
                  child: WaveDesktopTable<KhTrack>(
                    items: order,
                    keyOf: (t) => t.pagePath,
                    titleOf: (t) => t.name,
                    subtitleOf: (_) => album.name,
                    albumOf: (_) => album.name,
                    artworkOf: (_) => art,
                    artworkKind: ArtworkKind.album,
                    playableOf: (t) => khPlayable(album, t),
                    durationOf: (t) => (t.durationSeconds ?? 0) > 0
                        ? formatDuration(Duration(seconds: t.durationSeconds!))
                        : '',
                    titleSortOf: (t) => t.name.toLowerCase(),
                    durationSortOf: (t) => t.durationSeconds ?? 0,
                    isCurrent: (t) =>
                        playingUrl == KhInsiderParser.playbackUri(t.pagePath),
                    isPlaying: (t) =>
                        isPlaying &&
                        playingUrl == KhInsiderParser.playbackUri(t.pagePath),
                    showArtistColumn: false,
                    shrinkWrap: true,
                    menuBuilder: (ref, t) {
                      final playable = khPlayable(album, t);
                      return [
                        ...waveTrackMenuItems(
                          context: context,
                          ref: ref,
                          playable: playable,
                          title: playable.title,
                          artist: playable.artist,
                          artworkUrl: playable.artworkUrl,
                          album: playable.album,
                          durationSeconds: t.durationSeconds ?? 0,
                        ).where(
                          (e) =>
                              !(e is WaveMenuAction && e.label == 'Download'),
                        ),
                        const WaveMenuSeparator(),
                        WaveMenuAction(
                          leading: const Icon(FluentIcons.download, size: 15),
                          label: 'Download',
                          onPressed: () => downloadKhTrack(
                            ref,
                            playable,
                            number: t.number ?? 0,
                          ),
                        ),
                      ];
                    },
                    onPlay: (i) => _play(album, order, i),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
