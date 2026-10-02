import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/innertube/innertube_api.dart';
import '../../features/innertube/yt_library_providers.dart';
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
        showWaveRenamePlaylist;
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

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
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
                    itemBuilder: (context, i) =>
                        WaveEntrance(
                      index: i,
                      rise: 10,
                      child: _PlaylistCard(
                        playlist: shown[i],
                        artSize: 160,
                      ),
                    ),
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
    void play() => context.go('/ytplaylist/${p.id}'
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
          duration: WaveMotion.fast,
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: WaveMotion.normal,
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              boxShadow: [
                if (_hover)
                  BoxShadow(
                    color: Colors.black.withValues(
                        alpha: dark ? 0.45 : 0.18),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
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
                        radius: 6,
                        label: p.title),
                    Positioned.fill(
                      child: AnimatedOpacity(
                        opacity: _hover ? 1 : 0,
                        duration: WaveMotion.fast,
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
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Center(
                            child: AnimatedScale(
                              scale: _hover ? 1.0 : 0.70,
                              duration: WaveMotion.fast,
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
                                  child: const Icon(
                                      WaveIcons.play,
                                      size: 18,
                                      color: Colors.white),
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
  const _PlaylistCard(
      {required this.playlist, this.artSize = 150});
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
    void play() => context.go('/playlists/${p.id}');
    return WaveContextMenu(
      items: () => [
        WaveMenuAction(
          leading:
              const Icon(FluentIcons.play, size: 13),
          label: 'Open',
          onPressed: play,
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
        if (!p.isLikedSongs)
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
            duration: WaveMotion.fast,
            curve: Curves.easeOutCubic,
            child: AnimatedContainer(
              duration: WaveMotion.normal,
              curve: Curves.easeOutCubic,
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: _hover
                    ? (waveIsDark(context)
                            ? Colors.white
                            : Colors.black)
                        .withValues(alpha: 0.05)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                boxShadow: [
                  if (_hover)
                    BoxShadow(
                      color: Colors.black.withValues(
                          alpha: dark ? 0.45 : 0.18),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
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
                          radius: 6,
                          label: p.title),
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
                          duration: WaveMotion.fast,
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
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Center(
                              child: AnimatedScale(
                                scale: _hover ? 1.0 : 0.70,
                                duration: WaveMotion.fast,
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
                                    child: const Icon(
                                        WaveIcons.play,
                                        size: 18,
                                        color: Colors.white),
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
                  Text('${p.tracks.length} tracks',
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
