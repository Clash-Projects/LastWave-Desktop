import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../design_system/components.dart';
import '../design_system/icons.dart';

import '../core/audio/stream_models.dart';
import '../features/downloads/download_manager.dart';
import '../features/feed/feed_repository.dart';
import '../features/library/playlists.dart';
import '../features/player/playback_service.dart';
import '../widgets/toast.dart';
import '../widgets/track_tile.dart';

/// Start the queue; the playback service resolves each track on demand.
/// Limusic fast path: videoIds are preserved end-to-end so tracks with
/// a known videoId open instantly (no search, no lyrics/artwork/Last.fm
/// gating before playback).
Future<void> playGenerated(
  WidgetRef ref,
  BuildContext context,
  GeneratedTrack track, {
  String sourceLabel = 'Home',
  List<GeneratedTrack>? queueAll,
  int startIndex = 0,
}) async {
  final player = ref.read(playbackServiceProvider.notifier);
  final list = queueAll ?? [track];
  final index = queueAll == null ? 0 : startIndex;
  await player.playQueue(
    list.map(playableFromGenerated).toList(),
    index,
    sourceLabel: sourceLabel,
  );
}

/// Shared track actions returning shad context-menu items.
/// Right-click and the row "more" button share this single source.
List<TrackMenuItem> trackMenuItems({
  required WidgetRef ref,
  required String title,
  required String artist,
  String artworkUrl = '',
  String videoId = '',
  PlayableTrack? playable,
}) {
  final player = ref.read(playbackServiceProvider.notifier);
  final track = playable ??
      PlayableTrack(
        title: title,
        artist: artist,
        artworkUrl: artworkUrl,
        videoId: videoId,
      );
  final library = ref.read(playlistRepositoryProvider.notifier);
  final liked =
      library.likedKeys().contains(track.queueKey);
  final playlists = ref.read(playlistRepositoryProvider);

  StoredTrack stored() => StoredTrack(
        name: title,
        artist: artist,
        artworkUrl: artworkUrl,
        videoId: track.videoId,
      );

  return [
    TrackMenuItem(
      label: 'Play',
      icon: LucideIcons.play,
      onSelected: () =>
          player.play(track, sourceLabel: 'Context menu'),
    ),
    TrackMenuItem(
      label: 'Play next',
      icon: LucideIcons.plus,
      onSelected: () => player.playNext(track),
    ),
    TrackMenuItem(
      label: 'Add to queue',
      icon: LucideIcons.listPlus,
      onSelected: () => player.addToQueue(track),
    ),
    TrackMenuItem(
      label: liked ? 'Unlike' : 'Like',
      icon: LucideIcons.heart,
      onSelected: () => library.toggleLiked(stored()),
    ),
    TrackMenuItem(
      label: 'Download',
      icon: LucideIcons.download,
      onSelected: () => ref
          .read(downloadManagerProvider.notifier)
          .downloadTrack(title: title, artist: artist),
    ),
    if (playlists.isNotEmpty)
      TrackMenuItem(
        label: 'Add to playlist',
        icon: LucideIcons.listMusic,
        onSelected: () {},
        children: playlists
            .map((p) => TrackMenuItem(
                  label: p.title,
                  icon: p.isLikedSongs
                      ? LucideIcons.heart
                      : LucideIcons.listMusic,
                  onSelected: () => library.addTrack(
                      p.id, stored()),
                ))
            .toList(),
      ),
  ];
}

PlayableTrack playableFromGenerated(GeneratedTrack t) =>
    PlayableTrack(
      title: t.name,
      artist: t.artist,
      artworkUrl: t.artworkUrl,
      videoId: t.videoId,
    );

/// Idempotent like toggle + toast. Returns new liked state.
Future<bool> toggleLike(
  WidgetRef ref,
  BuildContext context, {
  required String title,
  required String artist,
  String artworkUrl = '',
  String videoId = '',
}) async {
  final liked = await ref
      .read(playlistRepositoryProvider.notifier)
      .toggleLiked(StoredTrack(
        name: title,
        artist: artist,
        artworkUrl: artworkUrl,
        videoId: videoId,
      ));
  if (context.mounted) {
    showToast(context,
        liked ? 'Added to Liked Songs' : 'Removed from Liked Songs');
  }
  return liked;
}

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
