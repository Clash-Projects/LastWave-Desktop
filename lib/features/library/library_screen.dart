import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design_system/components.dart';
import '../../design_system/icons.dart';
import '../../design_system/tokens.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/section.dart';
import '../../widgets/track_tile.dart';
import 'playlists.dart';

/// Editorial library: masthead + shortcut ledger + playlist ledger.
/// Replaces shortcut cards + boxed rows with flat ledger hierarchy.
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});
  @override
  ConsumerState<LibraryScreen> createState() =>
      _LibraryScreenState();
}

class _LibraryScreenState
    extends ConsumerState<LibraryScreen> {
  final _filter = TextEditingController();
  String _q = '';

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playlists = ref.watch(playlistRepositoryProvider);
    final liked = playlists.where((p) => p.isLikedSongs).firstOrNull;
    final customs = playlists
        .where((p) => !p.isLikedSongs)
        .where((p) => p.title
            .toLowerCase()
            .contains(_q.toLowerCase()))
        .toList();
    final dark = Theme.of(context).brightness == Brightness.dark;

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
                title: 'Your Library',
                meta:
                    '${customs.length} playlists · ${liked?.tracks.length ?? 0} liked tracks',
                artworkUrl: _coverOf(
                    liked ?? customs.firstOrNull),
                fallbackIcon: LucideIcons.library,
                primaryActions: [
                  LwButton(
                    onPressed: () =>
                        createPlaylistDialog(
                            context, ref),
                    leading: const Icon(
                        LucideIcons.plus,
                        size: 14),
                    child: const Text('New playlist'),
                  ),
                ],
              ),
              const SizedBox(height: LwSpacing.lg),
              const EdKicker('Shortcuts'),
              const SizedBox(height: LwSpacing.xs),
              _ShortcutLedger(
                icon: LucideIcons.heart,
                title: 'Liked Songs',
                meta:
                    '${liked?.tracks.length ?? 0} tracks',
                onTap: () => context.go('/liked'),
              ),
              _ShortcutLedger(
                icon: LucideIcons.download,
                title: 'Downloads',
                meta: 'Offline music',
                onTap: () =>
                    context.go('/downloads'),
              ),
              _ShortcutLedger(
                icon: LucideIcons.history,
                title: 'History',
                meta: 'Recently played',
                onTap: () =>
                    context.go('/history'),
              ),
              const SizedBox(height: LwSpacing.lg),
              Row(
                children: [
                  const EdKicker('Playlists'),
                  const Spacer(),
                  Text('${customs.length}',
                      style: LwType.caption.copyWith(
                          color: dark
                              ? LwColors.textTertiary
                              : LwColors
                                  .lightTextTertiary,
                          fontFeatures: const [
                            FontFeature
                                .tabularFigures()
                          ])),
                ],
              ),
              const SizedBox(height: LwSpacing.xs),
              LedgerFilterBar(
                controller: _filter,
                onChanged: (v) =>
                    setState(() => _q = v),
                hint: 'Filter playlists…',
              ),
              const SizedBox(height: LwSpacing.xs),
              const EdLedgerHeader(
                  metaLabel: 'Tracks'),
              if (customs.isEmpty)
                Padding(
                  padding:
                      const EdgeInsets.symmetric(
                          vertical: LwSpacing.md),
                  child: EmptyState(
                    icon: LucideIcons.listMusic,
                    title: _q.isEmpty
                        ? 'No playlists yet'
                        : 'No matches',
                    subtitle: _q.isEmpty
                        ? 'Create your first playlist to organise what you love.'
                        : 'No playlists match "$_q".',
                    actionLabel: _q.isEmpty
                        ? 'Create playlist'
                        : null,
                    onAction: _q.isEmpty
                        ? () => createPlaylistDialog(
                            context, ref)
                        : null,
                  ),
                )
              else
                ...customs.asMap().entries.map((e) {
                  final p = e.value;
                  return TrackTile(
                    index: e.key + 1,
                    title: p.title,
                    subtitle:
                        '${p.tracks.length} tracks${p.isPinned ? ' · Pinned' : ''}',
                    artworkUrl: _coverOf(p),
                    onTap: () => context
                        .go('/playlists/${p.id}'),
                    menu: _playlistMenu(
                        context, ref, p),
                  );
                }),
            ],
          ),
        ),
      ],
    );
  }

  String _coverOf(SavedPlaylist? p) {
    if (p == null) {
      return '';
    }
    for (final t in p.tracks) {
      if (t.artworkUrl.isNotEmpty) {
        return t.artworkUrl;
      }
    }
    return '';
  }
}

List<TrackMenuItem> _playlistMenu(
    BuildContext context, WidgetRef ref, SavedPlaylist p) {
  final repo = ref.read(playlistRepositoryProvider.notifier);
  return [
    TrackMenuItem(
      label: 'Open',
      icon: LucideIcons.chevronRight,
      onSelected: () => context.go('/playlists/${p.id}'),
    ),
    TrackMenuItem(
      label: p.isPinned ? 'Unpin' : 'Pin',
      icon: LucideIcons.pin,
      onSelected: () => repo.setPinned(p.id, !p.isPinned),
    ),
    TrackMenuItem(
      label: 'Rename',
      icon: LucideIcons.pencil,
      onSelected: () =>
          renamePlaylistDialog(context, ref, p),
    ),
    if (!p.isLikedSongs)
      TrackMenuItem(
        label: 'Delete',
        icon: LucideIcons.trash2,
        onSelected: () =>
            deletePlaylistDialog(context, ref, p),
      ),
  ];
}

class _ShortcutLedger extends StatelessWidget {
  final IconData icon;
  final String title;
  final String meta;
  final VoidCallback onTap;
  const _ShortcutLedger({
    required this.icon,
    required this.title,
    required this.meta,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final accent = Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(LwRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: LwSpacing.sm,
            vertical: LwSpacing.xs),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(
                    LwRadius.sm),
              ),
              child: Icon(icon,
                  size: 18, color: accent),
            ),
            const SizedBox(width: LwSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      style: LwType.title),
                  Text(meta,
                      style: LwType.caption.copyWith(
                          color: dark
                              ? LwColors.textSecondary
                              : LwColors
                                  .lightTextSecondary)),
                ],
              ),
            ),
            const Icon(LucideIcons.chevronRight,
                size: 15,
                color: LwColors.textTertiary),
          ],
        ),
      ),
    );
  }
}

/// Shared playlist dialogs (create / rename / delete) — flat ledger style.
Future<void> createPlaylistDialog(
    BuildContext context, WidgetRef ref) async {
  final controller = TextEditingController();
  final name = await showLwDialog<String>(
    context: context,
    builder: (context) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment:
          CrossAxisAlignment.stretch,
      children: [
        const Text('New playlist',
            style: LwType.headline),
        const SizedBox(height: LwSpacing.sm),
        LwTextField(
          controller: controller,
          hint: 'Playlist name',
          autofocus: true,
          onSubmitted: (v) => Navigator.of(context)
              .pop(v.trim()),
        ),
        const SizedBox(height: LwSpacing.md),
        Row(
          mainAxisAlignment:
              MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () =>
                  Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: LwSpacing.xs),
            LwButton(
              onPressed: () =>
                  Navigator.of(context).pop(
                      controller.text.trim()),
              child: const Text('Create'),
            ),
          ],
        ),
      ],
    ),
  );
  controller.dispose();
  if (name != null && name.isNotEmpty) {
    final created = await ref
        .read(playlistRepositoryProvider.notifier)
        .createCustom(name);
    if (context.mounted) {
      showToast(context, 'Playlist created.');
      context.go('/playlists/${created.id}');
    }
  }
}

Future<void> renamePlaylistDialog(BuildContext context,
    WidgetRef ref, SavedPlaylist playlist) async {
  final controller =
      TextEditingController(text: playlist.title);
  final name = await showLwDialog<String>(
    context: context,
    builder: (context) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment:
          CrossAxisAlignment.stretch,
      children: [
        const Text('Rename playlist',
            style: LwType.headline),
        const SizedBox(height: LwSpacing.sm),
        LwTextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (v) => Navigator.of(context)
              .pop(v.trim()),
        ),
        const SizedBox(height: LwSpacing.md),
        Row(
          mainAxisAlignment:
              MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () =>
                  Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: LwSpacing.xs),
            LwButton(
              onPressed: () =>
                  Navigator.of(context).pop(
                      controller.text.trim()),
              child: const Text('Save'),
            ),
          ],
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

Future<void> deletePlaylistDialog(BuildContext context,
    WidgetRef ref, SavedPlaylist playlist) async {
  final confirm = await showLwDialog<bool>(
    context: context,
    builder: (context) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment:
          CrossAxisAlignment.stretch,
      children: [
        const Text('Delete playlist?',
            style: LwType.headline),
        const SizedBox(height: 4),
        Text(
            '"${playlist.title}" will be removed from your library.',
            style: LwType.caption),
        const SizedBox(height: LwSpacing.md),
        Row(
          mainAxisAlignment:
              MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () =>
                  Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: LwSpacing.xs),
            LwButton(
              danger: true,
              onPressed: () =>
                  Navigator.of(context).pop(true),
              child: const Text('Delete'),
            ),
          ],
        ),
      ],
    ),
  );
  if (confirm == true) {
    await ref
        .read(playlistRepositoryProvider.notifier)
        .delete(playlist.id);
    if (context.mounted) {
      showToast(context, 'Playlist deleted.');
      context.go('/playlists');
    }
  }
}
