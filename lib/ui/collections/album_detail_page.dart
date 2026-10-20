import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/track_actions.dart'
    show formatDuration, playGenerated, playableFromGenerated;
import '../../../core/audio/stream_models.dart';
import '../../../core/storage/prefs.dart';
import '../../../features/addons/addon_api.dart';
import '../../../features/downloads/download_manager.dart';
import '../../../features/feed/feed_repository.dart';
import '../../../features/innertube/innertube_api.dart';
import '../../../features/player/playback_service.dart';
import '../components/ambient.dart';
import '../components/artwork.dart';
import '../components/buttons.dart';
import '../components/command_bar.dart';
import '../components/desktop_table.dart';
import '../components/menus.dart';
import '../components/skeletons.dart';
import '../components/states.dart';
import '../navigation/flight.dart';
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
            // Per-track sleeves survive when the response carries
            // them (recap-style listings); the header is only the
            // fallback for true album rows that omit artwork.
            artworkUrl:
                t.artworkUrl.isNotEmpty ? t.artworkUrl : art,
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
      loading: () => _body(
        title: widget.fallbackTitle,
        artist: widget.fallbackArtist,
        art: widget.fallbackArt,
        tracks: null,
      ),
      error: (e, _) => WaveError(
        title: 'Could not load album',
        message: '$e',
        onRetry: () =>
            ref.invalidate(_albumDetailProvider(widget.browseId)),
      ),
      data: (d) => _body(
        title: d.title.isNotEmpty ? d.title : widget.fallbackTitle,
        artist:
            d.artist.isNotEmpty ? d.artist : widget.fallbackArtist,
        art: d.artwork.isNotEmpty ? d.artwork : widget.fallbackArt,
        tracks: d.tracks,
      ),
    );
  }

  /// Album layout: header over the track table, shared by the loading and the
  /// loaded path. [tracks] null means `browseAlbum` has not answered yet — the
  /// header is already real (cover/title/artist were routed in by
  /// [waveAlbumLocation]) and skeleton rows stand in for the table, which then
  /// fades in underneath. That is what the route entrance animates; with a
  /// spinner here it played over nothing and the album looked like it never
  /// faded in, just arrived late.
  Widget _body({
    required String title,
    required String artist,
    required String art,
    required List<GeneratedTrack>? tracks,
  }) {
    final loading = tracks == null;
    final order = tracks ?? const <GeneratedTrack>[];
    final albumTitle = title.isNotEmpty ? title : 'Album';
    final playingKey = ref.watch(
      playbackServiceProvider.select((s) => s.current?.queueKey),
    );
    // A seedless load (command palette, deep link) has no cover to show:
    // stand a skeleton tile in rather than an empty artwork frame.
    Widget artTile(double size) => (loading && art.isEmpty)
        ? SkeletonBox(width: size, height: size)
        : WaveFlightTarget(
            kind: 'album',
            id: widget.browseId,
            enabled: art.isNotEmpty,
            child: WaveArtwork(
                url: art,
                size: size,
                radius: WaveRadius.artwork,
                title: albumTitle,
                artist: artist,
                label: albumTitle,
                kind: ArtworkKind.album),
          );
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
                    index: 0,
                    rise: 10,
                    child: WaveAmbientBand(
                      artworkUrl: art,
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
                        Text(albumTitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: WaveType.pageTitle
                                .copyWith(fontSize: 28)),
                        const SizedBox(height: 4),
                        WaveLink(
                          onPressed: () => context.go(
                              '/search?q=${Uri.encodeComponent(artist)}'),
                          child: Text(artist,
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
                            if (loading)
                              const SkeletonBox(
                                  width: 84, height: 10)
                            else
                              Flexible(
                                child: Text(
                                    '${order.length} tracks',
                                    maxLines: 1,
                                    overflow:
                                        TextOverflow.ellipsis,
                                    style: WaveType.meta.copyWith(
                                        color: waveTextTertiary(
                                            context))),
                              ),
                            const SizedBox(width: 8),
                            if (!loading && order.isNotEmpty)
                              _AlbumQualityChip(
                                title: order.first.name,
                                artist: artist,
                                album: albumTitle,
                              ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        if (loading)
                          // Placeholder for the transport row: WaveCommandBar
                          // drops a button whose callback is null, so without
                          // this the header would jump when the browse lands.
                          const SizedBox(height: 32)
                        else
                        WaveCommandBar(
                              onPlay: order.isEmpty
                                  ? null
                                  : () => playGenerated(
                                      ref, context, order.first,
                                      sourceLabel: albumTitle,
                                      queueAll: order),
                              onShuffle: order.isEmpty
                                  ? null
                                  : () {
                                      final s = List.of(order)
                                        ..shuffle();
                                      playGenerated(ref, context,
                                          s.first,
                                          sourceLabel: albumTitle,
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
                                      context: context,
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
                          artTile(180),
                          const SizedBox(height: 16),
                          header,
                        ],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        artTile(200),
                        const SizedBox(width: 22),
                        Expanded(child: header),
                      ],
                    );
                      }),
                    ),
                  ),
                  const SizedBox(height: 20),
                  // The browse answers well after the route entrance has
                  // finished (that is the whole reason the header is seeded),
                  // so the swap is what has to soften: the table fades in where
                  // the skeleton stood instead of popping in after the motion.
                  // Deliberately not a crossfade — the outgoing skeleton and
                  // the incoming table would have to overlap, and the Stack
                  // that needs would drop the table's full width.
                  WaveEntrance(
                    index: 1,
                    rise: 10,
                    child: TweenAnimationBuilder<double>(
                    key: ValueKey(
                        loading ? 'album-loading' : 'album-tracks'),
                    tween: Tween(begin: 0, end: 1),
                    duration: waveMotion(context, WaveMotion.normal),
                    curve: WaveMotion.standard,
                    builder: (context, t, child) =>
                        Opacity(opacity: t, child: child),
                    child: loading
                        ? const SkeletonRow(count: 8)
                        : Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              WaveDesktopTable<GeneratedTrack>(
                                items: order,
                                keyOf: (t) => t.key,
                                titleOf: (t) => t.name,
                                subtitleOf: (t) => t.artist,
                                albumOf: (_) => albumTitle,
                                artworkOf: (_) => art,
                                artworkKind: ArtworkKind.album,
                                artworkTitleOf: (_) => albumTitle,
                                artworkArtistOf: (_) => artist,
                                playableOf: playableFromGenerated,
                                durationOf: (t) =>
                                    t.durationSeconds > 0
                                        ? formatDuration(Duration(
                                            seconds:
                                                t.durationSeconds))
                                        : '',
                                titleSortOf: (t) =>
                                    t.name.toLowerCase(),
                                artistSortOf: (t) =>
                                    t.artist.toLowerCase(),
                                durationSortOf: (t) =>
                                    t.durationSeconds,
                                isCurrent: (t) =>
                                    playingKey == t.key,
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
                                    sourceLabel: albumTitle,
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
                  ),
                ],
              ),
            ),
          ],
          ),
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
