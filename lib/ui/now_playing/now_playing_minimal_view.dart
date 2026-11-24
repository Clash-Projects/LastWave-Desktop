import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart' hide Colors;
import 'package:flutter/material.dart' show Colors, Icons;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/artwork/animated_artwork_service.dart';
import '../../core/artwork/animated_artwork_session.dart';
import '../../core/audio/stream_models.dart';
import '../../features/lyrics/karaoke_lyrics_view.dart';
import '../../features/spotify/spotify_api.dart' show canvasEnabledProvider;
import '../components/ambient.dart';
import '../components/animated_artwork_video.dart';
import '../components/artwork.dart';
import '../lyrics/lyrics_panel.dart' show waveLyricsProvider;
import '../theme/tokens.dart';
import 'immersive.dart';
import 'now_playing_overflow_menu.dart';

/// Minimal Now Playing layout: Sharp cover art (with motion art and hi-res
/// official artwork), centered metadata, and distraction-free synced lyrics.
/// Automatically centers the artwork when lyrics are hidden or unavailable.
class NowPlayingMinimalView extends ConsumerStatefulWidget {
  final PlayableTrack track;
  final VoidCallback onClose;
  final bool lyricsVisible;
  final VoidCallback? onToggleLyrics;

  const NowPlayingMinimalView({
    super.key,
    required this.track,
    required this.onClose,
    this.lyricsVisible = true,
    this.onToggleLyrics,
  });

  @override
  ConsumerState<NowPlayingMinimalView> createState() =>
      _NowPlayingMinimalViewState();
}

class _NowPlayingMinimalViewState extends ConsumerState<NowPlayingMinimalView> {
  String _lastClipUrl = '';
  String _lastClipFallbackUrl = '';
  bool _sleeveGone = false;

  @override
  Widget build(BuildContext context) {
    final track = widget.track;
    final canvasEnabled = ref.watch(canvasEnabledProvider);
    final controlsIdle = ref.watch(nowPlayingControlsIdleProvider);
    final lyricsAsync = ref.watch(waveLyricsProvider(track));
    final lyricsMissing = lyricsAsync.when(
      loading: () => false,
      error: (_, _) => true,
      data: (r) => r.isEmpty || r.isInstrumental,
    );
    final showLyrics = widget.lyricsVisible && !lyricsMissing;

    // Minimal uses non-Spotify motion art (Apple Music / Tidal / Community);
    // Spotify 9:16 Canvas is reserved exclusively for Full Bleed.
    final motionAsync = !canvasEnabled
        ? const AsyncData<AnimatedArtwork?>(null)
        : ref.watch(
            animatedArtworkProvider(
              AnimatedArtworkQuery(
                artist: track.artist,
                album: track.album,
                title: track.title,
              ),
            ),
          );
    final motionArt = motionAsync.valueOrNull;
    final clipUrl = motionArt?.hasUrl == true ? motionArt!.url : '';
    final clipFallbackUrl = motionArt?.fallbackUrl ?? '';
    if (!motionAsync.isLoading || clipUrl.isNotEmpty) {
      _lastClipUrl = clipUrl;
      _lastClipFallbackUrl = clipFallbackUrl;
    }
    final activeUrl = !canvasEnabled
        ? ''
        : (clipUrl.isNotEmpty
            ? clipUrl
            : (motionAsync.isLoading ? _lastClipUrl : ''));
    final activeFallbackUrl = !canvasEnabled
        ? ''
        : (clipUrl.isNotEmpty
            ? clipFallbackUrl
            : (motionAsync.isLoading ? _lastClipFallbackUrl : ''));
    final videoReady =
        canvasEnabled &&
        clipUrl.isNotEmpty &&
        ref.watch(
          animatedArtworkSessionProvider.select((s) => s.isReadyFor(clipUrl)),
        );
    if (!videoReady) _sleeveGone = false;
    final showSleeve = !videoReady || !_sleeveGone;

    return Stack(
      children: [
        // 1. Backdrop: Cached single-pass artwork-tinted ambient stage
        Positioned.fill(
          child: RepaintBoundary(
            child: WaveAmbientMesh(
              artworkUrl: track.artworkUrl,
              isFullBleed: true,
              cinematic: true,
              apple: ref.watch(ambientStyleProvider) == AmbientStyle.apple,
            ),
          ),
        ),

        // 2. Main Layout: Centers cover smoothly when lyrics are hidden or unavailable
        Positioned.fill(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 56, vertical: 40),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final availW = constraints.maxWidth;
                final availH = constraints.maxHeight;
                final targetLeftW = showLyrics
                    ? math.min(
                        availW,
                        math.max(0.0, (availW - 48.0) * 0.42).clamp(0.0, 440.0),
                      )
                    : math.min(
                        availW,
                        math.max(0.0, math.min(availH - 80.0, 460.0)),
                      );
                final gapW =
                    showLyrics && availW > targetLeftW + 48.0 ? 48.0 : 0.0;
                final targetLyricsW = showLyrics
                    ? math.max(0.0, availW - targetLeftW - gapW)
                    : 0.0;
                final coverMax = showLyrics ? 420.0 : 440.0;
                final animDuration = waveMotion(
                  context,
                  const Duration(milliseconds: 420),
                );

                return Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Cover + Centered Track Info (smoothly centers when lyrics are off/missing)
                    AnimatedContainer(
                      duration: animDuration,
                      curve: Curves.easeInOutCubic,
                      width: targetLeftW,
                      child: Center(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: coverMax,
                            maxHeight: coverMax + 100,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              // Sharp square album cover with motion art & Hi-Res Official Art
                              ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: coverMax,
                                  maxHeight: coverMax,
                                ),
                                child: AspectRatio(
                                  aspectRatio: 1,
                                  child: LayoutBuilder(
                                    builder: (context, box) {
                                      final side = box.maxWidth;
                                      return RepaintBoundary(
                                        child: ClipRRect(
                                          borderRadius:
                                              BorderRadius.circular(2.0),
                                          child: Stack(
                                            fit: StackFit.expand,
                                            children: [
                                              if (activeUrl.isNotEmpty)
                                                AnimatedArtworkVideo(
                                                  url: activeUrl,
                                                  fallbackUrl:
                                                      activeFallbackUrl,
                                                  size: side,
                                                ),
                                              if (showSleeve)
                                                AnimatedOpacity(
                                                  opacity:
                                                      videoReady ? 0.0 : 1.0,
                                                  duration: const Duration(
                                                    milliseconds: 320,
                                                  ),
                                                  curve: Curves.easeOut,
                                                  onEnd: () {
                                                    if (videoReady &&
                                                        !_sleeveGone &&
                                                        mounted) {
                                                      setState(
                                                        () =>
                                                            _sleeveGone = true,
                                                      );
                                                    }
                                                  },
                                                  child: WaveArtwork(
                                                    url: track.artworkUrl,
                                                    videoId: track.videoId,
                                                    size: side,
                                                    decodeExtent: 1024,
                                                    radius: 2.0,
                                                    label: track.title,
                                                    title: track.title,
                                                    artist: track.artist,
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ),
                              const SizedBox(height: 18),

                              // Centered Track Title
                              Text(
                                track.title,
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                  letterSpacing: -0.2,
                                ),
                              ),
                              const SizedBox(height: 4),

                              // Centered Artist Name
                              Text(
                                track.artist,
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w400,
                                  color: Colors.white.withValues(alpha: 0.65),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                    AnimatedContainer(
                      duration: animDuration,
                      curve: Curves.easeInOutCubic,
                      width: gapW,
                    ),

                    // Right Column: Synced Lyrics (collapses smoothly when hidden or not found)
                    AnimatedContainer(
                      duration: animDuration,
                      curve: Curves.easeInOutCubic,
                      width: targetLyricsW,
                      child: ClipRect(
                        child: AnimatedOpacity(
                          duration: waveMotion(
                            context,
                            const Duration(milliseconds: 260),
                          ),
                          opacity: showLyrics ? 1.0 : 0.0,
                          child: ExcludeFocus(
                            excluding: !showLyrics,
                            child: IgnorePointer(
                              ignoring: !showLyrics,
                              child: OverflowBox(
                                alignment: Alignment.centerLeft,
                                minWidth: showLyrics
                                    ? targetLyricsW
                                    : math.max(320.0, (availW - 48.0) * 0.58),
                                maxWidth: showLyrics
                                    ? targetLyricsW
                                    : math.max(320.0, (availW - 48.0) * 0.58),
                                child: WaveKaraokeLyricsView(
                                  track: track,
                                  compact: false,
                                  showHeaderControls: false,
                                  fontSize: 34.0,
                                  isActive: showLyrics,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),

        // 3. Top-Left Downward Collapse Chevron (fades on idle)
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
                child: _CollapseChevronButton(
                  onTap: () {
                    ref.read(nowPlayingActivityProvider.notifier).state++;
                    widget.onClose();
                  },
                ),
              ),
            ),
          ),
        ),

        // 4. Unified Top-Right Control Bar (Ambient, Fullscreen, Overflow — fades on idle)
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
                  lyricsVisible: widget.lyricsVisible,
                  onToggleLyrics: widget.onToggleLyrics,
                  onInteraction: () =>
                      ref.read(nowPlayingActivityProvider.notifier).state++,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _CollapseChevronButton extends StatefulWidget {
  final VoidCallback onTap;

  const _CollapseChevronButton({required this.onTap});

  @override
  State<_CollapseChevronButton> createState() => _CollapseChevronButtonState();
}

class _CollapseChevronButtonState extends State<_CollapseChevronButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Collapse Now Playing',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hover
                  ? Colors.white.withValues(alpha: 0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(
              Icons.keyboard_arrow_down,
              size: 22,
              color: Colors.white.withValues(alpha: _hover ? 0.95 : 0.55),
            ),
          ),
        ),
      ),
    );
  }
}
