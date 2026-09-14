import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/track_actions.dart' show playGenerated;
import '../../core/storage/prefs.dart';
import '../../features/feed/feed_repository.dart';
import '../../features/innertube/innertube_api.dart';
import '../../features/lastfm/auth_repository.dart' show lastFmApiProvider;
import '../../features/player/playback_service.dart';
import '../../features/search/shared_providers.dart' show prefsApiKeyProvider;
import '../components/artwork.dart';
import '../components/menus.dart';
import '../components/states.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

class _Album {
  final String title;
  final String artist;
  final String artwork;
  final String browseId;
  const _Album(this.title, this.artist, this.artwork, this.browseId);
}

final _waveAlbumsProvider =
    FutureProvider<List<_Album>>((ref) async {
  final api = ref.watch(lastFmApiProvider);
  final apiKey = ref.watch(prefsApiKeyProvider);
  final user = ref.watch(prefsProvider).username;
  if (user.isEmpty) {
    try {
      final entities = await ref
          .watch(innerTubeProvider)
          .browseAlbums('FEmusic_new_releases', limit: 24);
      return entities.map((e) {
        final parts =
            InnerTubeMusicApi.splitSubtitle(e.subtitle);
        final artist =
            parts.length > 1 ? parts[1] : e.artist;
        return _Album(e.name, artist, e.artworkUrl, e.browseId);
      }).toList();
    } catch (_) {
      return const [];
    }
  }
  try {
    final json = await api.get({
      'method': 'user.gettopalbums',
      'user': user,
      'api_key': apiKey,
      'limit': '30',
      'period': '1month',
    });
    final items = json['topalbums']?['album'];
    final list = items is List
        ? items.whereType<Map<String, dynamic>>().toList()
        : items is Map<String, dynamic>
            ? [items]
            : <Map<String, dynamic>>[];
    // Resolve browseIds on demand via search when opening.
    return list
        .map((a) => _Album(
              a['name']?.toString() ?? '',
              (a['artist'] as Map?)?['name']?.toString() ?? '',
              _img(a['image']),
              '',
            ))
        .where((e) => e.title.isNotEmpty)
        .toList();
  } catch (_) {
    return const [];
  }
});

String _img(Object? images) {
  var fallback = '';
  final list = images is List
      ? images.whereType<Map>().toList()
      : const [];
  for (final img in list) {
    final url = img['#text']?.toString() ?? '';
    if (url.isEmpty) continue;
    fallback = url;
    if (img['size'] == 'extralarge') return url;
  }
  return fallback;
}

/// Albums — premium responsive grid (max180/extent218, 160px art radius 6,
/// hover quick-play 44px + more + playing indicator).
class WaveAlbumsPage extends ConsumerWidget {
  const WaveAlbumsPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albums = ref.watch(_waveAlbumsProvider);
    return albums.when(
      loading: () => const WaveLoading(label: 'Loading albums…'),
      error: (e, _) => WaveError(
        title: 'Could not load albums',
        message: '$e',
        onRetry: () => ref.invalidate(_waveAlbumsProvider),
      ),
      data: (list) {
        if (list.isEmpty) {
          return const WaveEmpty(
            icon: FluentIcons.music_note,
            title: 'No albums yet',
            subtitle:
                'Your most-played records will appear here once you scrobble.',
          );
        }
        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding:
                    const EdgeInsets.fromLTRB(28, 22, 28, 12),
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    Text('Albums',
                        style: WaveType.pageTitle
                            .copyWith(fontSize: 24)),
                    Text('${list.length} records',
                        style: WaveType.meta.copyWith(
                            color: waveTextSecondary(
                                context))),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding:
                  const EdgeInsets.fromLTRB(28, 0, 28, 28),
              sliver: SliverGrid(
                gridDelegate:
                    const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 180,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 12,
                  mainAxisExtent: 218,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) {
                    final a = list[i];
                    return _AlbumCard(album: a);
                  },
                  childCount: list.length,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _AlbumCard extends ConsumerStatefulWidget {
  final _Album album;
  const _AlbumCard({required this.album});
  @override
  ConsumerState<_AlbumCard> createState() => _AlbumCardState();
}

class _AlbumCardState extends ConsumerState<_AlbumCard> {
  bool _hover = false;

  Future<void> _open() async {
    final a = widget.album;
    String bid = a.browseId;
    if (bid.isEmpty) {
      try {
        final results = await ref
            .read(innerTubeProvider)
            .searchAlbums('${a.artist} ${a.title}', limit: 3);
        if (results.isNotEmpty) bid = results.first.browseId;
      } catch (_) {}
    }
    if (!mounted) return;
    if (bid.isEmpty) {
      context.go(
          '/search?q=${Uri.encodeComponent('${a.artist} ${a.title}')}');
      return;
    }
    context.go('/album/${Uri.encodeComponent(bid)}');
  }

  Future<void> _quickPlay() async {
    final a = widget.album;
    try {
      String bid = a.browseId;
      if (bid.isEmpty) {
        final results = await ref
            .read(innerTubeProvider)
            .searchAlbums('${a.artist} ${a.title}', limit: 3);
        if (results.isNotEmpty) bid = results.first.browseId;
      }
      if (bid.isNotEmpty) {
        final songs = await ref
            .read(innerTubeProvider)
            .browseSongs(bid, limit: 50);
        if (songs.isNotEmpty && mounted) {
          final tracks = songs
              .map((t) => GeneratedTrack(
                    name: t.title,
                    artist:
                        t.artist.isNotEmpty ? t.artist : a.artist,
                    artworkUrl: t.artworkUrl.isNotEmpty
                        ? t.artworkUrl
                        : a.artwork,
                    videoId: t.videoId,
                  ))
              .toList();
          await playGenerated(ref, context, tracks.first,
              sourceLabel: a.title, queueAll: tracks);
          return;
        }
      }
    } catch (_) {}
    if (mounted) await _open();
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.album;
    final playing = ref.watch(
      playbackServiceProvider.select(
        (s) =>
            s.current != null &&
            (s.sourceLabel == a.title ||
                (s.current!.album == a.title &&
                    s.current!.artist == a.artist)),
      ),
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: _open,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 110),
          decoration: BoxDecoration(
            color: _hover
                ? (waveIsDark(context) ? Colors.white : Colors.black)
                    .withValues(alpha: 0.05)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          padding: const EdgeInsets.all(4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  WaveArtwork(
                      url: a.artwork,
                      size: 160,
                      radius: 6,
                      label: a.title),
                  Positioned.fill(
                    child: AnimatedOpacity(
                      opacity: _hover ? 1 : 0,
                      duration:
                          const Duration(milliseconds: 110),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black
                              .withValues(alpha: 0.42),
                          borderRadius:
                              BorderRadius.circular(6),
                        ),
                        child: Center(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Tooltip(
                                message: 'Play ${a.title}',
                                child: GestureDetector(
                                  onTap: _quickPlay,
                                  child: Container(
                                    width: 44,
                                    height: 44,
                                    decoration:
                                        const BoxDecoration(
                                      color: Colors.white,
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                        FluentIcons.play,
                                        size: 18,
                                        color: Colors.black),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              WaveContextMenu(
                                items: () =>
                                    waveTrackMenuItems(
                                  ref: ref,
                                  title: a.title,
                                  artist: a.artist,
                                  artworkUrl: a.artwork,
                                ),
                                child: Container(
                                  width: 32,
                                  height: 32,
                                  decoration: BoxDecoration(
                                    color: Colors.black
                                        .withValues(alpha: 0.55),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                      FluentIcons.more,
                                      size: 14,
                                      color: Colors.white),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (playing)
                    Positioned(
                      left: 6,
                      bottom: 6,
                      child: Container(
                        padding:
                            const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.black
                              .withValues(alpha: 0.7),
                          borderRadius:
                              BorderRadius.circular(999),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(WaveIcons.queue,
                                size: 11,
                                color: Colors.white),
                            SizedBox(width: 4),
                            Text('PLAYING',
                                style: TextStyle(
                                    fontSize: 9,
                                    fontWeight:
                                        FontWeight.w700,
                                    letterSpacing: 0.6,
                                    color: Colors.white)),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(a.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: WaveType.trackTitle.copyWith(
                      fontSize: 12.5,
                      color: playing
                          ? waveAccent(context)
                          : null)),
              Text(a.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: WaveType.meta
                      .copyWith(fontSize: 11.5)),
            ],
          ),
        ),
      ),
    );
  }
}



