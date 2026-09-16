import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/library/playlists.dart';
import '../components/artwork.dart';
import '../components/buttons.dart';
import '../components/hero.dart';
import '../components/menus.dart';
import '../components/states.dart';
import '../library/library_page.dart'
    show
        showWaveCreatePlaylist,
        showWaveDeletePlaylist,
        showWaveRenamePlaylist;
import '../theme/motion.dart';
import '../theme/tokens.dart';

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
                artworkSize: 120,
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
              if (shown.isEmpty)
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
              else
                LayoutBuilder(builder: (context, c) {
                  final cols =
                      (c.maxWidth / 170).floor().clamp(2, 6);
                  return GridView.builder(
                    shrinkWrap: true,
                    physics:
                        const NeverScrollableScrollPhysics(),
                    gridDelegate:
                        SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: cols,
                      mainAxisSpacing: 16,
                      crossAxisSpacing: 12,
                      mainAxisExtent: 214,
                    ),
                    itemCount: shown.length,
                    itemBuilder: (context, i) =>
                        WaveEntrance(
                      index: i,
                      rise: 10,
                      child: _PlaylistCard(
                          playlist: shown[i]),
                    ),
                  );
                }),
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

class _PlaylistCard extends ConsumerStatefulWidget {
  final SavedPlaylist playlist;
  const _PlaylistCard({required this.playlist});
  @override
  ConsumerState<_PlaylistCard> createState() =>
      _PlaylistCardState();
}

class _PlaylistCardState
    extends ConsumerState<_PlaylistCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.playlist;
    final cover = _coverOf(p);
    return WaveContextMenu(
      items: () => [
        MenuFlyoutItem(
          leading:
              const Icon(FluentIcons.play, size: 13),
          text: const Text('Open'),
          onPressed: () =>
              context.go('/playlists/${p.id}'),
        ),
        MenuFlyoutItem(
          leading: Icon(
              p.isPinned
                  ? FluentIcons.pinned
                  : FluentIcons.pin,
              size: 13),
          text: Text(p.isPinned ? 'Unpin' : 'Pin'),
          onPressed: () => ref
              .read(playlistRepositoryProvider.notifier)
              .setPinned(p.id, !p.isPinned),
        ),
        MenuFlyoutItem(
          leading:
              const Icon(FluentIcons.edit, size: 13),
          text: const Text('Rename'),
          onPressed: () => showWaveRenamePlaylist(
              context, ref, p),
        ),
        if (!p.isLikedSongs)
          MenuFlyoutItem(
            leading: const Icon(FluentIcons.delete,
                size: 13),
            text: const Text('Delete'),
            onPressed: () => showWaveDeletePlaylist(
                context, ref, p),
          ),
      ],
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: () =>
              context.go('/playlists/${p.id}'),
          child: AnimatedContainer(
            duration:
                const Duration(milliseconds: 110),
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: _hover
                  ? (waveIsDark(context)
                          ? Colors.white
                          : Colors.black)
                      .withValues(alpha: 0.05)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Stack(
                  children: [
                    WaveArtwork(
                        url: cover ?? '',
                        size: 150,
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
    );
  }
}
