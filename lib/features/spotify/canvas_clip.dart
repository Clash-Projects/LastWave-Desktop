import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/diagnostics/diagnostics_log.dart';
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

/// The panel's answer: a clip, or a note saying why there is none.
class CanvasPanelOutcome {
  final CanvasPanelClip? clip;
  final String note;
  const CanvasPanelOutcome({this.clip, this.note = ''});
}

/// Spotify Canvas first (connected account + toggle on), then the
/// motion-artwork providers the Now Playing cover already uses. Hits are
/// kept; misses are re-asked next time so a transient failure never sticks.
final canvasPanelClipProvider = FutureProvider.autoDispose
    .family<CanvasPanelOutcome, CanvasPanelQuery>((ref, q) async {
      final prefs = ref.watch(prefsProvider);
      final auth = ref.watch(spotifyAuthProvider);
      var note = '';

      if (!prefs.spotifyCanvasEnabled) {
        note = 'Spotify Canvas is switched off in Settings';
        DiagnosticsLog.info('spotify-canvas skipped reason=toggle-off');
      } else {
        // The stored cookie loads asynchronously at startup: wait for it
        // instead of racing it (a lookup before it lands used to fall
        // straight through to the non-Spotify providers and stay cached).
        final hasCookie = await auth.spdc() != null;
        if (!hasCookie) {
          note =
              'Connect Spotify in Settings → Integrations for Spotify Canvas';
          DiagnosticsLog.info('spotify-canvas skipped reason=not-connected');
        } else {
          // Native cleans both before any lookup (video / "official" noise).
          final res = await ref
              .watch(spotifyApiProvider)
              .canvas(
                title: cleanCanvasQuery(q.title),
                artist: cleanCanvasQuery(q.artist),
                durationMs: q.durationMs,
              );
          if (res.clip != null) {
            ref.keepAlive();
            return CanvasPanelOutcome(
              clip: CanvasPanelClip(
                url: res.clip!.url,
                source: 'Spotify',
                vertical: true,
              ),
            );
          }
          note = res.reason;
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
        return CanvasPanelOutcome(
          clip: CanvasPanelClip(
            url: tall ? art.urlTall : art.url,
            source: switch (art.source) {
              CanvasSource.apple => 'Apple Music',
              CanvasSource.tidal => 'Tidal',
              CanvasSource.community => 'Community',
            },
            vertical: tall,
          ),
        );
      }
      DiagnosticsLog.info('canvas-panel none note="$note"');
      return CanvasPanelOutcome(note: note);
    });
