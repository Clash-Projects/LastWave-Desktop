import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/track_actions.dart' show playGenerated;
import '../../core/storage/prefs.dart';
import '../../features/feed/feed_repository.dart';
import '../../features/innertube/innertube_api.dart';
import '../../features/lastfm/auth_repository.dart' show lastFmApiProvider;
import '../../features/library/playlists.dart';
import '../../features/player/playback_service.dart';
import '../../features/search/shared_providers.dart';
import '../components/artwork.dart';
import '../components/buttons.dart' show LWTooltip;
import '../components/menus.dart';
import '../components/states.dart';
import '../components/track_row.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

/// Rebuilt Library — desktop modes for thousands of items.
///
/// Songs: TABLE / LIST · Albums: ARTWORK GRID · Artists: ARTIST GRID
/// Playlists: GRID or LIST · sort · filter · in-library search.
class WaveLibraryPage extends ConsumerStatefulWidget {
  const WaveLibraryPage({super.key});
  @override
  ConsumerState<WaveLibraryPage> createState() =>
      _WaveLibraryPageState();
}

class _WaveLibraryPageState extends ConsumerState<WaveLibraryPage> {
  String _tab = 'songs'; // songs | albums | artists | playlists
  String _q = '';
  String _sort = 'recent';
  bool _playlistGrid = true;
  final _filter = TextEditingController();

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding:
                const EdgeInsets.fromLTRB(28, 22, 28, 0),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                    maxWidth: WaveDensity.contentMax),
                child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        Text('Your Library',
                            style: WaveType.pageTitle
                                .copyWith(fontSize: 24)),
                        const SizedBox(height: 2),
                        Text('Songs, albums, artists and playlists.',
                            style: WaveType.meta.copyWith(
                                color: waveTextSecondary(
                                    context))),
                      ],
                    ),
                  ),
                  GestureDetector(
                    onTap: () =>
                        showWaveCreatePlaylist(context, ref),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: waveIsDark(context)
                            ? Colors.white
                            : Colors.black,
                        borderRadius:
                            BorderRadius.circular(999),
                      ),
                      child: Text('New playlist',
                          style: WaveType.label.copyWith(
                              fontSize: 12,
                              color: waveIsDark(context)
                                  ? Colors.black
                                  : Colors.white)),
                    ),
                  ),
                ],
              ),
                ),
            ),
          ),
        ),
        // Sticky controls: tabs + search/sort stay usable while the
        // list/grid scrolls underneath — never scroll back to the top.
        SliverPersistentHeader(
          pinned: true,
          delegate: _LibraryControlsDelegate(
            tab: _tab,
            onTab: (v) => setState(() => _tab = v),
            filter: _filter,
            query: _q,
            onQuery: (v) => setState(() => _q = v),
            playlistGrid: _playlistGrid,
            onToggleGrid: () => setState(
                () => _playlistGrid = !_playlistGrid),
            sort: _sort,
            onSort: (v) => setState(() => _sort = v),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding:
                const EdgeInsets.fromLTRB(28, 12, 28, 32),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                    maxWidth: WaveDensity.contentMax),
                child: _tab == 'songs'
                    ? _SongsTab(query: _q, sort: _sort)
                    : _tab == 'albums'
                        ? _AlbumsTab(query: _q)
                        : _tab == 'artists'
                            ? _ArtistsTab(query: _q)
                            : _PlaylistsTab(
                                query: _q,
                                grid: _playlistGrid),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Pinned library controls (tabs + in-library search/sort). One fixed
/// geometry so pinning never jumps the layout when it sticks.
class _LibraryControlsDelegate extends SliverPersistentHeaderDelegate {
  final String tab;
  final ValueChanged<String> onTab;
  final TextEditingController filter;
  final String query;
  final ValueChanged<String> onQuery;
  final bool playlistGrid;
  final VoidCallback onToggleGrid;
  final String sort;
  final ValueChanged<String> onSort;
  const _LibraryControlsDelegate({
    required this.tab,
    required this.onTab,
    required this.filter,
    required this.query,
    required this.onQuery,
    required this.playlistGrid,
    required this.onToggleGrid,
    required this.sort,
    required this.onSort,
  });

  @override
  double get minExtent => 108;
  @override
  double get maxExtent => 108;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    final dark = waveIsDark(context);
    return Container(
      color: dark ? WaveColors.background : WaveColors.lightBackground,
      padding: const EdgeInsets.fromLTRB(28, 12, 28, 0),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
              maxWidth: WaveDensity.contentMax),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Tabs(value: tab, onChanged: onTab),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: ConstrainedBox(
                      constraints:
                          const BoxConstraints(maxWidth: 280),
                      child: TextBox(
                        controller: filter,
                        placeholder: 'Search in library…',
                        prefix: const Padding(
                          padding: EdgeInsets.only(left: 8),
                          child: Icon(WaveIcons.search, size: 15),
                        ),
                        onChanged: onQuery,
                      ),
                    ),
                  ),
                  const Spacer(),
                  if (tab == 'playlists')
                    GestureDetector(
                      onTap: onToggleGrid,
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Icon(
                            playlistGrid
                                ? FluentIcons.list
                                : FluentIcons.grid_view_small,
                            size: 15,
                            color:
                                waveTextSecondary(context)),
                      ),
                    ),
                  if (tab == 'songs')
                    _SortMenu(
                        value: sort, onChanged: onSort),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_LibraryControlsDelegate old) =>
      tab != old.tab ||
      query != old.query ||
      playlistGrid != old.playlistGrid ||
      sort != old.sort;
}

class _Tabs extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _Tabs({required this.value, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    const tabs = [
      ('songs', 'Songs'),
      ('albums', 'Albums'),
      ('artists', 'Artists'),
      ('playlists', 'Playlists'),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const ClampingScrollPhysics(),
      child: Row(
        children: tabs.map((t) {
          final sel = value == t.$1;
          return Padding(
            padding: const EdgeInsets.only(right: 6),
            child: GestureDetector(
              onTap: () => onChanged(t.$1),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 7),
                decoration: BoxDecoration(
                  color: sel
                      ? (waveIsDark(context)
                              ? Colors.white
                              : Colors.black)
                          .withValues(alpha: 0.1)
                      : Colors.transparent,
                  borderRadius:
                      BorderRadius.circular(999),
                ),
                child: Text(t.$2,
                    style: WaveType.label.copyWith(
                        color: sel
                            ? waveTextPrimary(context)
                            : waveTextTertiary(context))),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _SortMenu extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _SortMenu({required this.value, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    String label = switch (value) {
      'title' => 'Title A–Z',
      'artist' => 'Artist A–Z',
      _ => 'Recently added',
    };
    return DropDownButton(
      placement: FlyoutPlacementMode.bottomRight,
      title: Text(label, style: WaveType.meta),
      items: [
        MenuFlyoutItem(
            text: const Text('Recently added'),
            onPressed: () => onChanged('recent')),
        MenuFlyoutItem(
            text: const Text('Title A–Z'),
            onPressed: () => onChanged('title')),
        MenuFlyoutItem(
            text: const Text('Artist A–Z'),
            onPressed: () => onChanged('artist')),
      ],
    );
  }
}

// -- Songs: liked tracks table ---------------------------------------------

class _SongsTab extends ConsumerWidget {
  final String query;
  final String sort;
  const _SongsTab({required this.query, required this.sort});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(playlistRepositoryProvider);
    final liked =
        playlists.where((p) => p.isLikedSongs).firstOrNull;
    var tracks = (liked?.tracks ?? const [])
        .where((t) =>
            '${t.name} ${t.artist}'
                .toLowerCase()
                .contains(query.toLowerCase()))
        .toList();
    if (sort == 'title') {
      tracks.sort((a, b) => a.name.compareTo(b.name));
    } else if (sort == 'artist') {
      tracks.sort((a, b) => a.artist.compareTo(b.artist));
    } else {
      tracks = tracks.reversed.toList();
    }
    if (tracks.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 20),
        child: WaveEmpty(
          icon: WaveIcons.liked,
          title: query.isEmpty
              ? 'No liked songs yet'
              : 'No songs match "$query"',
          subtitle: query.isEmpty
              ? 'Like songs and they will live here.'
              : 'Try a different search.',
        ),
      );
    }
    final playingKey = ref.watch(
      playbackServiceProvider.select((s) => s.current?.queueKey),
    );
    final generated = tracks
        .map((t) => GeneratedTrack(
            name: t.name,
            artist: t.artist,
            artworkUrl: t.artworkUrl,
            videoId: t.videoId))
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${tracks.length} songs',
            style: WaveType.meta
                .copyWith(color: waveTextTertiary(context))),
        const SizedBox(height: 6),
        const WaveTrackTableHeader(showAlbum: false),
        for (var i = 0; i < tracks.length; i++)
          WaveContextMenu(
            items: () => waveTrackMenuItems(
              ref: ref,
              title: tracks[i].name,
              artist: tracks[i].artist,
              artworkUrl: tracks[i].artworkUrl,
              videoId: tracks[i].videoId,
            ),
            child: WaveTrackRow(
              index: i + 1,
              title: tracks[i].name,
              artist: tracks[i].artist,
              artworkUrl: tracks[i].artworkUrl,
              videoId: tracks[i].videoId,
              playing: playingKey == generated[i].key,
              isCurrent: playingKey == generated[i].key,
              onTap: () => playGenerated(
                  ref, context, generated[i],
                  sourceLabel: 'Liked Songs',
                  queueAll: generated,
                  startIndex: i),
            ),
          ),
      ],
    );
  }
}

// -- Albums: artwork grid ---------------------------------------------------

final _libAlbumsProvider = FutureProvider.autoDispose<
    List<({String title, String artist, String art, String browseId})>>(
    (ref) async {
  final api = ref.watch(lastFmApiProvider);
  final apiKey = ref.watch(prefsApiKeyProvider);
  final user = ref.watch(prefsProvider).username;
  // Try Last.fm top albums for a personal grid.
  if (user.isNotEmpty) {
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
      // Resolve browseIds lazily on tap via search; keep empty here.
      return list
          .map((a) => (
                title: a['name']?.toString() ?? '',
                artist: (a['artist'] as Map?)?['name']
                        ?.toString() ??
                    '',
                art: _libImg(a['image']),
                browseId: '',
              ))
          .where((e) => e.title.isNotEmpty)
          .toList();
    } catch (_) {}
  }
  try {
    final entities = await ref
        .watch(innerTubeProvider)
        .browseAlbums('FEmusic_new_releases', limit: 24);
    return entities
        .map((e) {
          final parts =
              InnerTubeMusicApi.splitSubtitle(e.subtitle);
          return (
            title: e.name,
            artist: parts.length > 1 ? parts[1] : e.artist,
            art: e.artworkUrl,
            browseId: e.browseId,
          );
        })
        .toList();
  } catch (_) {
    return const [];
  }
});

String _libImg(Object? images) {
  var fallback = '';
  final list =
      images is List ? images.whereType<Map>().toList() : const [];
  for (final img in list) {
    final url = img['#text']?.toString() ?? '';
    if (url.isEmpty) continue;
    fallback = url;
    if (img['size'] == 'extralarge') return url;
  }
  return fallback;
}

class _AlbumsTab extends ConsumerWidget {
  final String query;
  const _AlbumsTab({required this.query});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(_libAlbumsProvider);
    return async.when(
      loading: () =>
          const WaveLoading(label: 'Loading albums…'),
      error: (e, _) => WaveError(
        title: 'Could not load albums',
        message: '$e',
        onRetry: () =>
            ref.invalidate(_libAlbumsProvider),
      ),
      data: (list) {
        final filtered = list
            .where((a) =>
                '${a.title} ${a.artist}'
                    .toLowerCase()
                    .contains(query.toLowerCase()))
            .toList();
        if (filtered.isEmpty) {
          return WaveEmpty(
            icon: WaveIcons.albums,
            title: 'No albums',
            subtitle: query.isEmpty
                ? 'Your most-played records will appear here.'
                : 'No albums match "$query".',
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${filtered.length} ${filtered.length == 1 ? 'album' : 'albums'}',
                style: WaveType.meta.copyWith(
                    color: waveTextTertiary(context))),
            const SizedBox(height: 6),
            LayoutBuilder(builder: (context, c) {
          final cols = (c.maxWidth / 160).floor().clamp(2, 8);
          return GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate:
                SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cols,
              mainAxisSpacing: 16,
              crossAxisSpacing: 12,
              mainAxisExtent: 214,
            ),
            itemCount: filtered.length,
            itemBuilder: (context, i) {
              final a = filtered[i];
              return _LibraryAlbumCell(
                  title: a.title,
                  artist: a.artist,
                  art: a.art,
                  browseId: a.browseId);
            },
          );
        }),
          ],
        );
      },
    );
  }

  static Future<void> openAlbum(
      BuildContext context,
      WidgetRef ref,
      String title,
      String artist,
      String browseId) async {
    String bid = browseId;
    if (bid.isEmpty) {
      try {
        final results = await ref
            .read(innerTubeProvider)
            .searchAlbums('$artist $title', limit: 3);
        if (results.isNotEmpty) bid = results.first.browseId;
      } catch (_) {}
    }
    if (!context.mounted) return;
    if (bid.isEmpty) {
      context.go(
          '/search?q=${Uri.encodeComponent('$artist $title')}');
      return;
    }
    context.go('/album/${Uri.encodeComponent(bid)}');
  }
}

/// Library album cell: 150px art radius 6 + hover quick-play + more.
class _LibraryAlbumCell extends ConsumerStatefulWidget {
  final String title;
  final String artist;
  final String art;
  final String browseId;
  const _LibraryAlbumCell(
      {required this.title,
      required this.artist,
      required this.art,
      required this.browseId});
  @override
  ConsumerState<_LibraryAlbumCell> createState() =>
      _LibraryAlbumCellState();
}

class _LibraryAlbumCellState
    extends ConsumerState<_LibraryAlbumCell> {
  bool _hover = false;

  Future<String> _browseId() async {
    if (widget.browseId.isNotEmpty) return widget.browseId;
    try {
      final results = await ref
          .read(innerTubeProvider)
          .searchAlbums(
              '${widget.artist} ${widget.title}',
              limit: 3);
      if (results.isNotEmpty) return results.first.browseId;
    } catch (_) {}
    return '';
  }

  Future<void> _quickPlay() async {
    try {
      final bid = await _browseId();
      if (bid.isNotEmpty) {
        final songs = await ref
            .read(innerTubeProvider)
            .browseSongs(bid, limit: 50);
        if (songs.isNotEmpty && mounted) {
          final tracks = songs
              .map((t) => GeneratedTrack(
                    name: t.title,
                    artist: t.artist.isNotEmpty
                        ? t.artist
                        : widget.artist,
                    artworkUrl: t.artworkUrl.isNotEmpty
                        ? t.artworkUrl
                        : widget.art,
                    videoId: t.videoId,
                  ))
              .toList();
          await playGenerated(ref, context, tracks.first,
              sourceLabel: widget.title,
              queueAll: tracks);
          return;
        }
      }
    } catch (_) {}
    if (mounted) {
      final bid = await _browseId();
      if (!mounted) return;
      if (bid.isEmpty) {
        context.go(
            '/search?q=${Uri.encodeComponent('${widget.artist} ${widget.title}')}');
        return;
      }
      context.go('/album/${Uri.encodeComponent(bid)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: () => _AlbumsTab.openAlbum(context, ref,
            widget.title, widget.artist, widget.browseId),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                WaveArtwork(
                    url: widget.art,
                    size: 150,
                    radius: 6,
                    label: widget.title),
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
                        child: LWTooltip(
                          message:
                              'Play ${widget.title}',
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
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: WaveType.trackTitle
                    .copyWith(fontSize: 12.5)),
            Text(widget.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    WaveType.meta.copyWith(fontSize: 11.5)),
          ],
        ),
      ),
    );
  }
}

// -- Artists: portrait grid -------------------------------------------------

final _libArtistsProvider = FutureProvider.autoDispose<
    List<({String name, String art})>>((ref) async {
  final api = ref.watch(lastFmApiProvider);
  final apiKey = ref.watch(prefsApiKeyProvider);
  final user = ref.watch(prefsProvider).username;
  try {
    final method =
        user.isEmpty ? 'chart.gettopartists' : 'user.gettopartists';
    final json = await api.get({
      'method': method,
      if (user.isNotEmpty) 'user': user,
      'api_key': apiKey,
      'limit': '30',
      'period': '1month',
    });
    final root =
        user.isEmpty ? json['artists'] : json['topartists'];
    final items = root?['artist'];
    final list = items is List
        ? items.whereType<Map<String, dynamic>>().toList()
        : items is Map<String, dynamic>
            ? [items]
            : <Map<String, dynamic>>[];
    return list
        .map((a) => (
              name: a['name']?.toString() ?? '',
              art: _libImg(a['image']),
            ))
        .where((e) => e.name.isNotEmpty)
        .toList();
  } catch (_) {
    return const [];
  }
});

class _ArtistsTab extends ConsumerWidget {
  final String query;
  const _ArtistsTab({required this.query});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(_libArtistsProvider);
    return async.when(
      loading: () =>
          const WaveLoading(label: 'Loading artists…'),
      error: (e, _) => WaveError(
        title: 'Could not load artists',
        message: '$e',
        onRetry: () =>
            ref.invalidate(_libArtistsProvider),
      ),
      data: (list) {
        final filtered = list
            .where((a) => a.name
                .toLowerCase()
                .contains(query.toLowerCase()))
            .toList();
        if (filtered.isEmpty) {
          return WaveEmpty(
            icon: WaveIcons.lyrics,
            title: 'No artists',
            subtitle: query.isEmpty
                ? 'Your most-played voices will appear here.'
                : 'No artists match "$query".',
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${filtered.length} ${filtered.length == 1 ? 'artist' : 'artists'}',
                style: WaveType.meta.copyWith(
                    color: waveTextTertiary(context))),
            const SizedBox(height: 6),
            LayoutBuilder(builder: (context, c) {
          final cols = (c.maxWidth / 140).floor().clamp(2, 8);
          return GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate:
                SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cols,
              mainAxisSpacing: 14,
              crossAxisSpacing: 10,
              mainAxisExtent: 168,
            ),
            itemCount: filtered.length,
            itemBuilder: (context, i) {
              final a = filtered[i];
              return GestureDetector(
                onTap: () => context.go(
                    '/artist/${Uri.encodeComponent(a.name)}'),
                child: Column(
                  children: [
                    WaveArtwork.circle(
                        url: a.art,
                        size: 112,
                        label: a.name),
                    const SizedBox(height: 6),
                    Text(a.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: WaveType.trackTitle
                            .copyWith(fontSize: 12.5)),
                  ],
                ),
              );
            },
          );
        }),
          ],
        );
      },
    );
  }
}

// -- Playlists --------------------------------------------------------------

class _PlaylistsTab extends ConsumerWidget {
  final String query;
  final bool grid;
  const _PlaylistsTab({required this.query, required this.grid});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(playlistRepositoryProvider);
    final customs = playlists
        .where((p) => p.title
            .toLowerCase()
            .contains(query.toLowerCase()))
        .toList();
    if (customs.isEmpty) {
      return WaveEmpty(
        icon: FluentIcons.list_mirrored,
        title: 'No playlists yet',
        subtitle: query.isEmpty
            ? 'Create your first playlist to organise what you love.'
            : 'No playlists match "$query".',
        actionLabel:
            query.isEmpty ? 'Create playlist' : null,
        onAction: query.isEmpty
            ? () =>
                showWaveCreatePlaylist(context, ref)
            : null,
      );
    }
    if (!grid) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${customs.length} ${customs.length == 1 ? 'playlist' : 'playlists'}',
              style: WaveType.meta.copyWith(
                  color: waveTextTertiary(context))),
          const SizedBox(height: 6),
          for (var i = 0; i < customs.length; i++)
            _PlaylistListRow(
                playlist: customs[i], index: i + 1),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${customs.length} ${customs.length == 1 ? 'playlist' : 'playlists'}',
            style: WaveType.meta.copyWith(
                color: waveTextTertiary(context))),
        const SizedBox(height: 6),
        LayoutBuilder(builder: (context, c) {
      final cols = (c.maxWidth / 160).floor().clamp(2, 8);
      return GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate:
            SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          mainAxisSpacing: 16,
          crossAxisSpacing: 12,
          mainAxisExtent: 214,
        ),
        itemCount: customs.length,
        itemBuilder: (context, i) {
          final p = customs[i];
          String? cover;
          for (final t in p.tracks) {
            if (t.artworkUrl.isNotEmpty) {
              cover = t.artworkUrl;
              break;
            }
          }
          return GestureDetector(
            onTap: () =>
                context.go('/playlists/${p.id}'),
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                WaveArtwork(
                    url: cover ?? '',
                    size: 150,
                    radius: 6,
                    label: p.title),
                const SizedBox(height: 6),
                Text(p.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: WaveType.trackTitle
                        .copyWith(fontSize: 12.5)),
                Text('${p.tracks.length} tracks',
                    style: WaveType.meta
                        .copyWith(fontSize: 11.5)),
              ],
            ),
          );
        },
      );
    }),
      ],
    );
  }
}

class _PlaylistListRow extends ConsumerWidget {
  final SavedPlaylist playlist;
  final int index;
  const _PlaylistListRow(
      {required this.playlist, required this.index});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    String? cover;
    for (final t in playlist.tracks) {
      if (t.artworkUrl.isNotEmpty) {
        cover = t.artworkUrl;
        break;
      }
    }
    return WaveContextMenu(
      items: () => [
        MenuFlyoutItem(
          leading: const Icon(WaveIcons.play, size: 15),
          text: const Text('Play'),
          onPressed: () {
            if (playlist.tracks.isEmpty) return;
            final gen = playlist.tracks
                .map((t) => GeneratedTrack(
                    name: t.name,
                    artist: t.artist,
                    artworkUrl: t.artworkUrl,
                    videoId: t.videoId))
                .toList();
            playGenerated(ref, context, gen.first,
                sourceLabel: playlist.title,
                queueAll: gen);
          },
        ),
        if (!playlist.isLikedSongs)
          MenuFlyoutItem(
            leading:
                const Icon(WaveIcons.delete, size: 15),
            text: const Text('Delete'),
            onPressed: () => showWaveDeletePlaylist(
                context, ref, playlist),
          ),
      ],
      child: WaveTrackRow(
        index: index,
        title: playlist.title,
        artist:
            '${playlist.tracks.length} tracks${playlist.isPinned ? ' · Pinned' : ''}',
        artworkUrl: cover ?? '',
        showLike: false,
        onTap: () =>
            context.go('/playlists/${playlist.id}'),
      ),
    );
  }
}

/// Shared playlist dialogs (create / rename / delete).
Future<void> showWaveCreatePlaylist(
  BuildContext context,
  WidgetRef ref,
) async {
  final controller = TextEditingController();
  final name = await showDialog<String>(
    context: context,
    builder: (context) => ContentDialog(
      title: const Text('New playlist'),
      content: TextBox(
        controller: controller,
        placeholder: 'Playlist name',
        autofocus: true,
        onSubmitted: (v) =>
            Navigator.of(context).pop(v.trim()),
      ),
      actions: [
        Button(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context)
              .pop(controller.text.trim()),
          child: const Text('Create'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (name != null && name.isNotEmpty && context.mounted) {
    final created = await ref
        .read(playlistRepositoryProvider.notifier)
        .createCustom(name);
    if (context.mounted) {
      context.go('/playlists/${created.id}');
    }
  }
}

Future<void> showWaveRenamePlaylist(
  BuildContext context,
  WidgetRef ref,
  SavedPlaylist playlist,
) async {
  final controller =
      TextEditingController(text: playlist.title);
  final name = await showDialog<String>(
    context: context,
    builder: (context) => ContentDialog(
      title: const Text('Rename playlist'),
      content: TextBox(
        controller: controller,
        autofocus: true,
        onSubmitted: (v) =>
            Navigator.of(context).pop(v.trim()),
      ),
      actions: [
        Button(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context)
              .pop(controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (name != null && name.isNotEmpty) {
    await ref
        .read(playlistRepositoryProvider.notifier)
        .rename(playlist.id, name);
  }
}

Future<void> showWaveDeletePlaylist(
  BuildContext context,
  WidgetRef ref,
  SavedPlaylist playlist,
) async {
  final confirm = await showDialog<bool>(
    context: context,
    builder: (context) => ContentDialog(
      title: const Text('Delete playlist?'),
      content: Text(
        '"${playlist.title}" will be removed from your library.',
      ),
      actions: [
        Button(
          onPressed: () =>
              Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (confirm == true && context.mounted) {
    await ref
        .read(playlistRepositoryProvider.notifier)
        .delete(playlist.id);
    if (context.mounted) {
      context.go('/playlists');
    }
  }
}





