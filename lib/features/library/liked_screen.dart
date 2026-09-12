import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../design_system/icons.dart';

import '../../app/track_actions.dart';
import '../../design_system/components.dart';
import '../../design_system/tokens.dart';
import '../feed/feed_repository.dart' show GeneratedTrack;
import '../home/home_screen.dart' show playGenerated;
import '../player/playback_service.dart';
import 'playlists.dart';

/// Liked Songs: the pinned `liked` playlist, playable end-to-end.
class LikedScreen extends ConsumerWidget {
  const LikedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(playlistRepositoryProvider);
    final liked =
        playlists.where((p) => p.isLikedSongs).firstOrNull;
    final tracks = liked?.tracks ?? const [];

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
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [
                  Theme.of(context).colorScheme.primary,
                  Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.5),
                ]),
                borderRadius:
                    BorderRadius.circular(LwRadius.md),
              ),
              child: const Icon(LwIcons.heart,
                  color: Colors.white, size: 30),
            ),
            const SizedBox(width: LwSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  const Text('Liked Songs',
                      style: LwType.display),
                  Text('${tracks.length} tracks',
                      style: LwType.body.copyWith(
                          color:
                              LwColors.textSecondary)),
                ],
              ),
            ),
            if (tracks.isNotEmpty)
              FilledButton.icon(
                onPressed: () => playGenerated(
                  ref,
                  context,
                  asGenerated().first,
                  sourceLabel: 'Liked Songs',
                  queueAll: asGenerated(),
                ),
                icon: const Icon(LwIcons.play,
                    size: 15),
                label: const Text('Play all'),
              ),
          ],
        ),
        const SizedBox(height: LwSpacing.md),
        if (tracks.isEmpty)
          const EmptyState(
            icon: LwIcons.heart,
            title: 'No liked songs yet',
            subtitle:
                'Tap the heart on any track to save it here.',
          )
        else
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
                  sourceLabel: 'Liked Songs',
                  queueAll: asGenerated(),
                  startIndex: e.key),
              onMore: () => showTrackMenu(
                context: context,
                ref: ref,
                position: const Offset(800, 300),
                title: t.name,
                artist: t.artist,
                artworkUrl: t.artworkUrl,
                toPlayable: () =>
                    playableFromGenerated(t),
              ),
            );
          }),
      ],
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
