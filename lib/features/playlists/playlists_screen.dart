import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design_system/components.dart';
import '../../design_system/icons.dart';
import '../../design_system/tokens.dart';
import '../../widgets/artwork.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/section.dart';
import '../library/library_screen.dart'
    show createPlaylistDialog;
import '../library/playlists.dart';

/// Playlists browser: masthead + filter + cover grid (never track rows).
class PlaylistsScreen extends ConsumerStatefulWidget {
  const PlaylistsScreen({super.key});
  @override
  ConsumerState<PlaylistsScreen> createState() =>
      _PlaylistsScreenState();
}

class _PlaylistsScreenState
    extends ConsumerState<PlaylistsScreen> {
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
    final playlists = all
        .where((p) => p.title
            .toLowerCase()
            .contains(_q.toLowerCase()))
        .toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(
          LwSpacing.xl, LwSpacing.lg, LwSpacing.xl, 96),
      children: [
        EdPage(
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              CollectionHeader(
                kicker: 'Collect',
                title: 'Playlists',
                meta:
                    '${all.length} playlists',
                fallbackIcon:
                    LucideIcons.listMusic,
                artworkSize: 96,
                primaryActions: [
                  LwButton(
                    onPressed: () =>
                        createPlaylistDialog(
                            context, ref),
                    leading: const Icon(
                        LucideIcons.plus,
                        size: 14),
                    child: const Text('New'),
                  ),
                ],
              ),
              const SizedBox(height: LwSpacing.md),
              LedgerFilterBar(
                controller: _filter,
                onChanged: (v) =>
                    setState(() => _q = v),
                hint: 'Filter playlists…',
                countLabel:
                    '${playlists.length} shown',
              ),
              const SizedBox(height: LwSpacing.sm),
              if (playlists.isEmpty)
                EmptyState(
                  icon: LucideIcons.listMusic,
                  title: 'No playlists yet',
                  subtitle: _q.isEmpty
                      ? 'Create your first playlist to organise what you love.'
                      : 'No playlists match "$_q".',
                  actionLabel:
                      _q.isEmpty ? 'Create playlist' : null,
                  onAction: _q.isEmpty
                      ? () => createPlaylistDialog(
                          context, ref)
                      : null,
                )
              else
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
                  itemCount: playlists.length,
                  itemBuilder: (context, i) =>
                      _PlaylistGridCell(
                          playlist: playlists[i]),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PlaylistGridCell extends ConsumerWidget {
  final SavedPlaylist playlist;
  const _PlaylistGridCell({required this.playlist});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    String cover = '';
    for (final t in playlist.tracks) {
      if (t.artworkUrl.isNotEmpty) {
        cover = t.artworkUrl;
        break;
      }
    }
    return InkWell(
      onTap: () =>
          context.go('/playlists/${playlist.id}'),
      borderRadius: BorderRadius.circular(LwRadius.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            children: [
              Artwork(
                  url: cover,
                  size: 160,
                  radius: LwRadius.sm,
                  fallbackIcon: LucideIcons.listMusic),
              if (playlist.isPinned)
                Positioned(
                  left: 6,
                  top: 6,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.black
                          .withValues(alpha: 0.7),
                      borderRadius:
                          BorderRadius.circular(
                              LwRadius.pill),
                    ),
                    child: Text('PINNED',
                        style: LwType.micro.copyWith(
                            color: Colors.white)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(playlist.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: LwType.title
                  .copyWith(fontSize: 12.5)),
          Text(
              '${playlist.tracks.length} tracks',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: LwType.caption
                  .copyWith(fontSize: 11.5)),
        ],
      ),
    );
  }
}
