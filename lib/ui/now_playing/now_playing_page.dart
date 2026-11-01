import 'dart:async';
import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart' hide RepeatMode;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/window_lifecycle.dart';
import '../../core/artwork/animated_artwork_service.dart';
import '../../core/artwork/animated_artwork_session.dart';
import '../../core/artwork/artwork_resolver.dart';
import '../../core/audio/stream_models.dart';
import '../../features/lyrics/karaoke_lyrics_view.dart';
import '../../features/player/playback_service.dart';
import '../../features/video/synced_video_controller.dart';
import '../components/ambient.dart';
import '../components/animated_artwork_video.dart';
import '../components/artist_line.dart';
import '../components/artwork.dart';
import '../components/buttons.dart' show LWTooltip;
import '../components/states.dart';
import '../queue/queue_panel.dart';
import '../theme/haze.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';
import 'music_video_backdrop.dart';
import 'now_playing_chrome.dart';

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
  DateTime _lastHoverAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastArmAt = DateTime.fromMillisecondsSinceEpoch(0);
  String _preloadedKey = '';
  // Separate arming key for the motion-art lookup: it is gated on the
  // visualizer toggle (the only thing that renders a clip), so flipping
  // the toggle on must re-arm for the current track.
  String _prefetchedMotionKey = '';
  // Memoized in-page queue drawer: without this every page build
  // reconstructs the full row list (menus, tooltips, flyout targets).
  // Same instance across builds => element update short-circuits.
  // No changing params (reads providers internally, stable onClose).
  Widget? _queueDrawerCache;
  // True once the video has fully faded in: the ambient mesh behind it is
  // then unmounted instead of being re-rasterized under every video frame.
  bool _videoCovers = false;
  // Held so dispose() can detach without touching `ref` (not allowed then).
  SyncedVideoController? _video;

  void _closeQueueDrawer() {
    if (_queueVisible) setState(() => _queueVisible = false);
  }

  @override
  void initState() {
    super.initState();
    _resetIdleTimer();
    _autoHideSeconds = ref.read(nowPlayingAutoHideProvider);
    final open = ref.read(nowPlayingOpenProvider.notifier);
    _openFlag = open;
    // Provider state cannot change while the tree is building.
    Future.microtask(() => open.state = true);
    // The synced music video only plays while this page is open.
    final video = ref.read(syncedVideoControllerProvider);
    _video = video;
    video.attach();
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _video?.detach();
    // Leaving the page brings the app's side rail back. Deferred: provider
    // state cannot change while the tree is being torn down.
    final open = _openFlag;
    if (open != null) Future.microtask(() => open.state = false);
    super.dispose();
  }

  int _autoHideSeconds = 3;
  StateController<bool>? _openFlag;

  /// Hides (or brings back) every control on the page and the app's side
  /// rail. Only a click brings them back: hovering never does.
  void _setHidden(bool hidden) {
    if (_controlsIdle == hidden || !mounted) return;
    setState(() => _controlsIdle = hidden);
  }

  /// Pointer activity while the controls are showing keeps them up. While
  /// they are hidden it does nothing: they return on a click only.
  void _resetIdleTimer() {
    _lastHoverAt = DateTime.now();
    if (_controlsIdle) return;
    // Throttle per-pixel hover re-arms: high-DPI mice poll ~1000Hz and each
    // event cancelled/armed a Timer. The timeout self-corrects against
    // _lastHoverAt, so hide still lands exactly N s after the last move.
    final now = DateTime.now();
    if (now.difference(_lastArmAt).inMilliseconds < 200 &&
        (_idleTimer?.isActive ?? false)) {
      return;
    }
    _armIdleTimer();
  }

  /// A click or tap anywhere: shows the controls again.
  void _onPointerDown() {
    if (_controlsIdle) {
      _lastHoverAt = DateTime.now();
      _setHidden(false);
      _armIdleTimer();
    } else {
      _resetIdleTimer();
    }
  }

  void _armIdleTimer() {
    _lastArmAt = DateTime.now();
    _idleTimer?.cancel();
    if (_autoHideSeconds <= 0) return;
    _idleTimer = Timer(Duration(seconds: _autoHideSeconds), _onIdleTimeout);
  }

  void _onIdleTimeout() {
    if (!mounted) return;
    final limit = Duration(seconds: _autoHideSeconds);
    final elapsed = DateTime.now().difference(_lastHoverAt);
    if (elapsed < limit) {
      // A throttled hover landed after the last arm: wait the remainder.
      _idleTimer = Timer(limit - elapsed, _onIdleTimeout);
      return;
    }
    // Controls only hide over a playing music video, never over the plain
    // page, and never out from under an open queue drawer. Keep checking so
    // they hide as soon as a video starts.
    if (_queueVisible || !ref.read(syncedVideoControllerProvider).visible) {
      _armIdleTimer();
      return;
    }
    _setHidden(true);
  }

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(playbackServiceProvider.select((s) => s.current));

    final fullscreen = ref.watch(nowPlayingFullscreenProvider);
    // Auto aims at the display: re-check once the window has settled.
    ref.listen<bool>(nowPlayingFullscreenProvider, (_, _) {
      Future<void>.delayed(const Duration(milliseconds: 900), () {
        if (mounted) {
          ref.read(syncedVideoControllerProvider).onViewportChanged();
        }
      });
    });
    ref.listen<int>(nowPlayingAutoHideProvider, (_, seconds) {
      _autoHideSeconds = seconds;
      if (seconds <= 0) {
        _idleTimer?.cancel();
        _setHidden(false);
      } else {
        _lastHoverAt = DateTime.now();
        _armIdleTimer();
      }
    });

    final visualizerEnabled = ref.watch(visualizerEnabledProvider);
    // True only once the official video is fetched, decoded and locked to
    // the audio clock; until then the page is exactly as before.
    final videoOn = ref.watch(
      syncedVideoControllerProvider.select((c) => c.visible),
    );
    if (!videoOn) {
      _videoCovers = false;
      // The video went away (track change, switched off): bring the
      // controls back rather than leaving a bare page.
      if (_controlsIdle) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _setHidden(false);
        });
      }
    }

    if (current == null) {
      // Same stage as the playing page, for the same reason: this route must
      // not depend on whatever happens to be behind it.
      return ColoredBox(
        color: waveBackground(context),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: WaveEmpty(
              icon: WaveIcons.music,
              title: 'Nothing playing',
              subtitle: 'Pick something from Home, Discover or Search and it will take centre stage here.',
              actionLabel: 'Browse music',
              onAction: () => context.go('/home'),
            ),
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
      });
    }

    // Motion-art lookup is the expensive half (iTunes/Deezer search plus a
    // possible YTM album backfill) and is only ever rendered while the
    // visualizer is on, so nothing prefetches it while this page is closed
    // and nothing looks it up when the toggle is off. Re-arms on the toggle
    // so flipping it on warms the current track instead of waiting for the
    // first fade.
    if (visualizerEnabled && current.queueKey != _prefetchedMotionKey) {
      _prefetchedMotionKey = current.queueKey;
      final snap = ref.read(playbackServiceProvider);
      final q = snap.queue;
      final i = snap.currentIndex;
      final anim = ref.read(animatedArtworkServiceProvider);
      anim.prefetch(
        AnimatedArtworkQuery(
          artist: current.artist,
          album: current.album,
          title: current.title,
        ),
      );
      for (final offset in [1, 2]) {
        if (i + offset >= q.length) continue;
        final track = q[i + offset];
        anim.prefetch(
          AnimatedArtworkQuery(
            artist: track.artist,
            album: track.album,
            title: track.title,
          ),
        );
      }
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (ref.read(nowPlayingFullscreenProvider)) {
            ref.read(nowPlayingFullscreenProvider.notifier).state = false;
          } else if (_queueVisible) {
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
        cursor: _controlsIdle
            ? SystemMouseCursors.none
            : SystemMouseCursors.basic,
        onHover: (_) => _resetIdleTimer(),
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => _onPointerDown(),
          child: Stack(
            children: [
              // The stage belongs to the page. Without a background of its own
              // the black was borrowed from whatever sat behind the route, so
              // closing faded the ambient out over a backdrop that could not
              // fade with it — and then the backdrop vanished the instant the
              // route did. Painting it here keeps the whole screen, backdrop
              // included, inside the page's own transition.
              Positioned.fill(
                child: ColoredBox(color: waveBackground(context)),
              ),

              // Background Visualizer. Fully hidden by an opaque video, so it
              // is dropped once the video covers it: Flutter still paints
              // layers that are merely occluded.
              if (!(videoOn && _videoCovers))
                Positioned.fill(
                  child: TickerMode(
                    enabled: !videoOn,
                    child: RepaintBoundary(
                      child: _NowAmbient(artworkUrl: current.artworkUrl),
                    ),
                  ),
                ),

              // Synced music video, stretched edge to edge behind everything.
              Positioned.fill(
                child: MusicVideoBackdrop(
                  visible: videoOn,
                  lyricsVisible: _lyricsVisible,
                  onFadeEnd: (covering) {
                    if (mounted && _videoCovers != covering) {
                      setState(() => _videoCovers = covering);
                    }
                  },
                ),
              ),

              // Main Layout Content
              Positioned.fill(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final isWide = constraints.maxWidth > 860;

                    final page = Column(
                      children: [
                        // Top Actions Bar (Fadeable on idle)
                        AnimatedOpacity(
                          duration: waveMotion(
                            context,
                            const Duration(milliseconds: 350),
                          ),
                          opacity: _controlsIdle ? 0.0 : 1.0,
                          child: ExcludeFocus(
                            excluding: _controlsIdle,
                            child: IgnorePointer(
                              ignoring: _controlsIdle,
                              child: _TopActionsBar(
                                fullscreen: fullscreen,
                                onExitFullscreen: () =>
                                    ref
                                            .read(
                                              nowPlayingFullscreenProvider
                                                  .notifier,
                                            )
                                            .state =
                                        false,
                                lyricsVisible: _lyricsVisible,
                                queueVisible: _queueVisible,
                                visualizerEnabled: visualizerEnabled,
                                onToggleLyrics: () {
                                  _resetIdleTimer();
                                  setState(
                                    () => _lyricsVisible = !_lyricsVisible,
                                  );
                                },
                                onToggleQueue: () {
                                  _resetIdleTimer();
                                  setState(
                                    () => _queueVisible = !_queueVisible,
                                  );
                                },
                                onToggleVisualizer: () {
                                  _resetIdleTimer();
                                  ref
                                      .read(visualizerEnabledProvider.notifier)
                                      .toggle();
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
                                  hideArtwork: videoOn,
                                  hideChrome: _controlsIdle,
                                )
                              : _NarrowCenteredPane(
                                  track: current,
                                  lyricsVisible: _lyricsVisible,
                                  hideArtwork: videoOn,
                                  hideChrome: _controlsIdle,
                                ),
                        ),
                      ],
                    );
                    // Light text would vanish on a light theme over moving
                    // footage, so the chrome reads as dark while it plays.
                    if (!videoOn || waveIsDark(context)) return page;
                    return FluentTheme(
                      data: FluentTheme.of(context)
                          .copyWith(brightness: Brightness.dark),
                      child: page,
                    );
                  },
                ),
              ),

              // Scrim backdrop when queue drawer is active
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: !_queueVisible,
                  child: AnimatedOpacity(
                    duration: waveMotion(context, WaveMotion.normal),
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

              // Contextual Queue drawer smoothly sliding from right.
              // Offstage when shut: skips paint/raster of the 8 image rows
              // while closed (scroll offset preserved, no remount).
              AnimatedPositioned(
                duration: waveMotion(context, WaveMotion.normal),
                curve: Curves.easeOutCubic,
                top: 0,
                bottom: 0,
                right: _queueVisible ? 0 : -380,
                width: 360,
                child: ExcludeFocus(
                  excluding: !_queueVisible,
                  child: IgnorePointer(
                    ignoring: !_queueVisible,
                    child: Offstage(
                      offstage: !_queueVisible,
                      child: _queueDrawerCache ??= WaveQueuePanel(
                        onClose: _closeQueueDrawer,
                      ),
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

class _TopActionsBar extends StatelessWidget {
  final bool lyricsVisible;
  final bool queueVisible;
  final bool visualizerEnabled;
  final VoidCallback onToggleLyrics;
  final VoidCallback onToggleQueue;
  final VoidCallback onToggleVisualizer;
  final VoidCallback onClose;

  /// Full screen shows only an X, like a browser's: everything else on the
  /// bar would be app chrome in a view that is meant to be just the picture.
  final bool fullscreen;
  final VoidCallback onExitFullscreen;

  const _TopActionsBar({
    required this.fullscreen,
    required this.onExitFullscreen,
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
    if (fullscreen) {
      return Container(
        height: 54,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Row(
          children: [
            const Spacer(),
            WaveGlass(
              blur: false,
              borderRadius: WaveRadius.menuRadius,
              padding: const EdgeInsets.all(4),
              child: LWTooltip(
                message: 'Exit full screen (Esc)',
                child: _FsIconButton(
                  icon: WaveIcons.close,
                  onTap: onExitFullscreen,
                ),
              ),
            ),
          ],
        ),
      );
    }
    return Container(
      height: 54,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        children: [
          WaveGlass(
            blur: false,
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
            blur: false,
            borderRadius: WaveRadius.menuRadius,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Row(
              spacing: 5,
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
                // No close cross here: the Back chevron leaves the page and
                // Esc still works. The cross belongs to full screen only.
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
          duration: waveMotion(context, WaveMotion.fast),
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: widget.active
                ? accent.withValues(alpha: 0.15)
                : _hover
                ? (dark ? Colors.white : Colors.black).withValues(alpha: 0.10)
                : Colors.transparent,
            borderRadius: WaveRadius.controlsRadius,
            border: Border.all(
              color: widget.active
                  ? accent.withValues(alpha: 0.35)
                  : Colors.transparent,
            ),
          ),
          child: Center(child: Icon(widget.icon, size: 16, color: color)),
        ),
      ),
    );
  }
}

/// Mutes karaoke tickers while the window is minimized/tray-hidden, on top of
/// the lyrics-open gate, and while this route is still animating in or out.
/// Side-by-side (unfocused but visible) keeps ticking. Framework TickerMode:
/// auto-resumes on restore, clock resyncs from the snapshot. Scoped
/// ConsumerWidget so visibility flips rebuild only this leaf, never the page.
///
/// The transition gate keeps the lyrics engine's ~60 Hz repaints out of a
/// half-transparent layer: nothing is readable while the page fades, and on
/// the way out those repaints compete with the transition's last frames. It
/// listens to the route animation's *status*, never its value, so a navigation
/// costs two rebuilds instead of one per frame.
class _VisibleTicker extends ConsumerStatefulWidget {
  final bool enabled;
  final Widget child;
  const _VisibleTicker({required this.enabled, required this.child});

  @override
  ConsumerState<_VisibleTicker> createState() => _VisibleTickerState();
}

class _VisibleTickerState extends ConsumerState<_VisibleTicker> {
  Animation<double>? _routeAnimation;
  bool _routeSettled = true;

  /// A freshly pushed route reports `forward` on its first build, so the
  /// initial state comes from [Animation.isAnimating] rather than assuming
  /// settled.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animation = ModalRoute.of(context)?.animation;
    if (animation == _routeAnimation) return;
    _routeAnimation?.removeStatusListener(_onRouteStatus);
    _routeAnimation = animation;
    animation?.addStatusListener(_onRouteStatus);
    _routeSettled = !(animation?.isAnimating ?? false);
  }

  void _onRouteStatus(AnimationStatus status) {
    final settled =
        status == AnimationStatus.completed ||
        status == AnimationStatus.dismissed;
    if (settled != _routeSettled && mounted) {
      setState(() => _routeSettled = settled);
    }
  }

  @override
  void dispose() {
    _routeAnimation?.removeStatusListener(_onRouteStatus);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visible = ref.watch(windowVisibleProvider);
    return TickerMode(
      enabled: widget.enabled && visible && _routeSettled,
      child: widget.child,
    );
  }
}

/// Desktop Dual-Pane split layout with smooth cinematic centering when lyrics are hidden.
class _DesktopDualPane extends StatelessWidget {
  final PlayableTrack track;
  final bool lyricsVisible;
  final bool hideArtwork;

  /// Fades the title block, Up Next and the lyrics header bar; lyrics stay.
  final bool hideChrome;

  const _DesktopDualPane({
    required this.track,
    required this.lyricsVisible,
    this.hideArtwork = false,
    this.hideChrome = false,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final maxHeight = math.max(0.0, constraints.maxHeight - 24.0);

        // Symmetrical desktop dual pane layout:
        // When lyrics are visible, media column and lyrics column have harmonious, balanced
        // widths, leaving identical horizontal margins (emptiness) on both sides.
        final colWidth = lyricsVisible
            ? math.min(maxWidth * 0.36, maxHeight * 0.48).clamp(340.0, 420.0)
            : math.min(maxWidth * 0.55, maxHeight * 0.52).clamp(360.0, 480.0);

        final gap = lyricsVisible ? (maxWidth * 0.04).clamp(40.0, 64.0) : 0.0;

        // Harmonized lyrics column width, balancing the visual weight of the left column
        final targetLyricsWidth = (colWidth * 1.35).clamp(460.0, 580.0);
        final maxAllowedLyricsWidth = math.max(
          320.0,
          maxWidth - colWidth - gap - 48.0,
        );
        final lyricsWidth = lyricsVisible
            ? math.min(targetLyricsWidth, maxAllowedLyricsWidth)
            : 0.0;

        return Center(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 24),
            child: SizedBox(
              height: maxHeight,
              child: Row(
                mainAxisSize: MainAxisSize.max,
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Left Column (Media Player) — the metadata keeps its
                  // intrinsic height; artwork takes whatever remains.
                  AnimatedContainer(
                    duration: waveMotion(
                      context,
                      const Duration(milliseconds: 500),
                    ),
                    curve: Curves.easeInOutCubic,
                    width: colWidth,
                    height: maxHeight,
                    child: RepaintBoundary(
                      child: Column(
                        mainAxisSize: MainAxisSize.max,
                        crossAxisAlignment: lyricsVisible
                            ? CrossAxisAlignment.start
                            : CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: LayoutBuilder(
                              builder: (context, artConstraints) {
                                final artSize = math.max(
                                  0.0,
                                  math.min(
                                    artConstraints.maxWidth,
                                    artConstraints.maxHeight,
                                  ),
                                );
                                if (artSize <= 0) {
                                  return const SizedBox.shrink();
                                }
                                return Center(
                                  child: _ArtworkFade(
                                    hidden: hideArtwork,
                                    child: _HeroArtworkCard(
                                      track: track,
                                      size: artSize,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                          const SizedBox(height: 16),

                          // Track Info & Badges — crossfades on track change.
                          _ChromeFade(
                            hidden: hideChrome,
                            child: _TrackSwap(
                              child: _TrackMetadataSection(
                                key: ValueKey(track.queueKey),
                                track: track,
                                alignCenter: !lyricsVisible,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Gap
                  AnimatedContainer(
                    duration: waveMotion(
                      context,
                      const Duration(milliseconds: 500),
                    ),
                    curve: Curves.easeInOutCubic,
                    width: gap,
                  ),

                  // Right Column (Apple Music Karaoke Lyrics Pane)
                  AnimatedContainer(
                    duration: waveMotion(
                      context,
                      const Duration(milliseconds: 500),
                    ),
                    curve: Curves.easeInOutCubic,
                    width: lyricsWidth,
                    height: maxHeight,
                    child: ClipRect(
                      child: AnimatedOpacity(
                        duration: waveMotion(
                          context,
                          const Duration(milliseconds: 350),
                        ),
                        curve: Curves.easeInOutCubic,
                        opacity: lyricsVisible ? 1.0 : 0.0,
                        child: ExcludeFocus(
                          excluding: !lyricsVisible,
                          child: IgnorePointer(
                            ignoring: !lyricsVisible,
                            child: SizedBox(
                              height: maxHeight,
                              width: lyricsWidth,
                              child: Offstage(
                                offstage: !lyricsVisible,
                                child: _VisibleTicker(
                                  enabled: lyricsVisible,
                                  child: RepaintBoundary(
                                    child: WaveKaraokeLyricsView(
                                      track: track,
                                      compact: false,
                                      showHeaderControls: true,
                                      controlsVisible: !hideChrome,
                                      fontSize: 36.0,
                                      isActive: lyricsVisible,
                                    ),
                                  ),
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
        );
      },
    );
  }
}

/// Narrow window presentation.
class _NarrowCenteredPane extends StatelessWidget {
  final PlayableTrack track;
  final bool lyricsVisible;
  final bool hideArtwork;

  /// Fades the title block, Up Next and the lyrics header bar; lyrics stay.
  final bool hideChrome;

  const _NarrowCenteredPane({
    required this.track,
    required this.lyricsVisible,
    this.hideArtwork = false,
    this.hideChrome = false,
  });

  @override
  Widget build(BuildContext context) {
    final coverArtSubtree = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.max,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final artSize = math.max(
                      0.0,
                      math.min(
                        math.min(constraints.maxWidth, constraints.maxHeight),
                        360.0,
                      ),
                    );
                    if (artSize <= 0) {
                      return const SizedBox.shrink();
                    }
                    return Center(
                      child: _ArtworkFade(
                        hidden: hideArtwork,
                        child: _HeroArtworkCard(track: track, size: artSize),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
              _ChromeFade(
                hidden: hideChrome,
                child: _TrackSwap(
                  child: _TrackMetadataSection(
                    key: ValueKey(track.queueKey),
                    track: track,
                    alignCenter: true,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final lyricsSubtree = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: _VisibleTicker(
        enabled: lyricsVisible,
        child: RepaintBoundary(
          child: WaveKaraokeLyricsView(
            track: track,
            compact: true,
            showHeaderControls: true,
            controlsVisible: !hideChrome,
            isActive: lyricsVisible,
          ),
        ),
      ),
    );

    return IndexedStack(
      index: lyricsVisible ? 1 : 0,
      children: [coverArtSubtree, lyricsSubtree],
    );
  }
}

/// Large Artwork Card with rounded corners and deep drop shadow.
///
/// Motion art sits under a still sleeve that fades away once the first
/// video frame is ready. Same-album tracks keep the looping clip; the
/// player session survives leaving Now Playing so it does not reload.
///
/// Single still only: the sleeve above the video is the one and only
/// still layer. A second still beneath the video used to look
/// harmless (always covered), but on the software texture path the
/// video frames can carry partial alpha — and then the hidden still
/// bleeds through as a persistent overexposed double image. With one
/// still, any translucency blends into the blurred aura instead.
///
/// The live tile is isolated in a [RepaintBoundary] so the two large
/// blurs + clip don't re-rasterize on every video frame — without it
/// each texture upload repainted the static shadows too.
/// Motion art only mounts while the visualizer is enabled: the toggle
/// promises a calm static page, and an invisible video keeps
/// decoding + uploading textures otherwise.
class _HeroArtworkCard extends ConsumerStatefulWidget {
  final PlayableTrack track;
  final double size;

  const _HeroArtworkCard({required this.track, required this.size});

  @override
  ConsumerState<_HeroArtworkCard> createState() => _HeroArtworkCardState();
}

class _HeroArtworkCardState extends ConsumerState<_HeroArtworkCard> {
  /// True once the ready fade completes: the sleeve unmounts instead
  /// of sitting at opacity 0, where it would still rasterize (and
  /// alpha-blend) a full-res still on every video frame.
  bool _sleeveGone = false;
  String _lastMotionUrl = '';
  String _lastMotionFallbackUrl = '';

  @override
  Widget build(BuildContext context) {
    final ref = this.ref;
    final track = widget.track;
    final size = widget.size;
    final dark = waveIsDark(context);
    // Visualizer toggle owns ALL page motion: aura + motion-art clip.
    final visualizerOn = ref.watch(visualizerEnabledProvider);
    final motion = ref.watch(
      animatedArtworkProvider(
        AnimatedArtworkQuery(
          artist: track.artist,
          album: track.album,
          title: track.title,
        ),
      ),
    );
    final motionUrl = motion.valueOrNull?.hasUrl == true
        ? motion.valueOrNull!.url
        : '';
    final motionFallbackUrl = motion.valueOrNull?.fallbackUrl ?? '';
    if (!motion.isLoading) {
      _lastMotionUrl = motionUrl;
      _lastMotionFallbackUrl = motionFallbackUrl;
    } else if (motionUrl.isNotEmpty) {
      _lastMotionUrl = motionUrl;
      _lastMotionFallbackUrl = motionFallbackUrl;
    }
    final activeVideoUrl = motionUrl.isNotEmpty
        ? motionUrl
        : (motion.isLoading ? _lastMotionUrl : '');
    final activeVideoFallbackUrl = motionUrl.isNotEmpty
        ? motionFallbackUrl
        : (motion.isLoading ? _lastMotionFallbackUrl : '');
    final motionReady =
        visualizerOn &&
        motionUrl.isNotEmpty &&
        ref.watch(
          animatedArtworkSessionProvider.select((s) => s.isReadyFor(motionUrl)),
        );
    // Any not-ready state re-arms the sleeve (track change, toggle
    // off, session reset). Assigned, not setState: it only feeds this
    // build's output, so no extra frame is scheduled.
    if (!motionReady) _sleeveGone = false;
    final showSleeve = !motionReady || !_sleeveGone;
    WaveArtwork stillCover() => WaveArtwork(
      url: track.artworkUrl,
      videoId: track.videoId,
      size: size,
      radius: WaveRadius.hero,
      label: track.title,
      title: track.title,
      artist: track.artist,
    );

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: WaveRadius.heroRadius,
        // Kept shallow on purpose: large blurs over a full-window ambient
        // stage retain big GPU surfaces on Windows ANGLE.
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.58 : 0.30),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.35 : 0.15),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      // Boundary sits INSIDE the shadows: the live video repaints
      // per frame in its own layer while the blurs rasterize once.
      // Plain antiAlias (not ...WithSaveLayer): the offscreen target
      // switch every video frame cost milliseconds on weak raster.
      child: RepaintBoundary(
        child: ClipRRect(
          borderRadius: WaveRadius.heroRadius,
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // No bottom still: the fading sleeve below is the only
              // still layer (see class docs). When there is no motion
              // clip it stays opaque and the tile is just the cover.
              if (visualizerOn && activeVideoUrl.isNotEmpty)
                AnimatedArtworkVideo(
                  url: activeVideoUrl,
                  fallbackUrl: activeVideoFallbackUrl,
                  size: size,
                ),
              if (showSleeve)
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedOpacity(
                      // Smooth 480ms crossfade from still cover to animated
                      // cover once the video is decoded and playing; instant
                      // 0ms snap back to opaque when switching tracks so a
                      // mid-fade track change never exposes a black frame.
                      duration: motionReady
                          ? waveMotion(
                              context,
                              const Duration(milliseconds: 480),
                            )
                          : Duration.zero,
                      curve: Curves.easeOutCubic,
                      opacity: motionReady ? 0 : 1,
                      onEnd: () {
                        // Fade done while still ready: unmount so the
                        // invisible still stops rasterizing per video
                        // frame. Guarded on motionReady so a 0->1 snap
                        // never unmounts the sleeve while not ready.
                        if (mounted && motionReady) {
                          setState(() => _sleeveGone = true);
                        }
                      },
                      child: stillCover(),
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

/// Fades a block of controls out and makes it untouchable, keeping its
/// space so nothing on the page moves when controls hide or return.
class _ChromeFade extends StatelessWidget {
  final bool hidden;
  final Widget child;
  const _ChromeFade({required this.hidden, required this.child});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: hidden,
      child: ExcludeFocus(
        excluding: hidden,
        child: AnimatedOpacity(
          duration: waveMotion(context, const Duration(milliseconds: 350)),
          curve: Curves.easeOutCubic,
          opacity: hidden ? 0 : 1,
          child: child,
        ),
      ),
    );
  }
}

/// Fades the cover away while the music video plays behind the page. The
/// slot keeps its size so the title, lyrics and controls never move; once
/// faded out the card leaves the tree so it stops rasterizing.
class _ArtworkFade extends StatefulWidget {
  final bool hidden;
  final Widget child;
  const _ArtworkFade({required this.hidden, required this.child});

  @override
  State<_ArtworkFade> createState() => _ArtworkFadeState();
}

class _ArtworkFadeState extends State<_ArtworkFade> {
  bool _gone = false;

  @override
  void didUpdateWidget(covariant _ArtworkFade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.hidden) _gone = false;
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: widget.hidden,
      child: AnimatedOpacity(
        duration: waveMotion(context, const Duration(milliseconds: 420)),
        curve: Curves.easeOutCubic,
        opacity: widget.hidden ? 0 : 1,
        onEnd: () {
          if (mounted && widget.hidden && !_gone) {
            setState(() => _gone = true);
          }
        },
        // The card sits in a Center inside an Expanded slot, so dropping
        // it moves nothing; it also stops any motion-art decoding.
        child: _gone && widget.hidden ? const SizedBox.shrink() : widget.child,
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
      duration: waveMotion(context, WaveMotion.normal),
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

const _metadataShadow = [Shadow(color: Color(0x59000000), blurRadius: 10)];

/// Split the stream spec into a tier ("HI-RES") and a quieter detail
/// ("FLAC · 4608 kbps") without repeating the tier inside the codec.
({String tier, String detail})? _streamQualityParts(ResolvedStream stream) {
  final badge = stream.qualityBadge.trim().toUpperCase();
  final codec = stream.audioCodec.trim().toUpperCase();

  String tier;
  String? codecDetail;
  if (badge.isEmpty) {
    tier = codec;
  } else {
    tier = badge;
    if (codec.isNotEmpty && codec != badge) {
      if (codec.contains(badge)) {
        final remainder = codec
            .replaceFirst(badge, '')
            .replaceFirst(RegExp(r'^[\s·\-]+'), '')
            .trim();
        if (remainder.isNotEmpty) codecDetail = remainder;
      } else if (!badge.contains(codec)) {
        codecDetail = codec;
      }
    }
  }

  final detailParts = <String>[
    ?codecDetail,
    if (stream.bitrateKbps > 0) '${stream.bitrateKbps} kbps',
  ];
  if (tier.isEmpty && detailParts.isEmpty) return null;
  return (tier: tier.isEmpty ? 'AUDIO' : tier, detail: detailParts.join(' · '));
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
    final stream = ref.watch(playbackServiceProvider.select((s) => s.stream));
    var quality = stream == null ? null : _streamQualityParts(stream);
    // What the picture behind the page is actually playing at.
    final videoLabel = ref.watch(
      syncedVideoControllerProvider.select(
        (c) => c.visible ? c.currentQualityLabel : '',
      ),
    );
    // Why a video that exists is not showing yet.
    final videoStatus = ref.watch(
      syncedVideoControllerProvider.select((c) => c.status),
    );
    final videoEstimated = ref.watch(
      syncedVideoControllerProvider.select((c) => c.timingEstimated),
    );
    final videoNote = videoLabel.isNotEmpty
        ? 'VIDEO $videoLabel${videoEstimated ? ' · timing estimated' : ''}'
        : switch (videoStatus) {
            'loading' => 'VIDEO loading…',
            'syncing' => 'VIDEO syncing…',
            'unsynced' => 'VIDEO not synced',
            _ => '',
          };
    if (videoNote.isNotEmpty) {
      quality = quality == null
          ? (tier: 'VIDEO', detail: videoNote.replaceFirst('VIDEO ', ''))
          : (
              tier: quality.tier,
              detail: quality.detail.isEmpty
                  ? videoNote
                  : '${quality.detail} · $videoNote',
            );
    }

    final showDistinctAlbum =
        track.album.isNotEmpty &&
        track.album.toLowerCase().trim() != track.title.toLowerCase().trim();

    final artistStyle = WaveType.meta.copyWith(
      fontSize: 14,
      height: 1.45,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.1,
      shadows: _metadataShadow,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: alignCenter
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: [
        Text(
          track.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: alignCenter ? TextAlign.center : TextAlign.start,
          style: WaveType.pageTitle.copyWith(
            fontSize: 25,
            height: 1.12,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.5,
            color: Colors.white,
            shadows: _metadataShadow,
          ),
        ),
        const SizedBox(height: 5),
        WaveArtistLine(
          artist: track.artist,
          textAlign: alignCenter ? TextAlign.center : TextAlign.start,
          style: artistStyle.copyWith(
            color: Colors.white.withValues(alpha: 0.86),
          ),
          extraTrailingSpans: [
            if (showDistinctAlbum) ...[
              TextSpan(
                text: '  ·  ',
                style: artistStyle.copyWith(
                  color: Colors.white.withValues(alpha: 0.30),
                  fontWeight: FontWeight.w400,
                ),
              ),
              TextSpan(
                text: track.album,
                style: artistStyle.copyWith(
                  color: Colors.white.withValues(alpha: 0.56),
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ],
        ),
        if (quality != null) ...[
          const SizedBox(height: 10),
          _QualitySpecLine(quality: quality, centered: alignCenter),
        ],
        _UpNextRow(centered: alignCenter),
      ],
    );
  }
}

class _QualitySpecLine extends StatelessWidget {
  final ({String tier, String detail}) quality;
  final bool centered;

  const _QualitySpecLine({required this.quality, required this.centered});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: centered ? Alignment.center : Alignment.centerLeft,
      child: Row(
        key: const ValueKey('now-playing-quality'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            WaveIcons.equalizer,
            size: 11,
            color: waveAccent(context).withValues(alpha: 0.62),
          ),
          const SizedBox(width: 6),
          Text(
            quality.tier,
            style: WaveType.overline.copyWith(
              fontSize: 9.5,
              letterSpacing: 1.05,
              fontWeight: FontWeight.w700,
              color: Colors.white.withValues(alpha: 0.94),
              shadows: _metadataShadow,
            ),
          ),
          if (quality.detail.isNotEmpty) ...[
            const SizedBox(width: 7),
            Text(
              '·',
              style: WaveType.label.copyWith(
                fontSize: 10.5,
                color: Colors.white.withValues(alpha: 0.32),
                shadows: _metadataShadow,
              ),
            ),
            const SizedBox(width: 7),
            Text(
              quality.detail,
              style: WaveType.label.copyWith(
                fontSize: 10.5,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.1,
                color: Colors.white.withValues(alpha: 0.68),
                shadows: _metadataShadow,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _UpNextRow extends ConsumerStatefulWidget {
  final bool centered;

  const _UpNextRow({required this.centered});

  @override
  ConsumerState<_UpNextRow> createState() => _UpNextRowState();
}

class _UpNextRowState extends ConsumerState<_UpNextRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final queue = ref.watch(playbackServiceProvider.select((s) => s.queue));
    final index = ref.watch(
      playbackServiceProvider.select((s) => s.currentIndex),
    );

    final hasNext = index >= 0 && index + 1 < queue.length;
    if (!hasNext) return const SizedBox.shrink();

    final nextTrack = queue[index + 1];
    final nextStyle = WaveType.meta.copyWith(
      fontSize: 11.5,
      color: Colors.white.withValues(alpha: 0.62),
      shadows: _metadataShadow,
    );

    final nextLabel = Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: nextTrack.title,
            style: WaveType.trackTitle.copyWith(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: Colors.white.withValues(alpha: 0.92),
              shadows: _metadataShadow,
            ),
          ),
          TextSpan(
            text: '  ·  ',
            style: nextStyle.copyWith(
              color: Colors.white.withValues(alpha: 0.30),
            ),
          ),
          TextSpan(text: nextTrack.artist, style: nextStyle),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );

    final content = Row(
      mainAxisSize: widget.centered ? MainAxisSize.min : MainAxisSize.max,
      children: [
        Text(
          'UP NEXT',
          style: WaveType.overline.copyWith(
            fontSize: 8.5,
            letterSpacing: 1.2,
            fontWeight: FontWeight.w700,
            color: waveAccent(context).withValues(alpha: 0.82),
            shadows: _metadataShadow,
          ),
        ),
        const SizedBox(width: 10),
        if (widget.centered)
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 270),
            child: nextLabel,
          )
        else
          Expanded(child: nextLabel),
        const SizedBox(width: 8),
        AnimatedSlide(
          duration: WaveMotion.fast,
          curve: WaveMotion.standard,
          offset: _hovered ? const Offset(0.18, 0) : Offset.zero,
          child: Icon(
            FluentIcons.chevron_right,
            size: 11,
            color: _hovered
                ? waveAccent(context)
                : Colors.white.withValues(alpha: 0.42),
          ),
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: widget.centered
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 1,
            color: Colors.white.withValues(alpha: 0.16),
          ),
          const SizedBox(height: 4),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => ref.read(playbackServiceProvider.notifier).next(),
              child: AnimatedContainer(
                key: const ValueKey('now-playing-up-next'),
                duration: WaveMotion.fast,
                curve: WaveMotion.standard,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: _hovered ? 0.06 : 0.0),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: content,
              ),
            ),
          ),
        ],
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
