import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/track_actions.dart'
    show formatDuration, playGenerated, playableFromGenerated;
import '../../../core/audio/stream_models.dart';
import '../../../core/storage/prefs.dart';
import '../../../features/downloads/download_manager.dart';
import '../../../features/feed/feed_repository.dart';
import '../../../features/innertube/innertube_api.dart';
import '../../../features/lossless/lossless_api.dart';
import '../../../features/player/playback_service.dart';
import '../components/artwork.dart';
import '../components/buttons.dart' show WaveChip;
import '../components/command_bar.dart';
import '../components/desktop_table.dart';
import '../components/menus.dart';
import '../components/states.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';

final _albumDetailProvider = FutureProvider.autoDispose
    .family<_AlbumDetail, String>((ref, browseId) async {
  final tube = ref.watch(innerTubeProvider);
  final album = await tube.browseAlbum(browseId, limit: 50);
  final songs = album?.tracks ?? const <YouTubeMusicTrack>[];
  if (album == null || songs.isEmpty) {
    throw Exception('Empty album');
  }
  // Header comes from the album page itself; track rows inherit
  // artist/album/artwork from the header (browseAlbum already did).
  final art = album.artworkUrl.isNotEmpty
      ? album.artworkUrl
      : songs
          .map((s) => s.artworkUrl)
          .firstWhere((u) => u.isNotEmpty, orElse: () => '');
  return _AlbumDetail(
    title: album.title.isNotEmpty ? album.title : 'Album',
    artist: album.artist,
    artwork: art,
    tracks: songs
        .map((t) => GeneratedTrack(
            name: t.title,
            artist: t.artist,
            artworkUrl: art,
            videoId: t.videoId,
            durationSeconds: t.durationSeconds))
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
        final artist = d.artist.isNotEmpty
            ? d.artist
            : widget.fallbackArtist;
        final art =
            d.artwork.isNotEmpty ? d.artwork : widget.fallbackArt;
        return WaveEntranceGroup(
          child: ListView(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 32),
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(
                  maxWidth: WaveDensity.contentMax),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  WaveEntrance(
                    rise: 10,
                    child: LayoutBuilder(builder: (context, c) {
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
                            if (order.isNotEmpty)
                              _AlbumQualityChip(
                                title: order.first.name,
                                artist: d.artist,
                                album: title,
                              ),
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
                              title: title,
                              artist: artist,
                              label: title,
                              kind: ArtworkKind.album),
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
                            title: title,
                            artist: artist,
                            label: title,
                            kind: ArtworkKind.album),
                        const SizedBox(width: 22),
                        Expanded(child: header),
                      ],
                    );
                    }),
                  ),
                  const SizedBox(height: 20),
                  WaveDesktopTable<GeneratedTrack>(
                    items: order,
                    keyOf: (t) => t.key,
                    titleOf: (t) => t.name,
                    subtitleOf: (t) => t.artist,
                    albumOf: (_) => title,
                    artworkOf: (_) => art,
                    artworkKind: ArtworkKind.album,
                    artworkTitleOf: (_) => title,
                    artworkArtistOf: (_) => artist,
                    playableOf: playableFromGenerated,
                    durationOf: (t) => t.durationSeconds > 0
                        ? formatDuration(
                            Duration(seconds: t.durationSeconds))
                        : '',
                    titleSortOf: (t) => t.name.toLowerCase(),
                    artistSortOf: (t) => t.artist.toLowerCase(),
                    durationSortOf: (t) => t.durationSeconds,
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
          ),
        );
      },
    );
  }
}

/// Live quality chip: probes the lossless backend with the album's first
/// track and shows the tier the album would actually play at (HI-RES /
/// LOSSLESS). Renders nothing when lossless isn't configured, is
/// disabled in settings, or the album isn't available on the backend —
/// a hardcoded codec badge would be a lie.
class _AlbumQualityChip extends ConsumerStatefulWidget {
  final String title;
  final String artist;
  final String album;
  const _AlbumQualityChip({
    required this.title,
    required this.artist,
    required this.album,
  });

  @override
  ConsumerState<_AlbumQualityChip> createState() =>
      _AlbumQualityChipState();
}

class _AlbumQualityChipState extends ConsumerState<_AlbumQualityChip> {
  String? _badge;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _probe());
  }

  Future<void> _probe() async {
    final prefs = ref.read(prefsProvider);
    final api = ref.read(losslessApiProvider);
    if (!api.isConfigured ||
        !prefs.preferLossless ||
        prefs.losslessQuality == AudioQualityTiers.youtubeOnly) {
      return;
    }
    if (widget.title.isEmpty || widget.artist.isEmpty) return;
    try {
      final stream = await api.resolveStream(
        title: widget.title,
        artist: widget.artist,
        album: widget.album,
        preferredQuality: prefs.losslessQuality,
      );
      if (mounted && stream != null && stream.isLossless) {
        setState(() => _badge = stream.qualityBadge);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final badge = _badge;
    if (badge == null) return const SizedBox.shrink();
    return WaveChip(label: badge, highlight: true);
  }
}
