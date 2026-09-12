import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../design_system/icons.dart';

import '../../design_system/components.dart';
import '../../design_system/tokens.dart';
import 'playlists.dart';

/// Library overview: liked, playlists, stats shortcut.
class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(playlistRepositoryProvider);
    final liked = playlists.where((p) => p.isLikedSongs).firstOrNull;
    final customs = playlists.where((p) => !p.isLikedSongs).toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(
          LwSpacing.lg, LwSpacing.lg, LwSpacing.lg, 96),
      children: [
        const Text('Your Library', style: LwType.display),
        const SizedBox(height: LwSpacing.lg),
        Row(
          children: [
            _LibraryCard(
              icon: LwIcons.heart,
              title: 'Liked Songs',
              subtitle:
                  '${liked?.tracks.length ?? 0} tracks',
              onTap: () => context.go('/liked'),
            ),
            const SizedBox(width: LwSpacing.md),
            _LibraryCard(
              icon: LwIcons.download,
              title: 'Downloads',
              subtitle: 'Offline music',
              onTap: () => context.go('/downloads'),
            ),
            const SizedBox(width: LwSpacing.md),
            _LibraryCard(
              icon: LwIcons.history,
              title: 'History',
              subtitle: 'Recently played',
              onTap: () => context.go('/history'),
            ),
          ],
        ),
        const SizedBox(height: LwSpacing.lg),
        SectionHeader(
          title: 'Playlists',
          actionLabel: 'New playlist',
          onAction: () =>
              _createPlaylist(context, ref),
        ),
        const SizedBox(height: LwSpacing.xs),
        if (customs.isEmpty)
          const Padding(
            padding:
                EdgeInsets.symmetric(vertical: LwSpacing.md),
            child: Text(
              'No playlists yet — create one or import from Mix Lab.',
              style: LwType.caption,
            ),
          )
        else
          ...customs.map((p) => ListTile(
                leading: const Icon(
                    LwIcons.listMusic,
                    color: LwColors.textSecondary),
                title: Text(p.title),
                subtitle:
                    Text('${p.tracks.length} tracks'),
                trailing: const Icon(
                    LwIcons.chevronRight,
                    size: 16),
                onTap: () =>
                    context.go('/playlists/${p.id}'),
              )),
      ],
    );
  }

  Future<void> _createPlaylist(
      BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New playlist',
            style: LwType.title),
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

class _LibraryCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _LibraryCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius:
            BorderRadius.circular(LwRadius.md),
        child: Container(
          padding:
              const EdgeInsets.all(LwSpacing.md),
          decoration: BoxDecoration(
            color: LwColors.surfaceRaised,
            borderRadius:
                BorderRadius.circular(LwRadius.md),
            border:
                Border.all(color: LwColors.outlineSoft),
          ),
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              Icon(icon,
                  size: 20,
                  color: Theme.of(context)
                      .colorScheme
                      .primary),
              const SizedBox(height: LwSpacing.sm),
              Text(title, style: LwType.title),
              Text(subtitle,
                  style: LwType.caption.copyWith(
                      color: LwColors.textSecondary)),
            ],
          ),
        ),
      ),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
