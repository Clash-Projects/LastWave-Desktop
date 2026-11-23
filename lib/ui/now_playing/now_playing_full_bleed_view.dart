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
import '../queue/queue_panel.dart';
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
  String _activeTab = 'lyrics'; // 'lyrics' | 'upNext'
  String _lastClipUrl = '';
  String _lastClipFallbackUrl = '';
  bool _sleeveGone = false;

  @override
  Widget build(BuildContext context) {
    final track = widget.track;
    final isImmersive = ref.watch(nowPlayingImmersiveProvider);
    final ambientStyle = ref.watch(ambientStyleProvider);

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
        final artWidth = w * 0.56;
        final coverEdge = math.max(artWidth, h);

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

            // 1. Left Full-Bleed Canvas / Hi-Res Official Cover with Soft Alpha Feather
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
                    stops: const [0.0, 0.72, 0.90, 1.0],
                    colors: [
                      Colors.white,
                      Colors.white,
                      Colors.white.withValues(alpha: 0.45),
                      Colors.transparent,
                    ],
                  ).createShader(bounds),
                  blendMode: BlendMode.dstIn,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (activeUrl.isNotEmpty)
                        AnimatedArtworkVideo(
                          url: activeUrl,
                          fallbackUrl: activeFallbackUrl,
                          width: artWidth,
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
                                decodeExtent: 720,
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

            // 2. Right Pane: Lyrics or Up Next Queue
            Positioned(
              top: 0,
              bottom: 0,
              left: w * 0.48,
              right: 0,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 72, 48, 32),
                child: _activeTab == 'lyrics'
                    ? WaveKaraokeLyricsView(
                        track: track,
                        compact: false,
                        showHeaderControls: false,
                        fontSize: 34.0,
                        isActive: true,
                      )
                    : const WaveQueuePanel(
                        onClose: null,
                        embedded: true,
                      ),
              ),
            ),

            // 3. Top-Left Floating Track Pill (+ Back button in immersive fullscreen)
            Positioned(
              top: 18,
              left: 20,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isImmersive) ...[
                    _FullBleedIconButton(
                      icon: FluentIcons.chevron_left,
                      tooltip: 'Exit fullscreen (F11)',
                      onTap: () {
                        ref.read(nowPlayingImmersiveProvider.notifier).state =
                            false;
                      },
                    ),
                    const SizedBox(width: 8),
                  ],
                  Container(
                    constraints: const BoxConstraints(maxWidth: 260),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.44),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.12),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          track.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w400,
                            color: Colors.white.withValues(alpha: 0.76),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // 4. Unified Top-Right Control Bar (Visualizer, Fullscreen, Overflow)
            Positioned(
              top: 18,
              right: 20,
              child: NowPlayingTopActions(
                track: track,
                isQueueOpen: _activeTab == 'upNext',
                onToggleQueue: () => setState(
                  () => _activeTab =
                      _activeTab == 'upNext' ? 'lyrics' : 'upNext',
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
              color: Colors.white.withValues(alpha: _hover ? 0.20 : 0.10),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Center(
              child: Icon(
                widget.icon,
                size: 15,
                color: Colors.white.withValues(alpha: _hover ? 1.0 : 0.85),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
