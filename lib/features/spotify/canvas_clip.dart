import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/diagnostics/diagnostics_log.dart';
import '../../core/artwork/animated_artwork_service.dart';
import '../performance/performance_controller.dart';
import 'spotify_api.dart';
import 'spotify_auth.dart';

/// What the Canvas panel plays for a track.
class CanvasPanelClip {
  final String url;
  final String fallbackUrl;

  /// Provider label shown on the panel ("Spotify", "Apple Music", …).
  final String source;

  /// True when the clip is a real vertical canvas. Square album motion
  /// art is cover-cropped into the 9:16 frame instead.
  final bool vertical;

  const CanvasPanelClip({
    required this.url,
    this.fallbackUrl = '',
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

/// Full Bleed Canvas resolver: respects the master Playback Canvas toggle and
/// the "Prefer Spotify Canvas" priority toggle in Settings → Integrations.
/// Hits are kept; misses are re-asked next time so a transient failure never
/// sticks.
final canvasPanelClipProvider = FutureProvider.autoDispose
    .family<CanvasPanelOutcome, CanvasPanelQuery>((ref, q) async {
      final isPerf = ref.watch(performanceModeProvider);
      if (isPerf) {
        DiagnosticsLog.info('spotify-canvas skipped reason=performance-mode');
        return const CanvasPanelOutcome(
          note: 'Canvas video playback is paused by Performance Mode',
        );
      }

      if (!ref.watch(canvasEnabledProvider)) {
        DiagnosticsLog.info('spotify-canvas skipped reason=canvas-disabled');
        return const CanvasPanelOutcome(
          note: 'Canvas is switched off in Settings → Playback',
        );
      }

      final spotifyEnabled = ref.watch(spotifyCanvasEnabledProvider);
      final preferSpotify = ref.watch(preferSpotifyCanvasProvider);
      final auth = ref.watch(spotifyAuthProvider);
      var note = '';

      Future<CanvasPanelClip?> fetchSpotify() async {
        if (!spotifyEnabled) {
          note = 'Spotify Canvas is switched off in Settings';
          DiagnosticsLog.info('spotify-canvas skipped reason=toggle-off');
          return null;
        }
        // The stored cookie loads asynchronously at startup: wait for it
        // instead of racing it.
        final hasCookie = await auth.spdc() != null;
        if (!hasCookie) {
          note =
              'Connect Spotify in Settings → Integrations for Spotify Canvas';
          DiagnosticsLog.info('spotify-canvas skipped reason=not-connected');
          return null;
        }
        final res = await ref
            .watch(spotifyApiProvider)
            .canvas(
              title: cleanCanvasQuery(q.title),
              artist: cleanCanvasQuery(q.artist),
              durationMs: q.durationMs,
            );
        if (res.clip != null) {
          return CanvasPanelClip(
            url: res.clip!.url,
            source: 'Spotify',
            vertical: true,
          );
        }
        note = res.reason;
        return null;
      }

      Future<CanvasPanelClip?> fetchMotionArt() async {
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
          final tall = art.urlTall.isNotEmpty;
          return CanvasPanelClip(
            url: tall ? art.urlTall : art.url,
            fallbackUrl: art.fallbackUrl ?? '',
            source: switch (art.source) {
              CanvasSource.apple => 'Apple Music',
              CanvasSource.tidal => 'Tidal',
              CanvasSource.community => 'Community',
            },
            vertical: tall,
          );
        }
        return null;
      }

      if (preferSpotify) {
        final sp = await fetchSpotify();
        if (sp != null) {
          ref.keepAlive();
          return CanvasPanelOutcome(clip: sp);
        }
        final motion = await fetchMotionArt();
        if (motion != null) {
          ref.keepAlive();
          return CanvasPanelOutcome(clip: motion);
        }
      } else {
        final motion = await fetchMotionArt();
        if (motion != null) {
          ref.keepAlive();
          return CanvasPanelOutcome(clip: motion);
        }
        final sp = await fetchSpotify();
        if (sp != null) {
          ref.keepAlive();
          return CanvasPanelOutcome(clip: sp);
        }
      }

      DiagnosticsLog.info('canvas-panel none note="$note"');
      return CanvasPanelOutcome(note: note);
    });
