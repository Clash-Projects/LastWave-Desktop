import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/track_actions.dart'
    show playGenerated, playableFromGenerated;
import '../../../features/downloads/download_manager.dart';
import '../../../features/feed/feed_repository.dart';
import '../../../features/innertube/innertube_api.dart';
import '../../../features/player/playback_service.dart';
import '../components/artwork.dart';
import '../components/buttons.dart' show WaveChip;
import '../components/command_bar.dart';
import '../components/desktop_table.dart';
import '../components/menus.dart';
import '../components/states.dart';
import '../theme/tokens.dart';

final _albumDetailProvider = FutureProvider.autoDispose
    .family<_AlbumDetail, String>((ref, browseId) async {
  final tube = ref.watch(innerTubeProvider);
  final songs = await tube.browseSongs(browseId, limit: 50);
  if (songs.isEmpty) throw Exception('Empty album');
  // Derive header from first track + artwork.
  String art = '';
  for (final s in songs) {
    if (s.artworkUrl.isNotEmpty) {
      art = s.artworkUrl;
      break;
    }
  }
  String artist = songs.first.artist;
  String album = songs.first.album.isNotEmpty
      ? songs.first.album
      : 'Album';
  return _AlbumDetail(
    title: album,
    artist: artist,
    artwork: art,
    tracks: songs
        .map((t) => GeneratedTrack(
            name: t.title,
            artist: t.artist.isNotEmpty ? t.artist : artist,
            artworkUrl:
                t.artworkUrl.isNotEmpty ? t.artworkUrl : art,
            videoId: t.videoId))
        .toList(),
  );
});

class _AlbumDetail {
  final String title;
  final String artist;
  final String artwork;
  final List<GeneratedTrack> tracks;
  const _AlbumDetail(
      {required this.title,
      required this.artist,
      required this.artwork,
      required this.tracks});
}

/// Serious album layout: 200px art + ALBUM overline + 28px title +
/// artist link + year•tracks•duration + quality badge + Play (primary) +
/// Shuffle + Download + More, then desktop track table with sort.
class WaveAlbumPage extends ConsumerStatefulWidget {
  final String browseId;
  final String fallbackTitle;
  final String fallbackArtist;
  final String fallbackArt;
  const WaveAlbumPage({
    super.key,
    required this.browseId,
    this.fallbackTitle = '',
    this.fallbackArtist = '',
    this.fallbackArt = '',
  });

  @override
  ConsumerState<WaveAlbumPage> createState() => _WaveAlbumPageState();
}

class _WaveAlbumPageState extends ConsumerState<WaveAlbumPage> {
  @override
  Widget build(BuildContext context) {
    final async = ref.watch(_albumDetailProvider(widget.browseId));
    return async.when(
      loading: () =>
          const WaveLoading(label: 'Loading album…'),
      error: (e, _) => WaveError(
        title: 'Could not load album',
        message: '$e',
        onRetry: () =>
            ref.invalidate(_albumDetailProvider(widget.browseId)),
      ),
      data: (d) {
        final playingKey = ref.watch(
          playbackServiceProvider.select((s) => s.current?.queueKey),
        );
        final order = List.of(d.tracks);
        final title =
            d.title.isNotEmpty ? d.title : widget.fallbackTitle;
        final art =
            d.artwork.isNotEmpty ? d.artwork : widget.fallbackArt;
        return ListView(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 32),
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(
                  maxWidth: WaveDensity.contentMax),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LayoutBuilder(builder: (context, c) {
                    final narrow = c.maxWidth < 640;
                    final header = Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        Text('ALBUM',
                            style: WaveType.overline.copyWith(
                                fontSize: 10,
                                color: waveTextTertiary(
                                    context))),
                        const SizedBox(height: 6),
                        Text(title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: WaveType.pageTitle
                                .copyWith(fontSize: 28)),
                        const SizedBox(height: 4),
                        HyperlinkButton(
                          onPressed: () => context.go(
                              '/search?q=${Uri.encodeComponent(d.artist)}'),
                          child: Text(d.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: WaveType.body.copyWith(
                                  fontSize: 14,
                                  color: waveTextSecondary(
                                      context))),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                  '${d.tracks.length} tracks',
                                  maxLines: 1,
                                  overflow:
                                      TextOverflow.ellipsis,
                                  style: WaveType.meta.copyWith(
                                      color: waveTextTertiary(
                                          context))),
                            ),
                            const SizedBox(width: 8),
                            const WaveChip(
                                label: 'OPUS',
                                highlight: true),
                          ],
                        ),
                        const SizedBox(height: 14),
                        WaveCommandBar(
                              onPlay: order.isEmpty
                                  ? null
                                  : () => playGenerated(
                                      ref, context, order.first,
                                      sourceLabel: title,
                                      queueAll: order),
                              onShuffle: order.isEmpty
                                  ? null
                                  : () {
                                      final s = List.of(order)
                                        ..shuffle();
                                      playGenerated(ref, context,
                                          s.first,
                                          sourceLabel: title,
                                          queueAll: s);
                                    },
                              onDownload: order.isEmpty
                                  ? null
                                  : () {
                                      final manager = ref.read(
                                          downloadManagerProvider
                                              .notifier);
                                      for (final t in order) {
                                        manager.downloadTrack(
                                            title: t.name,
                                            artist: t.artist,
                                            artworkUrl:
                                                t.artworkUrl);
                                      }
                                    },
                              overflowItems: order.isEmpty
                                  ? const []
                                  : waveTrackMenuItems(
                                      ref: ref,
                                      title: order.first.name,
                                      artist: order.first.artist,
                                      artworkUrl:
                                          order.first.artworkUrl,
                                      videoId: order.first.videoId,
                                    ),
                            ),
                          ],
                    );
                    if (narrow) {
                      return Column(
                        crossAxisAlignment:
                            CrossAxisAlignment.start,
                        children: [
                          WaveArtwork(
                              url: art,
                              size: 180,
                              radius: WaveRadius.artwork,
                              label: title),
                          const SizedBox(height: 16),
                          header,
                        ],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        WaveArtwork(
                            url: art,
                            size: 200,
                            radius: WaveRadius.artwork,
                            label: title),
                        const SizedBox(width: 22),
                        Expanded(child: header),
                      ],
                    );
                  }),
                  const SizedBox(height: 20),
                  WaveDesktopTable<GeneratedTrack>(
                    items: order,
                    keyOf: (t) => t.key,
                    titleOf: (t) => t.name,
                    subtitleOf: (t) => t.artist,
                    albumOf: (_) => title,
                    artworkOf: (t) => t.artworkUrl,
                    playableOf: playableFromGenerated,
                    titleSortOf: (t) => t.name.toLowerCase(),
                    artistSortOf: (t) => t.artist.toLowerCase(),
                    isCurrent: (t) => playingKey == t.key,
                    isPlaying: (t) {
                      final s = ref.watch(
                        playbackServiceProvider.select(
                            (p) => p.isPlaying),
                      );
                      return playingKey == t.key && s;
                    },
                    showArtistColumn: true,
                    shrinkWrap: true,
                    onPlay: (i) => playGenerated(
                        ref, context, order[i],
                        sourceLabel: title,
                        queueAll: order,
                        startIndex: i),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    '${order.length} tracks',
                    style: WaveType.meta.copyWith(
                        color:
                            waveTextTertiary(context)),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
