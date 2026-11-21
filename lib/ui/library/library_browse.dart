import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/library/library_index.dart';
import '../../features/library/playlists.dart';
import '../../features/player/playback_service.dart';
import '../collections/playlist_dialogs.dart'
    show
        showWaveCreatePlaylist,
        showWaveDeletePlaylist,
        showWaveRenamePlaylist;
import '../components/artwork.dart';
import '../components/buttons.dart' show WaveGhostButton;
import '../components/states.dart';
import '../components/track_row.dart' show WaveDesktopTable;
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

const _emptyHint =
    'Download songs or add a music folder and they show up here.';

void _playAll(WidgetRef ref, List<StoredTrack> tracks, int index,
    {String label = 'Library'}) {
  ref.read(playbackServiceProvider.notifier).playQueue(
        [for (final t in tracks) t.toPlayable()],
        index,
        sourceLabel: label,
      );
}

/// Search box + song count row shared by the views.
class _Toolbar extends StatelessWidget {
  final String placeholder;
  final String count;
  final ValueChanged<String> onQuery;
  const _Toolbar({
    required this.placeholder,
    required this.count,
    required this.onQuery,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
      child: Row(
        children: [
          Expanded(
            child: TextBox(
              placeholder: placeholder,
              prefix: const Padding(
                padding: EdgeInsets.only(left: 10),
                child: Icon(WaveIcons.search, size: 14),
              ),
              onChanged: onQuery,
            ),
          ),
          const SizedBox(width: 12),
          Text(count,
              style: WaveType.meta.copyWith(color: waveTextTertiary(context))),
        ],
      ),
    );
  }
}

/// Row key: the file for Library songs; playlists can also hold streamed
/// rows, which PlaylistRepository keys by name|artist.
String _keyOf(StoredTrack t) => t.playbackUrl.isNotEmpty
    ? t.playbackUrl
    : '${t.name.toLowerCase()}|${t.artist.toLowerCase()}';

bool _matches(StoredTrack t, String q) =>
    q.isEmpty ||
    t.name.toLowerCase().contains(q) ||
    t.artist.toLowerCase().contains(q) ||
    t.album.toLowerCase().contains(q);

/// Sortable song table. [tracks] null = the whole library.
class LibrarySongsView extends ConsumerStatefulWidget {
  final List<StoredTrack>? tracks;
  final String sourceLabel;
  final Widget? header;

  /// Row remove action (playlists); null hides it.
  final void Function(StoredTrack track)? onRemove;
  const LibrarySongsView({
    super.key,
    this.tracks,
    this.sourceLabel = 'Library',
    this.header,
    this.onRemove,
  });

  @override
  ConsumerState<LibrarySongsView> createState() => _LibrarySongsViewState();
}

class _LibrarySongsViewState extends ConsumerState<LibrarySongsView> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final List<StoredTrack> all =
        widget.tracks ?? ref.watch(libraryTracksProvider);
    final q = _query.trim().toLowerCase();
    final items = [for (final t in all) if (_matches(t, q)) t];
    final current = ref.watch(
        playbackServiceProvider.select((s) => s.current?.playbackUrl ?? ''));
    final playing = ref.watch(playbackServiceProvider.select((s) => s.isPlaying));
    return CustomScrollView(
      slivers: [
        if (widget.header != null) SliverToBoxAdapter(child: widget.header),
        SliverToBoxAdapter(
          child: _Toolbar(
            placeholder: 'Search songs',
            count: '${all.length} ${all.length == 1 ? 'song' : 'songs'}',
            onQuery: (v) => setState(() => _query = v),
          ),
        ),
        if (all.isEmpty)
          const SliverToBoxAdapter(
            child: WaveEmpty(
              icon: WaveIcons.music,
              title: 'No songs yet',
              subtitle: _emptyHint,
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            sliver: WaveDesktopTable<StoredTrack>(
              items: items,
              keyOf: _keyOf,
              titleOf: (t) => t.name,
              subtitleOf: (t) => t.artist,
              albumOf: (t) => t.album,
              artworkOf: (t) => t.artworkUrl,
              playableOf: (t) => t.toPlayable(),
              titleSortOf: (t) => t.name.toLowerCase(),
              artistSortOf: (t) => t.artist.toLowerCase(),
              albumSortOf: (t) => t.album.toLowerCase(),
              dateAddedSortOf: (t) => t.addedAtMillis,
              isCurrent: (t) => current.isNotEmpty && t.playbackUrl == current,
              isPlaying: (t) =>
                  playing && current.isNotEmpty && t.playbackUrl == current,
              showArtistColumn: true,
              showLike: false,
              onPlay: (i) =>
                  _playAll(ref, items, i, label: widget.sourceLabel),
              removeLabel:
                  widget.onRemove == null ? null : 'Remove from playlist',
              onRemove: widget.onRemove == null
                  ? null
                  : (i) => widget.onRemove!(items[i]),
              empty: const WaveEmpty(
                icon: WaveIcons.search,
                title: 'No matches',
                subtitle: 'Try another title, artist or album.',
              ),
            ),
          ),
      ],
    );
  }
}

/// Header for an opened album or artist: back, art, title, play all.
class _DetailHeader extends ConsumerWidget {
  final String title;
  final String subtitle;
  final String artworkUrl;
  final bool circle;
  final List<StoredTrack> tracks;
  final VoidCallback onBack;
  final List<Widget> actions;
  const _DetailHeader({
    required this.title,
    required this.subtitle,
    required this.artworkUrl,
    required this.tracks,
    required this.onBack,
    this.circle = false,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 24, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(FluentIcons.back, size: 14),
            onPressed: onBack,
          ),
          const SizedBox(width: 8),
          WaveArtwork(
            url: artworkUrl,
            size: 96,
            isCircle: circle,
            label: title,
            upgrade: false,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: WaveType.sectionTitle),
                const SizedBox(height: 4),
                Text(subtitle,
                    style: WaveType.meta
                        .copyWith(color: waveTextSecondary(context))),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton(
                      onPressed: tracks.isEmpty
                          ? null
                          : () => _playAll(ref, tracks, 0, label: title),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(WaveIcons.play, size: 12),
                          SizedBox(width: 8),
                          Text('Play'),
                        ],
                      ),
                    ),
                    ...actions,
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A cover tile in the album / artist grids.
class _Tile extends StatelessWidget {
  final String title;
  final String subtitle;
  final String artworkUrl;
  final bool circle;
  final VoidCallback onTap;
  const _Tile({
    required this.title,
    required this.subtitle,
    required this.artworkUrl,
    required this.onTap,
    this.circle = false,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: LayoutBuilder(
          builder: (context, c) => Column(
            crossAxisAlignment:
                circle ? CrossAxisAlignment.center : CrossAxisAlignment.start,
            children: [
              WaveArtwork(
                url: artworkUrl,
                size: c.maxWidth,
                decodeExtent: 200,
                isCircle: circle,
                label: title,
                upgrade: false,
              ),
              const SizedBox(height: 8),
              Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: WaveType.trackTitle.copyWith(fontSize: 13)),
              Text(subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: WaveType.meta
                      .copyWith(color: waveTextSecondary(context))),
            ],
          ),
        ),
      ),
    );
  }
}

String _songs(int n) => '$n ${n == 1 ? 'song' : 'songs'}';

/// Grid of covers that opens into a song list, shared by Albums and Artists.
class _GridBrowser<T> extends StatefulWidget {
  final List<T> items;
  final String placeholder;
  final String Function(T) titleOf;
  final String Function(T) subtitleOf;
  final String Function(T) artworkOf;
  final List<StoredTrack> Function(T) tracksOf;
  final bool circle;
  final IconData emptyIcon;
  final String emptyTitle;
  const _GridBrowser({
    required this.items,
    required this.placeholder,
    required this.titleOf,
    required this.subtitleOf,
    required this.artworkOf,
    required this.tracksOf,
    required this.emptyIcon,
    required this.emptyTitle,
    this.circle = false,
  });

  @override
  State<_GridBrowser<T>> createState() => _GridBrowserState<T>();
}

class _GridBrowserState<T> extends State<_GridBrowser<T>> {
  String _query = '';
  String? _openTitle;

  @override
  Widget build(BuildContext context) {
    final open = _openTitle == null
        ? null
        : widget.items
            .where((i) => widget.titleOf(i) == _openTitle)
            .firstOrNull;
    if (open != null) {
      final tracks = widget.tracksOf(open);
      return LibrarySongsView(
        tracks: tracks,
        sourceLabel: widget.titleOf(open),
        header: _DetailHeader(
          title: widget.titleOf(open),
          subtitle: '${widget.subtitleOf(open)} Â· ${_songs(tracks.length)}',
          artworkUrl: widget.artworkOf(open),
          circle: widget.circle,
          tracks: tracks,
          onBack: () => setState(() => _openTitle = null),
        ),
      );
    }
    final q = _query.trim().toLowerCase();
    final items = [
      for (final i in widget.items)
        if (q.isEmpty ||
            widget.titleOf(i).toLowerCase().contains(q) ||
            widget.subtitleOf(i).toLowerCase().contains(q))
          i,
    ];
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: _Toolbar(
            placeholder: widget.placeholder,
            count: '${widget.items.length}',
            onQuery: (v) => setState(() => _query = v),
          ),
        ),
        if (widget.items.isEmpty)
          SliverToBoxAdapter(
            child: WaveEmpty(
              icon: widget.emptyIcon,
              title: widget.emptyTitle,
              subtitle: _emptyHint,
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 180,
                mainAxisSpacing: 18,
                crossAxisSpacing: 18,
                childAspectRatio: 0.74,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) {
                  final item = items[i];
                  return _Tile(
                    title: widget.titleOf(item),
                    subtitle: widget.subtitleOf(item),
                    artworkUrl: widget.artworkOf(item),
                    circle: widget.circle,
                    onTap: () =>
                        setState(() => _openTitle = widget.titleOf(item)),
                  );
                },
                childCount: items.length,
              ),
            ),
          ),
      ],
    );
  }
}

class LibraryAlbumsView extends ConsumerWidget {
  const LibraryAlbumsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albums = groupLibraryAlbums(ref.watch(libraryTracksProvider));
    return _GridBrowser<LibraryAlbum>(
      items: albums,
      placeholder: 'Search albums',
      titleOf: (a) => a.title,
      subtitleOf: (a) => a.artist,
      artworkOf: (a) => a.artworkUrl,
      tracksOf: (a) => a.tracks,
      emptyIcon: WaveIcons.albums,
      emptyTitle: 'No albums yet',
    );
  }
}

class LibraryArtistsView extends ConsumerWidget {
  const LibraryArtistsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artists = groupLibraryArtists(ref.watch(libraryTracksProvider));
    return _GridBrowser<LibraryArtist>(
      items: artists,
      placeholder: 'Search artists',
      titleOf: (a) => a.name,
      subtitleOf: (a) => _songs(a.tracks.length),
      artworkOf: (a) => a.artworkUrl,
      tracksOf: (a) => a.tracks,
      circle: true,
      emptyIcon: WaveIcons.artists,
      emptyTitle: 'No artists yet',
    );
  }
}

/// Your own playlists (not Liked Songs or the Local songs folder index):
/// create, open, rename, delete, remove songs. Songs are added from any
/// song's menu > Add to playlist, and Library songs keep playing from file.
class LibraryPlaylistsView extends ConsumerStatefulWidget {
  const LibraryPlaylistsView({super.key});

  @override
  ConsumerState<LibraryPlaylistsView> createState() =>
      _LibraryPlaylistsViewState();
}

String _coverOf(SavedPlaylist p) => p.customCoverUri.isNotEmpty
    ? p.customCoverUri
    : (p.tracks.where((t) => t.artworkUrl.isNotEmpty).firstOrNull?.artworkUrl ??
        '');

class _LibraryPlaylistsViewState extends ConsumerState<LibraryPlaylistsView> {
  int? _openId;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final mine = [
      for (final p in ref.watch(playlistRepositoryProvider))
        if (!p.isLikedSongs && !p.isLocal) p,
    ];
    final open = mine.where((p) => p.id == _openId).firstOrNull;
    if (open != null) {
      return LibrarySongsView(
        key: ValueKey(open.id),
        tracks: open.tracks,
        sourceLabel: open.title,
        // PlaylistRepository keys rows by name|artist.
        onRemove: (t) => ref.read(playlistRepositoryProvider.notifier).removeTrack(
            open.id, '${t.name.toLowerCase()}|${t.artist.toLowerCase()}'),
        header: _DetailHeader(
          title: open.title,
          subtitle: 'Playlist · ${_songs(open.tracks.length)}',
          artworkUrl: _coverOf(open),
          tracks: open.tracks,
          onBack: () => setState(() => _openId = null),
          actions: [
            WaveGhostButton(
              label: 'Rename',
              icon: FluentIcons.rename,
              onPressed: () => showWaveRenamePlaylist(context, ref, open),
            ),
            WaveGhostButton(
              label: 'Delete',
              icon: FluentIcons.delete,
              onPressed: () async {
                await showWaveDeletePlaylist(context, ref, open);
                if (mounted &&
                    !ref
                        .read(playlistRepositoryProvider)
                        .any((p) => p.id == open.id)) {
                  setState(() => _openId = null);
                }
              },
            ),
          ],
        ),
      );
    }
    final q = _query.trim().toLowerCase();
    final shown = [
      for (final p in mine)
        if (q.isEmpty || p.title.toLowerCase().contains(q)) p,
    ];
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextBox(
                    placeholder: 'Search playlists',
                    prefix: const Padding(
                      padding: EdgeInsets.only(left: 10),
                      child: Icon(WaveIcons.search, size: 14),
                    ),
                    onChanged: (v) => setState(() => _query = v),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: () => showWaveCreatePlaylist(context, ref),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(FluentIcons.add, size: 12),
                      SizedBox(width: 8),
                      Text('New playlist'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (mine.isEmpty)
          SliverToBoxAdapter(
            child: WaveEmpty(
              icon: WaveIcons.playlists,
              title: 'No playlists yet',
              subtitle: "Create one, then add songs from any song's menu "
                  '(right-click > Add to playlist).',
              actionLabel: 'New playlist',
              onAction: () => showWaveCreatePlaylist(context, ref),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 180,
                mainAxisSpacing: 18,
                crossAxisSpacing: 18,
                childAspectRatio: 0.74,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) {
                  final p = shown[i];
                  return _Tile(
                    title: p.title,
                    subtitle: _songs(p.tracks.length),
                    artworkUrl: _coverOf(p),
                    onTap: () => setState(() => _openId = p.id),
                  );
                },
                childCount: shown.length,
              ),
            ),
          ),
      ],
    );
  }
}
