import 'dart:async';
import 'dart:math' as math;

import 'package:audio_video_progress_bar/audio_video_progress_bar.dart' as avp;
import 'package:fluent_ui/fluent_ui.dart' hide RepeatMode;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/artwork/artwork_resolver.dart';
import '../../core/audio/stream_models.dart';
import '../../features/downloads/download_manager.dart';
import '../../features/library/playlists.dart';
import '../../features/lyrics/karaoke_lyrics_view.dart';
import '../../features/player/playback_service.dart';
import '../../widgets/ambient.dart';
import '../components/artwork.dart';
import '../components/buttons.dart' show LWTooltip, LWVolumeSlider;
import '../components/menus.dart';
import '../components/states.dart';
import '../queue/queue_panel.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

/// Centerpiece Fullscreen Player — Apple Music Split View & Cinematic Centering.
///
/// Mirrored directly from `desktop-app`'s `#fullscreen-cover-overlay`:
/// - 2-Column Split: Left media column (Large artwork, title/artist, Up Next,
///   timeline, transport, volume) + Right karaoke lyrics column.
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

    final upcomingKeys = ref.watch(
      playbackServiceProvider.select((s) {
        final q = s.queue;
        final i = s.currentIndex;
        if (i < 0 || q.isEmpty) return ('', '');
        final a = i + 1 < q.length ? q[i + 1].artworkUrl : '';
        final b = i + 2 < q.length ? q[i + 2].artworkUrl : '';
        return (a, b);
      }),
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
      final warm = [
        current.artworkUrl,
        upcomingKeys.$1,
        upcomingKeys.$2,
      ].where((u) => u.isNotEmpty).toList();
      if (warm.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ArtworkResolver.preload(context, warm, targetPx: 640);
        });
      }
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
                                controlsIdle: _controlsIdle,
                                maxHeight: constraints.maxHeight - 64,
                                maxWidth: constraints.maxWidth,
                              )
                            : _NarrowCenteredPane(
                                track: current,
                                lyricsVisible: _lyricsVisible,
                                controlsIdle: _controlsIdle,
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
          LWTooltip(
            message: 'Back',
            child: _FsIconButton(
              icon: FluentIcons.chevron_left,
              onTap: onClose,
            ),
          ),
          const Spacer(),
          LWTooltip(
            message: lyricsVisible ? 'Hide lyrics' : 'Show lyrics',
            child: _FsIconButton(
              icon: WaveIcons.lyrics,
              active: lyricsVisible,
              onTap: onToggleLyrics,
            ),
          ),
          const SizedBox(width: 10),
          LWTooltip(
            message: queueVisible ? 'Hide queue' : 'Show queue',
            child: _FsIconButton(
              icon: WaveIcons.queue,
              active: queueVisible,
              onTap: onToggleQueue,
            ),
          ),
          const SizedBox(width: 10),
          LWTooltip(
            message: visualizerEnabled ? 'Disable visualizer' : 'Enable visualizer',
            child: _FsIconButton(
              icon: WaveIcons.mixes,
              active: visualizerEnabled,
              onTap: onToggleVisualizer,
            ),
          ),
          const SizedBox(width: 10),
          LWTooltip(
            message: 'Close (Esc)',
            child: _FsIconButton(
              icon: WaveIcons.close,
              onTap: onClose,
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
        : _hover
            ? (dark ? WaveColors.textPrimary : WaveColors.lightTextPrimary)
            : (dark ? WaveColors.textSecondary : WaveColors.lightTextSecondary);

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
  final bool controlsIdle;
  final double maxHeight;
  final double maxWidth;

  const _DesktopDualPane({
    required this.track,
    required this.lyricsVisible,
    required this.controlsIdle,
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

                        // Track Info
                        _TrackMetadataSection(
                          track: track,
                          alignCenter: !lyricsVisible,
                        ),
                        const SizedBox(height: 10),

                        // Up Next Pill
                        _UpNextPill(alignCenter: !lyricsVisible),
                        const SizedBox(height: 18),

                        // Transport & Controls (fades when idle)
                        AnimatedOpacity(
                          duration: const Duration(milliseconds: 350),
                          opacity: controlsIdle ? 0.0 : 1.0,
                          child: ExcludeFocus(
                            excluding: controlsIdle,
                            child: IgnorePointer(
                              ignoring: controlsIdle,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  const _FullscreenTimeline(),
                                  const SizedBox(height: 14),
                                  _FullscreenTransportControls(track: track),
                                  const SizedBox(height: 16),
                                  const Center(
                                    child: _FullscreenVolumeSection(sliderWidth: 240),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
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
                                fontSize: 32.0,
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
  final bool controlsIdle;

  const _NarrowCenteredPane({
    required this.track,
    required this.lyricsVisible,
    required this.controlsIdle,
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
              _TrackMetadataSection(track: track, alignCenter: true),
              const SizedBox(height: 12),
              const _UpNextPill(alignCenter: true),
              const SizedBox(height: 20),
              AnimatedOpacity(
                duration: const Duration(milliseconds: 350),
                opacity: controlsIdle ? 0.0 : 1.0,
                child: ExcludeFocus(
                  excluding: controlsIdle,
                  child: IgnorePointer(
                    ignoring: controlsIdle,
                    child: Column(
                      children: [
                        const _FullscreenTimeline(),
                        const SizedBox(height: 12),
                        _FullscreenTransportControls(track: track),
                        const SizedBox(height: 14),
                        const _FullscreenVolumeSection(sliderWidth: 220),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Large Artwork Card with rounded corners and deep drop shadow.
class _HeroArtworkCard extends StatelessWidget {
  final PlayableTrack track;
  final double size;

  const _HeroArtworkCard({
    required this.track,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);

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
        child: WaveArtwork(
          url: track.artworkUrl,
          videoId: track.videoId,
          size: size,
          radius: 18,
          label: track.title,
        ),
      ),
    );
  }
}

class _TrackMetadataSection extends ConsumerWidget {
  final PlayableTrack track;
  final bool alignCenter;

  const _TrackMetadataSection({
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
              color: dark ? WaveColors.textSecondary : WaveColors.lightTextSecondary,
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
              color: dark ? WaveColors.textTertiary : WaveColors.lightTextTertiary,
            ),
          ),
        ],
        if (stream != null) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: (dark ? Colors.white : Colors.black).withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: waveDivider(context)),
            ),
            child: Text(
              '${stream.qualityBadge} · ${stream.audioCodec}${stream.bitrateKbps > 0 ? ' · ${stream.bitrateKbps} kbps' : ''}',
              style: WaveType.overline.copyWith(
                fontSize: 9.5,
                fontWeight: FontWeight.w700,
                color: dark ? WaveColors.textSecondary : WaveColors.lightTextSecondary,
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
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: (dark ? Colors.white : Colors.black).withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: waveDivider(context)),
            ),
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
                          ? WaveColors.textSecondary
                          : WaveColors.lightTextSecondary,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  FluentIcons.chevron_right,
                  size: 10,
                  color: waveTextTertiary(context),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FullscreenTimeline extends ConsumerWidget {
  const _FullscreenTimeline();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = waveIsDark(context);
    final clock = ref.watch(
      playbackServiceProvider.select((s) => (
        position: s.position,
        buffered: s.buffered,
        duration: s.duration,
      )),
    );
    final notifier = ref.read(playbackServiceProvider.notifier);

    return avp.ProgressBar(
      progress: clock.position,
      buffered: clock.buffered,
      total: clock.duration,
      onSeek: notifier.seek,
      barHeight: 4,
      thumbRadius: 6,
      thumbColor: dark ? Colors.white : Colors.black,
      thumbGlowColor: Colors.transparent,
      progressBarColor: dark ? Colors.white : Colors.black,
      bufferedBarColor:
          (dark ? Colors.white : Colors.black).withValues(alpha: 0.20),
      baseBarColor:
          (dark ? Colors.white : Colors.black).withValues(alpha: 0.12),
      timeLabelLocation: avp.TimeLabelLocation.sides,
      timeLabelTextStyle: WaveType.meta.copyWith(
        fontFeatures: const [FontFeature.tabularFigures()],
        color: dark ? WaveColors.textSecondary : WaveColors.lightTextSecondary,
      ),
    );
  }
}

class _FullscreenTransportControls extends ConsumerStatefulWidget {
  final PlayableTrack track;

  const _FullscreenTransportControls({required this.track});

  @override
  ConsumerState<_FullscreenTransportControls> createState() =>
      _FullscreenTransportControlsState();
}

class _FullscreenTransportControlsState
    extends ConsumerState<_FullscreenTransportControls> {
  final _moreFlyout = FlyoutController();

  @override
  void dispose() {
    _moreFlyout.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(
      playbackServiceProvider.select((s) => (
        shuffleEnabled: s.shuffleEnabled,
        isPlaying: s.isPlaying,
        isBuffering: s.isBuffering,
        repeatMode: s.repeatMode,
      )),
    );
    final notifier = ref.read(playbackServiceProvider.notifier);

    ref.watch(playlistRepositoryProvider);
    final liked = ref
        .read(playlistRepositoryProvider.notifier)
        .likedKeys()
        .contains(widget.track.queueKey);

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // 1. Like
        _TBtn(
          tooltip: liked ? 'Unlike' : 'Like',
          icon: WaveIcons.liked,
          active: liked,
          onTap: () => ref.read(playlistRepositoryProvider.notifier).toggleLiked(
                StoredTrack(
                  name: widget.track.title,
                  artist: widget.track.artist,
                  artworkUrl: widget.track.artworkUrl,
                  videoId: widget.track.videoId,
                ),
              ),
        ),
        // 2. Download
        _TBtn(
          tooltip: 'Download',
          icon: WaveIcons.downloadAction,
          onTap: () {
            ref.read(downloadManagerProvider.notifier).downloadTrack(
                  title: widget.track.title,
                  artist: widget.track.artist,
                  album: widget.track.album,
                  artworkUrl: widget.track.artworkUrl,
                );
          },
        ),
        // 3. Shuffle
        _TBtn(
          tooltip: 'Shuffle',
          icon: WaveIcons.shuffle,
          active: player.shuffleEnabled,
          onTap: notifier.toggleShuffle,
        ),
        // 4. Previous
        _TBtn(
          tooltip: 'Previous',
          icon: WaveIcons.previous,
          large: true,
          onTap: notifier.previous,
        ),
        const SizedBox(width: 8),
        // 5. Play / Pause (dead center)
        _PlayPauseDiscButton(
          isPlaying: player.isPlaying,
          isBuffering: player.isBuffering,
          onTap: notifier.toggle,
        ),
        const SizedBox(width: 8),
        // 6. Next
        _TBtn(
          tooltip: 'Next',
          icon: WaveIcons.next,
          large: true,
          onTap: notifier.next,
        ),
        // 7. Repeat
        _TBtn(
          tooltip: 'Repeat',
          icon: player.repeatMode == RepeatMode.one
              ? WaveIcons.repeatOne
              : WaveIcons.repeat,
          active: player.repeatMode != RepeatMode.off,
          onTap: notifier.cycleRepeat,
        ),
        // 8. Add to playlist
        _TBtn(
          tooltip: 'Add to playlist',
          icon: WaveIcons.addTo,
          onTap: () => showWaveAddToPlaylist(
            context,
            ref,
            title: widget.track.title,
            artist: widget.track.artist,
            artworkUrl: widget.track.artworkUrl,
            videoId: widget.track.videoId,
          ),
        ),
        // 9. More actions
        FlyoutTarget(
          controller: _moreFlyout,
          child: _TBtn(
            tooltip: 'More options',
            icon: WaveIcons.more,
            onTap: () {
              _moreFlyout.showFlyout(
                barrierColor: Colors.transparent,
                placementMode: FlyoutPlacementMode.topCenter,
                builder: (context) => MenuFlyout(
                  items: waveTrackMenuItems(
                    ref: ref,
                    title: widget.track.title,
                    artist: widget.track.artist,
                    artworkUrl: widget.track.artworkUrl,
                    videoId: widget.track.videoId,
                    playable: widget.track,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PlayPauseDiscButton extends StatefulWidget {
  final bool isPlaying;
  final bool isBuffering;
  final VoidCallback onTap;

  const _PlayPauseDiscButton({
    required this.isPlaying,
    required this.isBuffering,
    required this.onTap,
  });

  @override
  State<_PlayPauseDiscButton> createState() => _PlayPauseDiscButtonState();
}

class _PlayPauseDiscButtonState extends State<_PlayPauseDiscButton> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final accent = waveAccent(context);
    final onAccent =
        accent.computeLuminance() > 0.5 ? Colors.black : Colors.white;

    return LWTooltip(
      message: widget.isPlaying ? 'Pause (Space)' : 'Play (Space)',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedScale(
            scale: _pressed ? 0.92 : (_hover ? 1.05 : 1.0),
            duration: WaveMotion.fast,
            curve: Curves.easeOutCubic,
            child: Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: accent,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Center(
                child: widget.isBuffering
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: ProgressRing(
                          strokeWidth: 2.5,
                          activeColor: onAccent,
                          backgroundColor: onAccent.withValues(alpha: 0.25),
                        ),
                      )
                    : Icon(
                        widget.isPlaying ? WaveIcons.pause : WaveIcons.play,
                        size: 22,
                        color: onAccent,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FullscreenVolumeSection extends ConsumerWidget {
  final double sliderWidth;

  const _FullscreenVolumeSection({this.sliderWidth = 240});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final volume = ref.watch(
      playbackServiceProvider.select((s) => s.volume),
    );
    final notifier = ref.read(playbackServiceProvider.notifier);

    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _VolumeMuteButton(
          volume: volume,
          onMute: () => notifier.setVolume(volume == 0 ? 1 : 0),
        ),
        const SizedBox(width: 8),
        LWVolumeSlider(
          value: volume,
          width: sliderWidth,
          onChanged: notifier.setVolume,
        ),
      ],
    );
  }
}

class _VolumeMuteButton extends StatefulWidget {
  final double volume;
  final VoidCallback onMute;

  const _VolumeMuteButton({
    required this.volume,
    required this.onMute,
  });

  @override
  State<_VolumeMuteButton> createState() => _VolumeMuteButtonState();
}

class _VolumeMuteButtonState extends State<_VolumeMuteButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final icon = widget.volume == 0
        ? WaveIcons.volumeMute
        : WaveIcons.volume;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onMute,
        child: Container(
          width: 32,
          height: 32,
          color: Colors.transparent,
          child: Icon(
            icon,
            size: 16,
            color: _hover
                ? (dark ? Colors.white : Colors.black)
                : (dark ? WaveColors.textSecondary : WaveColors.lightTextSecondary),
          ),
        ),
      ),
    );
  }
}

class _TBtn extends StatefulWidget {
  final String tooltip;
  final IconData icon;
  final bool active;
  final bool large;
  final VoidCallback onTap;

  const _TBtn({
    required this.tooltip,
    required this.icon,
    this.active = false,
    this.large = false,
    required this.onTap,
  });

  @override
  State<_TBtn> createState() => _TBtnState();
}

class _TBtnState extends State<_TBtn> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final color = widget.active
        ? waveAccent(context)
        : _hover
            ? (dark ? WaveColors.textPrimary : WaveColors.lightTextPrimary)
            : (dark ? WaveColors.textSecondary : WaveColors.lightTextSecondary);

    return LWTooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: SizedBox(
            width: 34,
            height: 36,
            child: Center(
              child: AnimatedScale(
                scale: _pressed ? 0.92 : (_hover ? 1.08 : 1.0),
                duration: WaveMotion.fast,
                curve: WaveMotion.standard,
                child: Icon(
                  widget.icon,
                  size: widget.large ? 18 : 15,
                  color: color,
                ),
              ),
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
    return WaveAmbientMesh(artworkUrl: artworkUrl, isFullBleed: true);
  }
}
