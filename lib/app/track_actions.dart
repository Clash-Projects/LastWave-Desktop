import 'package:flutter/material.dart';

import '../core/audio/stream_models.dart';
import '../features/downloads/download_manager.dart';
import '../features/feed/feed_repository.dart';
import '../features/library/playlists.dart';
import '../features/player/playback_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Shared track actions: context menu + helpers used across screens.
Future<void> showTrackMenu({
  required BuildContext context,
  required WidgetRef ref,
  required Offset position,
  required PlayableTrack Function() toPlayable,
  required String title,
  required String artist,
  String artworkUrl = '',
}) async {
  final playlists = ref.read(playlistRepositoryProvider);
  final likedKeys =
      ref.read(playlistRepositoryProvider.notifier).likedKeys();
  final isLiked = likedKeys
      .contains('${title.toLowerCase()}|${artist.toLowerCase()}');
  final choice = await showMenu<String>(
    context: context,
    position: RelativeRect.fromLTRB(
      position.dx,
      position.dy,
      position.dx + 1,
      position.dy + 1,
    ),
    items: [
      const PopupMenuItem(value: 'play', child: Text('Play')),
      const PopupMenuItem(value: 'next', child: Text('Play next')),
      const PopupMenuItem(
          value: 'queue', child: Text('Add to queue')),
      PopupMenuItem(
        value: 'like',
        child: Text(isLiked ? 'Unlike' : 'Like'),
      ),
      const PopupMenuItem(
          value: 'download', child: Text('Download')),
      const PopupMenuDivider(),
      ...playlists.map((p) => PopupMenuItem(
            value: 'pl:${p.id}',
            child: Text('Add to ${p.title}',
                maxLines: 1, overflow: TextOverflow.ellipsis),
          )),
    ],
  );
  if (choice == null || !context.mounted) return;
  final player = ref.read(playbackServiceProvider.notifier);
  final track = toPlayable();
  switch (choice) {
    case 'play':
      await player.play(track, sourceLabel: 'Context menu');
      break;
    case 'next':
      await player.playNext(track);
      break;
    case 'queue':
      await player.addToQueue(track);
      break;
    case 'like':
      await ref
          .read(playlistRepositoryProvider.notifier)
          .toggleLiked(StoredTrack(
            name: title,
            artist: artist,
            artworkUrl: artworkUrl,
            videoId: track.videoId,
          ));
      break;
    case 'download':
      await ref
          .read(downloadManagerProvider.notifier)
          .downloadTrack(title: title, artist: artist);
      break;
    default:
      if (choice.startsWith('pl:')) {
        final id = int.tryParse(choice.substring(3));
        if (id != null) {
          await ref
              .read(playlistRepositoryProvider.notifier)
              .addTrack(
                id,
                StoredTrack(
                  name: title,
                  artist: artist,
                  artworkUrl: artworkUrl,
                  videoId: track.videoId,
                ),
              );
        }
      }
  }
}

PlayableTrack playableFromGenerated(GeneratedTrack t) =>
    PlayableTrack(
      title: t.name,
      artist: t.artist,
      artworkUrl: t.artworkUrl,
      videoId: t.videoId,
    );

String formatDuration(Duration d) {
  final total = d.inSeconds.clamp(0, 1 << 31);
  final m = total ~/ 60;
  final s = total % 60;
  if (d.inHours > 0) {
    return '${d.inHours}:${(m % 60).toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
  return '$m:${s.toString().padLeft(2, '0')}';
}

String relativeTime(DateTime dt) {
  final diff = DateTime.now().difference(dt);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  return '${diff.inDays}d ago';
}
