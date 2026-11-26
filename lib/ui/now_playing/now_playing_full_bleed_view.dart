import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart' hide Colors;
import 'package:flutter/material.dart' show Colors;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/artwork/animated_artwork_session.dart';
import '../../core/audio/stream_models.dart';
import '../../features/lyrics/karaoke_lyrics_view.dart';
import '../../features/spotify/canvas_clip.dart';
import '../components/ambient.dart';
import '../components/animated_artwork_video.dart';
import '../components/artwork.dart';
import '../lyrics/lyrics_panel.dart' show waveLyricsProvider;
import '../theme/tokens.dart';
import 'immersive.dart';
import 'now_playing_overflow_menu.dart';

/// Full Bleed Now Playing layout: Edge-to-edge Canvas / hi-res artwork blended
/// into a color-adapted ambient backdrop, paired with right-side lyrics/queue.
class NowPlayingFullBleedView extends ConsumerStatefulWidget {
  final PlayableTrack track;

  const NowPlayingFullBleedView({
    super.key,
    required this.track,
  });

  @override
  ConsumerState<NowPlayingFullBleedView> createState() =>
      _NowPlayingFullBleedViewState();
}

class _NowPlayingFullBleedViewState
    extends ConsumerState<NowPlayingFullBleedView> {
  String _lastClipUrl = '';
  String _lastClipFallbackUrl = '';
  bool _sleeveGone = false;

  @override
  Widget build(BuildContext context) {
    final track = widget.track;
    final isImmersive = ref.watch(nowPlayingImmersiveProvider);
    final controlsIdle = ref.watch(nowPlayingControlsIdleProvider);
    final ambientStyle = ref.watch(ambientStyleProvider);
    final lyricsAsync = ref.watch(waveLyricsProvider(track));
    final lyricsState = lyricsAsync.when(
      loading: () => (missing: false, instrumental: false),
      error: (_, _) => (missing: true, instrumental: false),
      data: (r) => (
        missing: r.isEmpty || r.isInstrumental,
        instrumental: r.isInstrumental,
      ),
    );

    // Prefer Spotify Canvas first, then Apple Music / Tidal / Community canvas.
    final canvasAsync = ref.watch(
      canvasPanelClipProvider((
        title: track.title,
        artist: track.artist,
        album: track.album,
        durationMs: track.duration.inMilliseconds,
      )),
    );
    final clip = canvasAsync.valueOrNull?.clip;
    final clipUrl = clip?.url ?? '';
    final clipFallbackUrl = clip?.fallbackUrl ?? '';
    if (!canvasAsync.isLoading || clipUrl.isNotEmpty) {
      _lastClipUrl = clipUrl;
      _lastClipFallbackUrl = clipFallbackUrl;
    }
    final activeUrl =
        clipUrl.isNotEmpty ? clipUrl : (canvasAsync.isLoading ? _lastClipUrl : '');
    final activeFallbackUrl = clipUrl.isNotEmpty
        ? clipFallbackUrl
        : (canvasAsync.isLoading ? _lastClipFallbackUrl : '');
    final videoReady =
        clipUrl.isNotEmpty &&
        ref.watch(
          animatedArtworkSessionProvider.select((s) => s.isReadyFor(clipUrl)),
        );
    if (!videoReady) _sleeveGone = false;
    final showSleeve = !videoReady || !_sleeveGone;

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        // Keep the Canvas/artwork pane near a natural square/portrait aspect
        // (~44-50% on widescreen) so Canvas videos aren't stretched wide
        // (blurry + cropped) and the lyrics pane gets comfortable width.
        final artWidth =
            math.min(w * 0.52, math.max(w * 0.44, h * 0.96)).clamp(240.0, w * 0.56);
        final coverEdge = math.max(artWidth, h);
        final lyricsLeft = math.min(w * 0.44, artWidth * 0.90);

        return Stack(
          fit: StackFit.expand,
          children: [
            // 0. Full-Stage Color-Adaptive Ambient Backdrop
            Positioned.fill(
              child: RepaintBoundary(
                child: WaveAmbientMesh(
                  artworkUrl: track.artworkUrl,
                  isFullBleed: true,
                  cinematic: true,
                  apple: ambientStyle == AmbientStyle.apple,
                ),
              ),
            ),

            // 1. Left Full-Bleed Canvas / Hi-Res Official Cover with Wide Smoothstep Feather
            Positioned(
              top: 0,
              bottom: 0,
              left: 0,
              width: artWidth,
              child: RepaintBoundary(
                child: ShaderMask(
                  shaderCallback: (bounds) => LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    // Wide cubic-eased alpha curve reaching full transparency by
                    // 0.95 (well inside the 4px inset below) so Skia's antialiased
                    // dstIn right boundary never leaves a 1px opaque-black seam at
                    // fractional DPI widths.
                    stops: const [
                      0.0,
                      0.40,
                      0.50,
                      0.60,
                      0.70,
                      0.80,
                      0.89,
                      0.95,
                      1.0,
                    ],
                    colors: [
                      Colors.white,
                      Colors.white,
                      Colors.white.withValues(alpha: 0.92),
                      Colors.white.withValues(alpha: 0.74),
                      Colors.white.withValues(alpha: 0.48),
                      Colors.white.withValues(alpha: 0.24),
                      Colors.white.withValues(alpha: 0.07),
                      Colors.transparent,
                      Colors.transparent,
                    ],
                  ).createShader(bounds),
                  blendMode: BlendMode.dstIn,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: ClipRect(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (activeUrl.isNotEmpty)
                            AnimatedArtworkVideo(
                              url: activeUrl,
                              fallbackUrl: activeFallbackUrl,
                              width: math.max(0.0, artWidth - 4),
                              height: h,
                            ),
                          if (showSleeve)
                            AnimatedOpacity(
                              opacity: videoReady ? 0.0 : 1.0,
                              duration: const Duration(milliseconds: 320),
                              curve: Curves.easeOut,
                              onEnd: () {
                                if (videoReady && !_sleeveGone && mounted) {
                                  setState(() => _sleeveGone = true);
                                }
                              },
                              child: SizedBox.expand(
                                child: FittedBox(
                                  fit: BoxFit.cover,
                                  clipBehavior: Clip.hardEdge,
                                  child: WaveArtwork(
                                    url: track.artworkUrl,
                                    videoId: track.videoId,
                                    size: coverEdge,
                                    decodeExtent: 1024,
                                    radius: 0,
                                    label: track.title,
                                    title: track.title,
                                    artist: track.artist,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // 2. Right Pane: Lyrics (or clean auto-hiding "Lyrics not found" notice)
            Positioned(
              top: 0,
              bottom: 0,
              left: lyricsLeft,
              right: 0,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 56, 36, 24),
                child: lyricsState.missing
                    ? AnimatedOpacity(
                        duration: waveMotion(
                          context,
                          const Duration(milliseconds: 350),
                        ),
                        opacity: controlsIdle ? 0.0 : 1.0,
                        child: Center(
                          child: Text(
                            lyricsState.instrumental
                                ? 'Instrumental'
                                : 'Lyrics not found',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                              color: (waveIsDark(context)
                                      ? Colors.white
                                      : Colors.black)
                                  .withValues(alpha: 0.48),
                              letterSpacing: -0.1,
                            ),
                          ),
                        ),
                      )
                    : WaveKaraokeLyricsView(
                        track: track,
                        compact: false,
                        showHeaderControls: false,
                        fontSize: 34.0,
                        isActive: true,
                      ),
              ),
            ),

            // 3. Top-Left Back button (only in immersive fullscreen, fades on idle)
            if (isImmersive)
              Positioned(
                top: 18,
                left: 20,
                child: AnimatedOpacity(
                  duration: waveMotion(
                    context,
                    const Duration(milliseconds: 350),
                  ),
                  opacity: controlsIdle ? 0.0 : 1.0,
                  child: ExcludeFocus(
                    excluding: controlsIdle,
                    child: IgnorePointer(
                      ignoring: controlsIdle,
                      child: _FullBleedIconButton(
                        icon: FluentIcons.chevron_left,
                        tooltip: 'Exit fullscreen (F11)',
                        onTap: () {
                          ref.read(nowPlayingActivityProvider.notifier).state++;
                          ref.read(nowPlayingImmersiveProvider.notifier).state =
                              false;
                        },
                      ),
                    ),
                  ),
                ),
              ),

            // 4. Unified Top-Right Control Bar (fades on idle)
            Positioned(
              top: 18,
              right: 20,
              child: AnimatedOpacity(
                duration: waveMotion(
                  context,
                  const Duration(milliseconds: 350),
                ),
                opacity: controlsIdle ? 0.0 : 1.0,
                child: ExcludeFocus(
                  excluding: controlsIdle,
                  child: IgnorePointer(
                    ignoring: controlsIdle,
                    child: NowPlayingTopActions(
                      track: track,
                      onInteraction: () =>
                          ref.read(nowPlayingActivityProvider.notifier).state++,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _FullBleedIconButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _FullBleedIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  State<_FullBleedIconButton> createState() => _FullBleedIconButtonState();
}

class _FullBleedIconButtonState extends State<_FullBleedIconButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final ink = dark ? Colors.white : Colors.black;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: dark
                  ? Colors.white.withValues(alpha: _hover ? 0.20 : 0.10)
                  : Colors.white.withValues(alpha: _hover ? 0.85 : 0.68),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Center(
              child: Icon(
                widget.icon,
                size: 15,
                color: ink.withValues(alpha: _hover ? 1.0 : 0.85),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
