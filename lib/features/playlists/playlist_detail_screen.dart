import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../design_system/icons.dart';

import '../../design_system/components.dart';
import '../../design_system/tokens.dart';
import '../feed/feed_repository.dart' show GeneratedTrack;
import '../home/home_screen.dart' show playGenerated;
import '../player/playback_service.dart';
import '../library/playlists.dart';

/// Single playlist: artwork header, play-all, rename/pin/delete,
/// per-track remove.
class PlaylistDetailScreen extends ConsumerWidget {
  final int id;
  const PlaylistDetailScreen({super.key, required this.id});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(playlistRepositoryProvider);
    final playlist =
        playlists.where((p) => p.id == id).firstOrNull;
    if (playlist == null) {
      return EmptyState(
        icon: LwIcons.listMusic,
        title: 'Playlist not found',
        subtitle: 'It may have been deleted.',
        actionLabel: 'Back to playlists',
        onAction: () => context.go('/playlists'),
      );
    }
    final tracks = playlist.tracks;
    List<GeneratedTrack> asGenerated() => tracks
        .map((t) => GeneratedTrack(
              name: t.name,
              artist: t.artist,
              artworkUrl: t.artworkUrl,
              videoId: t.videoId,
            ))
        .toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(
          LwSpacing.lg, LwSpacing.lg, LwSpacing.lg, 96),
      children: [
        Row(
          children: [
            Artwork(
                url: tracks.isNotEmpty
                    ? tracks.first.artworkUrl
                    : '',
                size: 120,
                radius: LwRadius.md,
                fallbackIcon: LwIcons.listMusic),
            const SizedBox(width: LwSpacing.lg),
            Expanded(
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  Text(playlist.title,
                      style: LwType.display),
                  const SizedBox(height: 4),
                  Text(
                    '${tracks.length} tracks${playlist.isPinned ? ' · Pinned' : ''}',
                    style: LwType.body.copyWith(
                        color: LwColors.textSecondary),
                  ),
                  const SizedBox(height: LwSpacing.sm),
                  Row(
                    children: [
                      if (tracks.isNotEmpty)
                        FilledButton.icon(
                          onPressed: () =>
                              playGenerated(
                            ref,
                            context,
                            asGenerated().first,
                            sourceLabel: playlist.title,
                            queueAll: asGenerated(),
                          ),
                          icon: const Icon(
                              LwIcons.play,
                              size: 15),
                          label:
                              const Text('Play all'),
                        ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: () =>
                            _rename(context, ref, playlist),
                        icon: const Icon(
                            LwIcons.pencil,
                            size: 14),
                        label: const Text('Rename'),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: () => ref
                            .read(playlistRepositoryProvider
                                .notifier)
                            .setPinned(playlist.id,
                                !playlist.isPinned),
                        icon: Icon(
                            playlist.isPinned
                                ? LwIcons.pinOff
                                : LwIcons.pin,
                            size: 14),
                        label: Text(playlist.isPinned
                            ? 'Unpin'
                            : 'Pin'),
                      ),
                      const SizedBox(width: 8),
                      if (!playlist.isLikedSongs)
                        OutlinedButton.icon(
                          onPressed: () =>
                              _delete(context, ref, playlist),
                          icon: const Icon(
                              LwIcons.trash2,
                              size: 14),
                          label: const Text('Delete'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: LwSpacing.md),
        ...asGenerated().asMap().entries.map((e) {
          final t = e.value;
          final playing = ref
                  .watch(playbackServiceProvider)
                  .current
                  ?.queueKey ==
              t.key;
          return TrackTile(
            title: t.name,
            subtitle: t.artist,
            artworkUrl: t.artworkUrl,
            playing: playing,
            onTap: () => playGenerated(ref, context, t,
                sourceLabel: playlist.title,
                queueAll: asGenerated(),
                startIndex: e.key),
            onMore: () => ref
                .read(
                    playlistRepositoryProvider.notifier)
                .removeTrack(playlist.id, t.key),
          );
        }),
      ],
    );
  }

  Future<void> _rename(BuildContext context, WidgetRef ref,
      SavedPlaylist playlist) async {
    final controller =
        TextEditingController(text: playlist.title);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename playlist'),
        content: TextField(
          controller: controller,
          autofocus: true,
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
              child: const Text('Save')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      await ref
          .read(playlistRepositoryProvider.notifier)
          .rename(playlist.id, name);
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref,
      SavedPlaylist playlist) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete playlist?'),
        content: Text(
            '"${playlist.title}" will be removed from your library.'),
        actions: [
          TextButton(
              onPressed: () =>
                  Navigator.of(context).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () =>
                  Navigator.of(context).pop(true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirm == true) {
      await ref
          .read(playlistRepositoryProvider.notifier)
          .delete(playlist.id);
      if (context.mounted) context.go('/playlists');
    }
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
