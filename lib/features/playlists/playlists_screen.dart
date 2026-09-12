import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../design_system/icons.dart';

import '../../design_system/components.dart';
import '../../design_system/tokens.dart';
import '../library/playlists.dart';

/// User + generated playlists (Liked Songs excluded — it has its own page).
class PlaylistsScreen extends ConsumerWidget {
  const PlaylistsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref
        .watch(playlistRepositoryProvider)
        .where((p) => !p.isLikedSongs)
        .toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(
          LwSpacing.lg, LwSpacing.lg, LwSpacing.lg, 96),
      children: [
        Row(
          children: [
            const Text('Playlists',
                style: LwType.display),
            const Spacer(),
            FilledButton.icon(
              onPressed: () =>
                  _create(context, ref),
              icon: const Icon(LwIcons.plus,
                  size: 15),
              label: const Text('New'),
            ),
          ],
        ),
        const SizedBox(height: LwSpacing.md),
        if (playlists.isEmpty)
          const EmptyState(
            icon: LwIcons.listMusic,
            title: 'No playlists yet',
            subtitle:
                'Create one, or generate a taste mix in Mix Lab.',
          )
        else
          ...playlists.map((p) => ListTile(
                leading:
                    Artwork(url: _coverOf(p), size: 46),
                title: Text(p.title),
                subtitle: Text(
                    '${p.tracks.length} tracks${p.isPinned ? ' · Pinned' : ''}'),
                trailing: const Icon(
                    LwIcons.chevronRight,
                    size: 16),
                onTap: () =>
                    context.go('/playlists/${p.id}'),
              )),
      ],
    );
  }

  String _coverOf(SavedPlaylist p) {
    for (final t in p.tracks) {
      if (t.artworkUrl.isNotEmpty) return t.artworkUrl;
    }
    return '';
  }

  Future<void> _create(
      BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New playlist'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
              hintText: 'Playlist name'),
          onSubmitted: (v) =>
              Navigator.of(context).pop(v.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () =>
                  Navigator.of(context).pop(),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(context)
                  .pop(controller.text.trim()),
              child: const Text('Create')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      final created = await ref
          .read(playlistRepositoryProvider.notifier)
          .createCustom(name);
      if (context.mounted) {
        context.go('/playlists/${created.id}');
      }
    }
  }
}
