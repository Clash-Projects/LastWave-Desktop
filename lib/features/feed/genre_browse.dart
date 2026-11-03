import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../innertube/innertube_api.dart';
import 'feed_repository.dart' show GeneratedTrack;

/// Songs for a Browse Categories tile, straight from YouTube Music's songs
/// search for that genre. The same list backs the tile's cover art (so a
/// genre only ever shows covers of its own songs) and the genre page the
/// tile opens. Empty on any failure; misses are not kept so a retry works.
final genreTracksProvider = FutureProvider.autoDispose
    .family<List<GeneratedTrack>, String>((ref, query) async {
      final tube = ref.watch(innerTubeProvider);
      try {
        final found = await tube.searchSongs('$query songs', limit: 40);
        final tracks = [
          for (final t in found)
            if (t.videoId.isNotEmpty)
              GeneratedTrack(
                name: t.title,
                artist: t.artist,
                album: t.album,
                artworkUrl: t.artworkUrl,
                videoId: t.videoId,
                durationSeconds: t.durationSeconds,
              ),
        ];
        if (tracks.isNotEmpty) ref.keepAlive();
        return tracks;
      } catch (_) {
        return const [];
      }
    });
