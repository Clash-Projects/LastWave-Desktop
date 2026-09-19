import 'dart:async';
import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart' hide RepeatMode;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/artwork/animated_artwork_service.dart';
import '../../core/artwork/animated_artwork_session.dart';
import '../../core/artwork/artwork_resolver.dart';
import '../../core/audio/stream_models.dart';
import '../../features/lyrics/karaoke_lyrics_view.dart';
import '../../features/player/playback_service.dart';
import '../../widgets/ambient.dart';
import '../../widgets/animated_artwork_video.dart';
import '../components/artwork.dart';
import '../components/buttons.dart' show LWTooltip;
import '../components/states.dart';
import '../queue/queue_panel.dart';
import '../theme/haze.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

/// Centerpiece Fullscreen Player — Apple Music Split View & Cinematic Centering.
///
/// Mirrored directly from `desktop-app`'s `#fullscreen-cover-overlay`:
/// - 2-Column Split: Left media column (Large artwork, title/artist, Up Next)
///   + Right karaoke lyrics column. Timeline, transport and volume live in the
///   persistent bottom player dock — the single control surface.
/// - Cinematic Centering: Smoothly animates the artwork and controls to center
///   when lyrics are toggled off.
/// - Top Actions: Lyrics toggle, Queue drawer toggle, Visualizer toggle, Close button.
/// - Inactivity Auto-Hide: Fades controls and hides cursor after 3.5s of idle mouse.
class WaveNowPlayingPage extends ConsumerStatefulWidget {
  const WaveNowPlayingPage({super.key});

  @override
  ConsumerState<WaveNowPlayingPage> createState() => _WaveNowPlayingPageState();
}

class _WaveNowPlayingPageState extends ConsumerState<WaveNowPlayingPage> {
  bool _lyricsVisible = true;
  bool _queueVisible = false;
  bool _controlsIdle = false;
  Timer? _idleTimer;
  String _preloadedKey = '';

  @override
  void initState() {
    super.initState();
    _resetIdleTimer();
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    super.dispose();
  }

  void _resetIdleTimer() {
    if (_controlsIdle) {
      setState(() => _controlsIdle = false);
    }
    _idleTimer?.cancel();
    _idleTimer = Timer(const Duration(milliseconds: 3500), () {
      if (mounted) {
        setState(() => _controlsIdle = true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(
      playbackServiceProvider.select((s) => s.current),
    );

    final visualizerEnabled = ref.watch(visualizerEnabledProvider);

    if (current == null) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: WaveEmpty(
            icon: WaveIcons.music,
            title: 'Nothing playing',
            subtitle:
                'Pick something from Home, Discover or Search and it will take centre stage here.',
            actionLabel: 'Browse music',
            onAction: () => context.go('/home'),
          ),
        ),
      );
    }

    if (current.queueKey != _preloadedKey) {
      _preloadedKey = current.queueKey;
      final snap = ref.read(playbackServiceProvider);
      final q = snap.queue;
      final i = snap.currentIndex;
      final upcoming = <PlayableTrack>[
        if (i + 1 < q.length) q[i + 1],
        if (i + 2 < q.length) q[i + 2],
      ];
      final warm = [
        current.artworkUrl,
        ...upcoming.map((t) => t.artworkUrl),
      ].where((u) => u.isNotEmpty).toList();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (warm.isNotEmpty) {
          ArtworkResolver.preload(context, warm, targetPx: 640);
        }
        final anim = ref.read(animatedArtworkServiceProvider);
        anim.prefetch(AnimatedArtworkQuery(
          artist: current.artist,
          album: current.album,
          title: current.title,
        ));
        for (final track in upcoming) {
          anim.prefetch(AnimatedArtworkQuery(
            artist: track.artist,
            album: track.album,
            title: track.title,
          ));
        }
      });
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_queueVisible) {
            setState(() => _queueVisible = false);
          } else {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/home');
            }
          }
        },
      },
      child: MouseRegion(
        cursor: _controlsIdle ? SystemMouseCursors.none : SystemMouseCursors.basic,
        onHover: (_) => _resetIdleTimer(),
        child: Stack(
          children: [
            // Background Visualizer
            Positioned.fill(
              child: _NowAmbient(artworkUrl: current.artworkUrl),
            ),

            // Main Layout Content
            Positioned.fill(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final isWide = constraints.maxWidth > 860;

                  return Column(
                    children: [
                      // Top Actions Bar (Fadeable on idle)
                      AnimatedOpacity(
                        duration: const Duration(milliseconds: 350),
                        opacity: _controlsIdle ? 0.0 : 1.0,
                        child: ExcludeFocus(
                          excluding: _controlsIdle,
                          child: IgnorePointer(
                            ignoring: _controlsIdle,
                            child: _TopActionsBar(
                              lyricsVisible: _lyricsVisible,
                              queueVisible: _queueVisible,
                              visualizerEnabled: visualizerEnabled,
                              onToggleLyrics: () {
                                _resetIdleTimer();
                                setState(() => _lyricsVisible = !_lyricsVisible);
                              },
                              onToggleQueue: () {
                                _resetIdleTimer();
                                setState(() => _queueVisible = !_queueVisible);
                              },
                              onToggleVisualizer: () {
                                _resetIdleTimer();
                                ref.read(visualizerEnabledProvider.notifier).toggle();
                              },
                              onClose: () {
                                if (context.canPop()) {
                                  context.pop();
                                } else {
                                  context.go('/home');
                                }
                              },
                            ),
                          ),
                        ),
                      ),

                      // Body
                      Expanded(
                        child: isWide
                            ? _DesktopDualPane(
                                track: current,
                                lyricsVisible: _lyricsVisible,
                                maxHeight: constraints.maxHeight - 64,
                                maxWidth: constraints.maxWidth,
                              )
                            : _NarrowCenteredPane(
                                track: current,
                                lyricsVisible: _lyricsVisible,
                              ),
                      ),
                    ],
                  );
                },
              ),
            ),

            // Scrim backdrop when queue drawer is active
            Positioned.fill(
              child: IgnorePointer(
                ignoring: !_queueVisible,
                child: AnimatedOpacity(
                  duration: WaveMotion.normal,
                  curve: Curves.easeOutCubic,
                  opacity: _queueVisible ? 1.0 : 0.0,
                  child: GestureDetector(
                    onTap: () => setState(() => _queueVisible = false),
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.45),
                    ),
                  ),
                ),
              ),
            ),

            // Contextual Queue drawer smoothly sliding from right
            AnimatedPositioned(
              duration: WaveMotion.normal,
              curve: Curves.easeOutCubic,
              top: 0,
              bottom: 0,
              right: _queueVisible ? 0 : -380,
              width: 360,
              child: ExcludeFocus(
                excluding: !_queueVisible,
                child: IgnorePointer(
                  ignoring: !_queueVisible,
                  child: WaveQueuePanel(
                    onClose: () => setState(() => _queueVisible = false),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopActionsBar extends StatelessWidget {
  final bool lyricsVisible;
  final bool queueVisible;
  final bool visualizerEnabled;
  final VoidCallback onToggleLyrics;
  final VoidCallback onToggleQueue;
  final VoidCallback onToggleVisualizer;
  final VoidCallback onClose;

  const _TopActionsBar({
    required this.lyricsVisible,
    required this.queueVisible,
    required this.visualizerEnabled,
    required this.onToggleLyrics,
    required this.onToggleQueue,
    required this.onToggleVisualizer,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 54,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        children: [
          WaveGlass(
            borderRadius: WaveRadius.menuRadius,
            child: LWTooltip(
              message: 'Back',
              child: _FsIconButton(
                icon: FluentIcons.chevron_left,
                onTap: onClose,
              ),
            ),
          ),
          const Spacer(),
          WaveGlass(
            borderRadius: WaveRadius.menuRadius,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                LWTooltip(
                  message: lyricsVisible ? 'Hide lyrics' : 'Show lyrics',
                  child: _FsIconButton(
                    icon: WaveIcons.lyrics,
                    active: lyricsVisible,
                    onTap: onToggleLyrics,
                  ),
                ),
                LWTooltip(
                  message: queueVisible ? 'Hide queue' : 'Show queue',
                  child: _FsIconButton(
                    icon: WaveIcons.queue,
                    active: queueVisible,
                    onTap: onToggleQueue,
                  ),
                ),
                LWTooltip(
                  message: visualizerEnabled
                      ? 'Disable visualizer'
                      : 'Enable visualizer',
                  child: _FsIconButton(
                    icon: WaveIcons.mixes,
                    active: visualizerEnabled,
                    onTap: onToggleVisualizer,
                  ),
                ),
                LWTooltip(
                  message: 'Close (Esc)',
                  child: _FsIconButton(
                    icon: WaveIcons.close,
                    onTap: onClose,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FsIconButton extends StatefulWidget {
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  const _FsIconButton({
    required this.icon,
    this.active = false,
    required this.onTap,
  });

  @override
  State<_FsIconButton> createState() => _FsIconButtonState();
}

class _FsIconButtonState extends State<_FsIconButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);
    final color = widget.active
        ? accent
        : (dark ? WaveColors.textPrimary : WaveColors.lightTextPrimary)
            .withValues(alpha: _hover ? 1.0 : 0.92);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: WaveMotion.fast,
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: widget.active
                ? accent.withValues(alpha: 0.15)
                : _hover
                    ? (dark ? Colors.white : Colors.black).withValues(alpha: 0.10)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: widget.active
                  ? accent.withValues(alpha: 0.35)
                  : Colors.transparent,
            ),
          ),
          child: Center(
            child: Icon(widget.icon, size: 16, color: color),
          ),
        ),
      ),
    );
  }
}

/// Desktop Dual-Pane split layout with smooth cinematic centering when lyrics are hidden.
class _DesktopDualPane extends StatelessWidget {
  final PlayableTrack track;
  final bool lyricsVisible;
  final double maxHeight;
  final double maxWidth;

  const _DesktopDualPane({
    required this.track,
    required this.lyricsVisible,
    required this.maxHeight,
    required this.maxWidth,
  });

  @override
  Widget build(BuildContext context) {
    // Symmetrical desktop dual pane layout:
    // When lyrics are visible, media column and lyrics column have harmonious, balanced
    // widths, leaving identical horizontal margins (emptiness) on both sides.
    final colWidth = lyricsVisible
        ? math.min(maxWidth * 0.36, maxHeight * 0.48).clamp(340.0, 420.0)
        : math.min(maxWidth * 0.55, maxHeight * 0.52).clamp(360.0, 480.0);

    final gap = lyricsVisible ? (maxWidth * 0.04).clamp(40.0, 64.0) : 0.0;

    // Harmonized lyrics column width, balancing the visual weight of the left column
    final targetLyricsWidth = (colWidth * 1.35).clamp(460.0, 580.0);
    final maxAllowedLyricsWidth = math.max(320.0, maxWidth - colWidth - gap - 48.0);
    final lyricsWidth = lyricsVisible
        ? math.min(targetLyricsWidth, maxAllowedLyricsWidth)
        : 0.0;

    return Center(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 24),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const ClampingScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: maxWidth),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Left Column (Media Player)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 500),
                  curve: Curves.easeInOutCubic,
                  width: colWidth,
                  child: SingleChildScrollView(
                    physics: const ClampingScrollPhysics(),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: lyricsVisible
                          ? CrossAxisAlignment.start
                          : CrossAxisAlignment.center,
                      children: [
                        // Artwork Card
                        _HeroArtworkCard(
                          track: track,
                          size: colWidth,
                        ),
                        const SizedBox(height: 20),

                        // Track Info — crossfades on track change.
                        _TrackSwap(
                          child: _TrackMetadataSection(
                            key: ValueKey(track.queueKey),
                            track: track,
                            alignCenter: !lyricsVisible,
                          ),
                        ),
                        const SizedBox(height: 10),

                        // Up Next Pill
                        _UpNextPill(alignCenter: !lyricsVisible),
                      ],
                    ),
                  ),
                ),

                // Gap
                AnimatedContainer(
                  duration: const Duration(milliseconds: 500),
                  curve: Curves.easeInOutCubic,
                  width: gap,
                ),

                // Right Column (Apple Music Karaoke Lyrics Pane)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 500),
                  curve: Curves.easeInOutCubic,
                  width: lyricsWidth,
                  child: ClipRect(
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 350),
                      curve: Curves.easeInOutCubic,
                      opacity: lyricsVisible ? 1.0 : 0.0,
                      child: ExcludeFocus(
                        excluding: !lyricsVisible,
                        child: IgnorePointer(
                          ignoring: !lyricsVisible,
                          child: Container(
                            height: maxHeight,
                            width: lyricsWidth,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(16),
                              child: WaveKaraokeLyricsView(
                                track: track,
                                compact: false,
                                showHeaderControls: true,
                                fontSize: 36.0,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Narrow window presentation.
class _NarrowCenteredPane extends StatelessWidget {
  final PlayableTrack track;
  final bool lyricsVisible;

  const _NarrowCenteredPane({
    required this.track,
    required this.lyricsVisible,
  });

  @override
  Widget build(BuildContext context) {
    if (lyricsVisible) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: WaveKaraokeLyricsView(
          track: track,
          compact: true,
          showHeaderControls: true,
        ),
      );
    }

    return SingleChildScrollView(
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _HeroArtworkCard(
                track: track,
                size: 260,
              ),
              const SizedBox(height: 20),
              _TrackSwap(
                child: _TrackMetadataSection(
                  key: ValueKey(track.queueKey),
                  track: track,
                  alignCenter: true,
                ),
              ),
              const SizedBox(height: 12),
              const _UpNextPill(alignCenter: true),
            ],
          ),
        ),
      ),
    );
  }
}

/// Large Artwork Card with rounded corners and deep drop shadow.
///
/// Motion art sits under a still sleeve that fades away once the first
/// video frame is ready. Same-album tracks keep the looping clip; the
/// player session survives leaving Now Playing so it does not reload.
class _HeroArtworkCard extends ConsumerWidget {
  final PlayableTrack track;
  final double size;

  const _HeroArtworkCard({
    required this.track,
    required this.size,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = waveIsDark(context);
    final motion = ref.watch(animatedArtworkProvider(
      AnimatedArtworkQuery(
        artist: track.artist,
        album: track.album,
        title: track.title,
      ),
    ));
    final motionUrl =
        motion.valueOrNull?.hasUrl == true ? motion.valueOrNull!.url : '';
    final motionReady = ref.watch(
      animatedArtworkSessionProvider.select((s) => s.isReadyFor(motionUrl)),
    );
    WaveArtwork stillCover() => WaveArtwork(
          url: track.artworkUrl,
          videoId: track.videoId,
          size: size,
          radius: 18,
          label: track.title,
          title: track.title,
          artist: track.artist,
        );

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.58 : 0.30),
            blurRadius: 48,
            offset: const Offset(0, 22),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.35 : 0.15),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAliasWithSaveLayer,
        child: Stack(
          fit: StackFit.expand,
          children: [
            stillCover(),
            if (motionUrl.isNotEmpty)
              AnimatedArtworkVideo(
                url: motionUrl,
                size: size,
              ),
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 480),
                  curve: Curves.easeOutCubic,
                  opacity: motionReady ? 0 : 1,
                  child: stillCover(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Track-change crossfade: the new child fades in with a slight rise
/// while the old fades out — WinUI connected-motion feel. The child must
/// carry a [ValueKey] that changes with the track.
class _TrackSwap extends StatelessWidget {
  final Widget child;
  const _TrackSwap({required this.child});

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: WaveMotion.normal,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.03),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

class _TrackMetadataSection extends ConsumerWidget {
  final PlayableTrack track;
  final bool alignCenter;

  const _TrackMetadataSection({
    super.key,
    required this.track,
    this.alignCenter = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = waveIsDark(context);
    final stream = ref.watch(
      playbackServiceProvider.select((s) => s.stream),
    );

    return Column(
      crossAxisAlignment:
          alignCenter ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      children: [
        Text(
          track.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: alignCenter ? TextAlign.center : TextAlign.start,
          style: WaveType.pageTitle.copyWith(
            fontSize: 26,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.4,
            color: Colors.white,
            shadows: const [
              Shadow(color: Color(0x66000000), blurRadius: 10),
            ],
          ),
        ),
        const SizedBox(height: 4),
        GestureDetector(
          onTap: () => context.go(
            '/search?q=${Uri.encodeComponent(track.artist)}',
          ),
          child: Text(
            track.artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: alignCenter ? TextAlign.center : TextAlign.start,
            style: WaveType.body.copyWith(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: Colors.white.withValues(alpha: 0.94),
              shadows: const [
                Shadow(color: Color(0x66000000), blurRadius: 10),
              ],
            ),
          ),
        ),
        if (track.album.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            track.album,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: alignCenter ? TextAlign.center : TextAlign.start,
            style: WaveType.meta.copyWith(
              fontSize: 13,
              color: Colors.white.withValues(alpha: 0.78),
              shadows: const [
                Shadow(color: Color(0x66000000), blurRadius: 10),
              ],
            ),
          ),
        ],
        if (stream != null) ...[
          const SizedBox(height: 8),
          WaveGlass(
            borderRadius: WaveRadius.controlsRadius,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Text(
              '${stream.qualityBadge} · ${stream.audioCodec}${stream.bitrateKbps > 0 ? ' · ${stream.bitrateKbps} kbps' : ''}',
              style: WaveType.overline.copyWith(
                fontSize: 9.5,
                fontWeight: FontWeight.w700,
                color: dark
                    ? WaveColors.textPrimary
                    : WaveColors.lightTextPrimary,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _UpNextPill extends ConsumerWidget {
  final bool alignCenter;

  const _UpNextPill({this.alignCenter = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = waveIsDark(context);
    final queue = ref.watch(playbackServiceProvider.select((s) => s.queue));
    final index = ref.watch(playbackServiceProvider.select((s) => s.currentIndex));

    final hasNext = index >= 0 && index + 1 < queue.length;
    if (!hasNext) return const SizedBox.shrink();

    final nextTrack = queue[index + 1];

    return Align(
      alignment: alignCenter ? Alignment.center : Alignment.centerLeft,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => ref.read(playbackServiceProvider.notifier).next(),
          child: WaveGlass(
            borderRadius: BorderRadius.circular(20),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'UP NEXT',
                  style: WaveType.overline.copyWith(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    color: waveAccent(context),
                  ),
                ),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 180),
                  child: Text(
                    '${nextTrack.title} · ${nextTrack.artist}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: WaveType.meta.copyWith(
                      fontSize: 11,
                      color: dark
                          ? WaveColors.textPrimary
                          : WaveColors.lightTextPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  FluentIcons.chevron_right,
                  size: 10,
                  color: dark
                      ? WaveColors.textSecondary
                      : WaveColors.lightTextSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NowAmbient extends StatelessWidget {
  final String artworkUrl;

  const _NowAmbient({required this.artworkUrl});

  @override
  Widget build(BuildContext context) {
    if (artworkUrl.isEmpty) return const SizedBox.shrink();
    return WaveAmbientMesh(
      artworkUrl: artworkUrl,
      isFullBleed: true,
      cinematic: true,
    );
  }
}
