import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/artwork/animated_artwork_service.dart';
import '../../core/storage/prefs.dart';
import 'spotify_api.dart';
import 'spotify_auth.dart';

/// What the Canvas panel plays for a track.
class CanvasPanelClip {
  final String url;

  /// Provider label shown on the panel ("Spotify", "Apple Music", …).
  final String source;

  /// True when the clip is a real vertical canvas. Square album motion
  /// art is cover-cropped into the 9:16 frame instead.
  final bool vertical;

  const CanvasPanelClip({
    required this.url,
    required this.source,
    required this.vertical,
  });
}

/// A track identity the panel resolves a clip for.
typedef CanvasPanelQuery = ({
  String title,
  String artist,
  String album,
  int durationMs,
});

/// Spotify Canvas first (connected account + toggle on), then the
/// motion-artwork providers the Now Playing cover already uses. Null
/// when nothing has a clip for the track. Successful answers are kept;
/// misses are re-asked next time so a transient failure never sticks.
final canvasPanelClipProvider = FutureProvider.autoDispose
    .family<CanvasPanelClip?, CanvasPanelQuery>((ref, q) async {
  final prefs = ref.watch(prefsProvider);
  final auth = ref.watch(spotifyAuthProvider);

  if (prefs.spotifyCanvasEnabled && auth.connected) {
    final clip = await ref.watch(spotifyApiProvider).canvas(
          title: q.title,
          artist: q.artist,
          durationMs: q.durationMs,
        );
    if (clip != null) {
      ref.keepAlive();
      return CanvasPanelClip(url: clip.url, source: 'Spotify', vertical: true);
    }
  }

  final art = await ref.watch(
    animatedArtworkProvider(
      AnimatedArtworkQuery(
        artist: q.artist,
        album: q.album,
        title: q.title,
      ),
    ).future,
  );
  if (art != null && art.hasUrl) {
    ref.keepAlive();
    final tall = art.urlTall.isNotEmpty;
    return CanvasPanelClip(
      url: tall ? art.urlTall : art.url,
      source: switch (art.source) {
        CanvasSource.apple => 'Apple Music',
        CanvasSource.tidal => 'Tidal',
        CanvasSource.community => 'Community',
      },
      vertical: tall,
    );
  }
  return null;
});
