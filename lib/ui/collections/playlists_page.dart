import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/search/shared_providers.dart';
import '../../features/innertube/innertube_api.dart';
import '../../features/innertube/yt_library_providers.dart';
import '../../features/library/local_music_library.dart';
import '../../features/library/playlists.dart';
import '../components/artwork.dart';
import '../components/buttons.dart';
import '../components/hero.dart';
import '../components/menus.dart';
import '../components/states.dart';
import 'playlist_dialogs.dart'
    show
        showWaveCreatePlaylist,
        showWaveDeletePlaylist,
        showWaveImportPlaylist,
        showWaveRenamePlaylist;
import '../navigation/wave_nav.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

/// Playlists browser: hero + filter + cover grid (never track rows).
class WavePlaylistsPage extends ConsumerStatefulWidget {
  const WavePlaylistsPage({super.key});

  @override
  ConsumerState<WavePlaylistsPage> createState() =>
      _WavePlaylistsPageState();
}

class _WavePlaylistsPageState
    extends ConsumerState<WavePlaylistsPage> {
  final _filter = TextEditingController();
  String _q = '';
  bool _selecting = false;
  final Set<int> _selected = {};

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  Future<void> _deleteSelected() async {
    final doomed = ref
        .read(playlistRepositoryProvider)
        .where((p) =>
            _selected.contains(p.id) && !p.isLikedSongs && !p.isLocal)
        .toList();
    if (doomed.isEmpty || !mounted) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => ContentDialog(
        title: const Text('Delete playlists?'),
        content: Text(
          '${doomed.length} playlist${doomed.length == 1 ? '' : 's'} will be removed. Liked Songs and Local songs stay.',
        ),
        actions: [
          WaveButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          WaveFilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    final repo = ref.read(playlistRepositoryProvider.notifier);
    for (final playlist in doomed) {
      await repo.delete(playlist.id);
    }
    if (!mounted) return;
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final all = ref
        .watch(playlistRepositoryProvider)
        .where((p) => !p.isLikedSongs)
        .toList();
    final shown = all
        .where(
          (p) =>
              p.title.toLowerCase().contains(_q.toLowerCase()),
        )
        .toList();
    // Signed-in YouTube Music playlists (own + liked), read-only.
    // Rendered as their own section below the local grid.
    final ytLists = (ref.watch(ytAccountPlaylistsProvider).value ??
            const [])
        .where(
          (p) =>
              p.title.toLowerCase().contains(_q.toLowerCase()),
        )
        .toList();
    // Full-width, left-aligned like the Liked/table pages — the grid
    // below fills the viewport instead of bunching in a centered cap.
    return WaveEntranceGroup(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        children: [
        ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: WaveDensity.contentMax,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              WaveEntrance(
                rise: 10,
                child: WaveCollectionHero(
                overline: 'Collect',
                title: 'Playlists',
                meta: '${all.length} playlists',
                fallbackIcon: FluentIcons.list_mirrored,
                primaryActions: [
                  WavePrimaryButton(
                    label: 'New',
                    icon: FluentIcons.add,
                    onPressed: () =>
                        showWaveCreatePlaylist(
                      context,
                      ref,
                    ),
                  ),
                  WaveGhostButton(
                    label: 'Import',
                    icon: FluentIcons.download,
                    onPressed: () =>
                        showWaveImportPlaylist(
                      context,
                      ref,
                    ),
                  ),
                  if (_selecting) ...[
                    WaveGhostButton(
                      label: 'Delete',
                      icon: FluentIcons.delete,
                      onPressed:
                          _selected.isEmpty ? null : _deleteSelected,
                    ),
                    WaveGhostButton(
                      label: 'Done',
                      icon: FluentIcons.check_mark,
                      onPressed: () => setState(() {
                        _selecting = false;
                        _selected.clear();
                      }),
                    ),
                  ] else
                    WaveGhostButton(
                      label: 'Select',
                      icon: FluentIcons.multi_select,
                      onPressed: () =>
                          setState(() => _selecting = true),
                    ),
                ],
              ),
              ),
              const SizedBox(height: 12),
              WaveFilterBar(
                controller: _filter,
                onChanged: (v) =>
                    setState(() => _q = v),
                hint: 'Filter playlists…',
                countLabel: '${shown.length} shown',
              ),
              const SizedBox(height: 12),
              const _LocalFolders(),
              const SizedBox(height: 18),
              if (shown.isEmpty && ytLists.isEmpty)
                WaveEmpty(
                  icon: FluentIcons.list_mirrored,
                  title: 'No playlists yet',
                  subtitle: _q.isEmpty
                      ? 'Create your first playlist to organise what you love.'
                      : 'No playlists match "$_q".',
                  actionLabel:
                      _q.isEmpty ? 'Create playlist' : null,
                  onAction: _q.isEmpty
                      ? () => showWaveCreatePlaylist(
                          context, ref)
                      : null,
                )
              else ...[
                if (shown.isNotEmpty)
                  // Same density as the Albums page: max 180px cells,
                  // fixed 160 art, 218 rows — grids match across pages.
                  GridView.builder(
                    shrinkWrap: true,
                    physics:
                        const NeverScrollableScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 180,
                      mainAxisSpacing: 16,
                      crossAxisSpacing: 12,
                      mainAxisExtent: 218,
                    ),
                    itemCount: shown.length,
                    itemBuilder: (context, i) {
                      final playlist = shown[i];
                      final protected =
                          playlist.isLikedSongs || playlist.isLocal;
                      return WaveEntrance(
                      index: i,
                      rise: 10,
                      child: _PlaylistCard(
                        playlist: playlist,
                        artSize: 160,
                        selecting: _selecting && !protected,
                        selected: _selected.contains(playlist.id),
                        onSelect: () => setState(() {
                          if (!_selected.add(playlist.id)) {
                            _selected.remove(playlist.id);
                          }
                        }),
                      ),
                    );
                    },
                  ),
                if (ytLists.isNotEmpty) ...[
                  if (shown.isNotEmpty)
                    const SizedBox(height: 18),
                  _YtSection(lists: ytLists),
                ],
              ],
            ],
          ),
        ),
      ],
      ),
    );
  }
}

String? _coverOf(SavedPlaylist p) {
  if (p.customCoverUri.isNotEmpty) return p.customCoverUri;
  for (final t in p.tracks) {
    if (t.artworkUrl.isNotEmpty) return t.artworkUrl;
  }
  return null;
}

/// YouTube Music account playlists (own + liked). Read-only grid
/// mirroring the local cards; tap opens the YT detail page.
class _YtSection extends StatelessWidget {
  final List<YouTubePlaylistSummary> lists;
  const _YtSection({required this.lists});
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('YOUTUBE MUSIC',
            style: WaveType.overline
                .copyWith(color: waveAccent(context))),
        const SizedBox(height: 2),
        Text(
            '${lists.length} ${lists.length == 1 ? 'playlist' : 'playlists'}',
            style: WaveType.meta
                .copyWith(color: waveTextTertiary(context))),
        const SizedBox(height: 6),
        // Same density as the Albums page (see above).
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate:
              const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 180,
            mainAxisSpacing: 16,
            crossAxisSpacing: 12,
            mainAxisExtent: 218,
          ),
          itemCount: lists.length,
          itemBuilder: (context, i) => WaveEntrance(
            index: i,
            rise: 10,
            child:
                _YtCard(index: i, lists: lists, artSize: 160),
          ),
        ),
      ],
    );
  }
}

/// Single YouTube Music playlist card (art fills the grid cell).
class _YtCard extends ConsumerStatefulWidget {
  final int index;
  final List<YouTubePlaylistSummary> lists;
  final double artSize;
  const _YtCard(
      {required this.index,
      required this.lists,
      required this.artSize});

  @override
  ConsumerState<_YtCard> createState() => _YtCardState();
}

class _YtCardState extends ConsumerState<_YtCard> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final p = widget.lists[widget.index];
    void play() => waveOpen(context, '/ytplaylist/${p.id}'
        '?title=${Uri.encodeComponent(p.title)}'
        '&art=${Uri.encodeComponent(p.artworkUrl)}');
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _pressed = false;
      }),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: play,
        child: AnimatedScale(
          scale: _pressed ? 0.97 : (_hover ? 1.03 : 1.0),
          duration: waveMotion(context, WaveMotion.fast),
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: waveMotion(context, WaveMotion.normal),
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              borderRadius: WaveRadius.artworkRadius,
              boxShadow: [
                if (_hover) ...WaveElevation.lift(dark),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(
                  children: [
                    WaveArtwork(
                        url: p.artworkUrl,
                        size: widget.artSize,
                        radius: WaveRadius.artwork,
                        label: p.title),
                    Positioned.fill(
                      child: AnimatedOpacity(
                        opacity: _hover ? 1 : 0,
                        duration: waveMotion(context, WaveMotion.fast),
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.transparent,
                                Colors.black.withValues(alpha: 0.55),
                              ],
                            ),
                            borderRadius: WaveRadius.artworkRadius,
                          ),
                          child: Center(
                            child: AnimatedScale(
                              scale: _hover ? 1.0 : 0.70,
                              duration: waveMotion(context, WaveMotion.fast),
                              curve: Curves.easeOutBack,
                              child: GestureDetector(
                                onTap: play,
                                child: Container(
                                  width: 44,
                                  height: 44,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: waveAccent(context),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black
                                            .withValues(alpha: 0.4),
                                        blurRadius: 12,
                                      ),
                                    ],
                                  ),
                                  child: Icon(
                                      WaveIcons.play,
                                      size: 18,
                                      color: waveOnAccent(context)),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 6),
                  Text(p.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: WaveType.trackTitle
                          .copyWith(fontSize: 12.5)),
                  Text(
                      p.trackCountText.isNotEmpty
                          ? p.trackCountText
                          : 'YouTube playlist',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          WaveType.meta.copyWith(fontSize: 11.5)),
                ],
              ),
            ),
          ),
        ),
      );
  }
}

class _PlaylistCard extends ConsumerStatefulWidget {
  final SavedPlaylist playlist;
  final double artSize;
  final bool selecting;
  final bool selected;
  final VoidCallback? onSelect;
  const _PlaylistCard({
    required this.playlist,
    this.artSize = 150,
    this.selecting = false,
    this.selected = false,
    this.onSelect,
  });
  @override
  ConsumerState<_PlaylistCard> createState() =>
      _PlaylistCardState();
}

class _PlaylistCardState
    extends ConsumerState<_PlaylistCard> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.playlist;
    final dark = waveIsDark(context);
    final cover = _coverOf(p);
    void open() => context.go('/playlists/${p.id}');
    void play() {
      if (widget.selecting) {
        widget.onSelect?.call();
        return;
      }
      open();
    }
    return WaveContextMenu(
      items: () => [
        WaveMenuAction(
          leading:
              const Icon(FluentIcons.play, size: 13),
          label: 'Open',
          onPressed: open,
        ),
        WaveMenuAction(
          leading: Icon(
              p.isPinned
                  ? FluentIcons.pinned
                  : FluentIcons.pin,
              size: 13),
          label: p.isPinned ? 'Unpin' : 'Pin',
          onPressed: () => ref
              .read(playlistRepositoryProvider.notifier)
              .setPinned(p.id, !p.isPinned),
        ),
        WaveMenuAction(
          leading:
              const Icon(FluentIcons.edit, size: 13),
          label: 'Rename',
          onPressed: () => showWaveRenamePlaylist(
              context, ref, p),
        ),
        if (!p.isLikedSongs && !p.isLocal)
          WaveMenuAction(
            leading: const Icon(FluentIcons.delete,
                size: 13),
            label: 'Delete',
            onPressed: () => showWaveDeletePlaylist(
                context, ref, p),
          ),
      ],
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() {
          _hover = false;
          _pressed = false;
        }),
        child: GestureDetector(
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onTap: play,
          child: AnimatedScale(
            scale: _pressed ? 0.97 : (_hover ? 1.03 : 1.0),
            duration: waveMotion(context, WaveMotion.fast),
            curve: Curves.easeOutCubic,
            child: AnimatedContainer(
              duration: waveMotion(context, WaveMotion.normal),
              curve: Curves.easeOutCubic,
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: _hover
                    ? (waveIsDark(context)
                            ? Colors.white
                            : Colors.black)
                        .withValues(alpha: 0.05)
                    : Colors.transparent,
                borderRadius: WaveRadius.artworkRadius,
                border: widget.selected
                    ? Border.all(color: waveAccent(context), width: 2)
                    : null,
                boxShadow: [
                  if (_hover) ...WaveElevation.lift(dark),
                ],
              ),
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  Stack(
                    children: [
                      WaveArtwork(
                          url: cover ?? '',
                          size: widget.artSize,
                          radius: WaveRadius.artwork,
                          label: p.title),
                      if (widget.selecting)
                        Positioned(
                          right: 8,
                          top: 8,
                          child: Icon(
                            widget.selected
                                ? FluentIcons.checkbox_composite
                                : FluentIcons.checkbox,
                            size: 18,
                            color: Colors.white,
                          ),
                        ),
                      if (p.isPinned)
                        Positioned(
                          left: 6,
                          top: 6,
                          child: Container(
                            padding:
                                const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 3),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(
                                  alpha: 0.7),
                              borderRadius:
                                  BorderRadius.circular(
                                      999),
                            ),
                            child: const Text('PINNED',
                                style: TextStyle(
                                    fontSize: 9,
                                    fontWeight:
                                        FontWeight.w700,
                                    letterSpacing: 0.6,
                                    color: Colors.white)),
                          ),
                        ),
                      Positioned.fill(
                        child: AnimatedOpacity(
                          opacity: _hover ? 1 : 0,
                          duration: waveMotion(context, WaveMotion.fast),
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.transparent,
                                  Colors.black.withValues(alpha: 0.55),
                                ],
                              ),
                              borderRadius: WaveRadius.artworkRadius,
                            ),
                            child: Center(
                              child: AnimatedScale(
                                scale: _hover ? 1.0 : 0.70,
                                duration: waveMotion(context, WaveMotion.fast),
                                curve: Curves.easeOutBack,
                                child: GestureDetector(
                                  onTap: play,
                                  child: Container(
                                    width: 44,
                                    height: 44,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: waveAccent(context),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black
                                              .withValues(alpha: 0.4),
                                          blurRadius: 12,
                                        ),
                                      ],
                                    ),
                                    child: Icon(
                                        WaveIcons.play,
                                        size: 18,
                                        color: waveOnAccent(context)),
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
                  Text(p.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: WaveType.trackTitle
                          .copyWith(fontSize: 12.5)),
                  Text(
                      p.isLocal
                          ? 'On this PC · ${p.tracks.length} tracks'
                          : '${p.tracks.length} tracks',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: WaveType.meta
                          .copyWith(fontSize: 11.5)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LocalFolders extends ConsumerWidget {
  const _LocalFolders();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folders = ref.watch(databaseProvider).localFolders();
    final scan = ref.watch(localScanProvider);
    final busy = scan.running;

    Future<void> add() async {
      final path = await FilePicker.getDirectoryPath(
        dialogTitle: 'Add a music folder',
      );
      if (path == null || path.trim().isEmpty) return;
      await ref.read(localMusicLibraryProvider).addFolder(path.trim());
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'ON THIS PC',
          style: WaveType.overline.copyWith(color: waveAccent(context)),
        ),
        const SizedBox(height: 2),
        Text(
          busy
              ? scan.label
              : (scan.label.isEmpty
                  ? 'Play files from folders you choose. Local songs stay on this PC and are never uploaded.'
                  : scan.label),
          style: WaveType.meta.copyWith(color: waveTextSecondary(context)),
        ),
        const SizedBox(height: 8),
        for (final folder in folders)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    folder,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: WaveType.trackTitle,
                  ),
                ),
                WaveGhostButton(
                  label: 'Forget',
                  onPressed: busy
                      ? null
                      : () => ref
                          .read(localMusicLibraryProvider)
                          .forgetFolder(folder),
                ),
              ],
            ),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            WaveGhostButton(
              label: 'Add folder',
              icon: FluentIcons.add,
              onPressed: busy ? null : add,
            ),
            WaveGhostButton(
              label: 'Rescan',
              icon: FluentIcons.refresh,
              onPressed: busy
                  ? null
                  : () => ref.read(localMusicLibraryProvider).rescan(),
            ),
            if (busy)
              const SizedBox(
                width: 16,
                height: 16,
                child: ProgressRing(strokeWidth: 2),
              ),
          ],
        ),
      ],
    );
  }
}
