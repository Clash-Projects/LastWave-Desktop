import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/prefs.dart';
import '../spotify/spotify_canvas.dart';

class CanvasLookup {
  final String title;
  final String artist;
  final String album;
  final int durationMs;

  const CanvasLookup({
    required this.title,
    required this.artist,
    this.album = '',
    this.durationMs = 0,
  });

  @override
  bool operator ==(Object other) =>
      other is CanvasLookup &&
      other.title == title &&
      other.artist == artist &&
      other.album == album &&
      other.durationMs == durationMs;

  @override
  int get hashCode => Object.hash(title, artist, album, durationMs);
}

/// Spotify canvas, or null so Tidal and other motion art can run.
///
/// Never throws. A signed-out Spotify session is skipped.
final canvasClipProvider =
    FutureProvider.family<String?, CanvasLookup>((ref, query) async {
  final prefs = ref.watch(prefsProvider);
  if (!prefs.spotifyCanvasEnabled) return null;
  try {
    final spotify = await ref.read(spotifyCanvasProvider).search(
          title: query.title,
          artist: query.artist,
          album: query.album,
          durationMs: query.durationMs,
        );
    if (spotify != null && spotify.isNotEmpty) return spotify;
  } catch (_) {}
  return null;
});
