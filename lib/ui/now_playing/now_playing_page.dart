import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:fluent_ui/fluent_ui.dart' hide RepeatMode;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/window_lifecycle.dart';
import '../../core/artwork/animated_artwork_service.dart';
import 'immersive.dart';
import '../../core/artwork/animated_artwork_session.dart';
import '../../core/artwork/artwork_resolver.dart';
import '../../core/audio/stream_models.dart';
import '../../features/lyrics/karaoke_lyrics_view.dart';
import '../../features/player/playback_service.dart';
import '../../features/podcasts/podcast_repository.dart';
import '../components/ambient.dart';
import '../components/animated_artwork_video.dart';
import '../components/artist_line.dart';
import '../components/artwork.dart';
import '../components/image_aspect.dart';
import '../components/buttons.dart' show LWTooltip;
import '../components/states.dart';
import '../theme/fluent_theme.dart';
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
/// - Top Actions: Lyrics toggle, Visualizer toggle, Close button.
/// - Inactivity Auto-Hide: Fades controls and hides cursor after 3.5s of idle mouse.
class WaveNowPlayingPage extends ConsumerStatefulWidget {
  const WaveNowPlayingPage({super.key});

  @override
  ConsumerState<WaveNowPlayingPage> createState() => _WaveNowPlayingPageState();
}

class _WaveNowPlayingPageState extends ConsumerState<WaveNowPlayingPage> {
  bool _lyricsVisible = true;
  // Focus mode: lyrics only, artwork column collapsed, lyrics centered.
  bool _focusMode = false;
  bool _controlsIdle = false;
  Timer? _idleTimer;
  DateTime _lastHoverAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastArmAt = DateTime.fromMillisecondsSinceEpoch(0);
  String _preloadedKey = '';
  // Separate arming key for the motion-art lookup: it is gated on the
  // visualizer toggle (the only thing that renders a clip), so flipping
  // the toggle on must re-arm for the current track.
  String _prefetchedMotionKey = '';
  // Captured up front: `ref` is not safe to read while the element unmounts.
  late final StateController<bool> _idleMirror =
      ref.read(nowPlayingControlsIdleProvider.notifier);

  @override
  void initState() {
    super.initState();
    _resetIdleTimer();
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    // Not while the tree is finalizing: a hidden-dock state must not
    // outlive the page.
    final mirror = _idleMirror;
    Future.microtask(() => mirror.state = false);
    super.dispose();
  }

  void _resetIdleTimer() {
    _lastHoverAt = DateTime.now();
    if (_controlsIdle) {
      setState(() => _controlsIdle = false);
      _idleMirror.state = false;
      _armIdleTimer();
      return;
    }
    // Throttle per-pixel hover re-arms while visible: high-DPI mice poll
    // ~1000Hz and each event cancelled/armed a Timer. The timeout below
    // self-corrects against _lastHoverAt, so hide still lands exactly
    // 3.5s after the last movement. Showing from hidden stays instant.
    final now = DateTime.now();
    if (now.difference(_lastArmAt).inMilliseconds < 200 &&
        (_idleTimer?.isActive ?? false)) {
      return;
    }
    _armIdleTimer();
  }

  void _armIdleTimer() {
    _lastArmAt = DateTime.now();
    _idleTimer?.cancel();
    _idleTimer = Timer(const Duration(milliseconds: 3500), _onIdleTimeout);
  }

  void _onIdleTimeout() {
    if (!mounted) return;
    // A throttled hover may have landed after the last arm: re-arm for
    // the remainder instead of hiding early.
    final elapsed = DateTime.now().difference(_lastHoverAt).inMilliseconds;
    if (elapsed < 3500) {
      _idleTimer = Timer(
        Duration(milliseconds: 3500 - elapsed),
        _onIdleTimeout,
      );
      return;
    }
    setState(() => _controlsIdle = true);
    _idleMirror.state = true;
  }

  // Dark theme for the Apple Music stage, memoized on the accent so page
  // rebuilds don't hand FluentTheme a new data object each time.
  FluentThemeData? _stageTheme;
  Color? _stageAccent;

  /// Apple Music ambient: the page always renders on the dark stage with
  /// white text and controls, whatever the app theme (Pearl, Custom…), the
  /// way Apple Music's lyrics view does. WinUI keeps following the theme.
  @override
  Widget build(BuildContext context) {
    // Pointer activity on the immersive overlay dock keeps the stage awake.
    // Must live here: `_buildPage` runs inside a Builder on the Apple stage,
    // where `ref.listen` is not allowed.
    ref.listen<int>(nowPlayingActivityProvider, (_, _) => _resetIdleTimer());
    final apple = ref.watch(ambientStyleProvider) == AmbientStyle.apple;
    if (!apple) return _buildPage(context);
    final accent = waveAccent(context);
    if (_stageTheme == null || _stageAccent != accent) {
      _stageAccent = accent;
      _stageTheme = buildWaveFluentTheme(accent: accent, isLight: false);
    }
    return FluentTheme(
      data: _stageTheme!,
      child: Builder(builder: _buildPage),
    );
  }

  Widget _buildPage(BuildContext context) {
    final current = ref.watch(playbackServiceProvider.select((s) => s.current));

    final visualizerEnabled = ref.watch(visualizerEnabledProvider);

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
          if (ref.read(nowPlayingImmersiveProvider)) {
            ref.read(nowPlayingImmersiveProvider.notifier).state = false;
            return;
          }
          if (context.canPop()) {
            context.pop();
          } else {
            context.go('/home');
          }
        },
      },
      child: MouseRegion(
        cursor: _controlsIdle
            ? SystemMouseCursors.none
            : SystemMouseCursors.basic,
        onHover: (_) => _resetIdleTimer(),
        child: Stack(
          children: [
            // The stage belongs to the page. Without a background of its own
            // the black was borrowed from whatever sat behind the route, so
            // closing faded the ambient out over a backdrop that could not
            // fade with it — and then the backdrop vanished the instant the
            // route did. Painting it here keeps the whole screen, backdrop
            // included, inside the page's own transition.
            Positioned.fill(child: ColoredBox(color: waveBackground(context))),

            // Background Visualizer
            Positioned.fill(
              child: RepaintBoundary(
                child: _NowAmbient(artworkUrl: current.artworkUrl),
              ),
            ),

            // Main Layout Content
            AnimatedPositioned(
              duration: waveMotion(context, WaveMotion.normal),
              curve: Curves.easeOutCubic,
              left: 0,
              top: 0,
              bottom: 0,
              right: 0,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final isWide = constraints.maxWidth > 860;

                  // The body spans the whole page and the top action bar floats
                  // over it, so the lyrics toolbar can sit on the same row as the
                  // top bar instead of costing the lyrics a row of their own.
                  return Stack(
                    children: [
                      Positioned.fill(
                        child: isWide
                            ? _DesktopDualPane(
                                topInset: _kTopBarHeight,
                                track: current,
                                lyricsVisible: _lyricsVisible,
                                focusMode: _focusMode,
                              )
                            : Padding(
                                padding: const EdgeInsets.only(
                                  top: _kTopBarHeight,
                                ),
                                child: _NarrowCenteredPane(
                                  track: current,
                                  lyricsVisible: _lyricsVisible,
                                ),
                              ),
                      ),
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: // Top Actions Bar (Fadeable on idle)
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
                                lyricsVisible: _lyricsVisible,
                                focusMode: _focusMode,
                                visualizerEnabled: visualizerEnabled,
                                onToggleLyrics: () {
                                  _resetIdleTimer();
                                  setState(() {
                                    _lyricsVisible = !_lyricsVisible;
                                    if (!_lyricsVisible) _focusMode = false;
                                  });
                                },
                                onToggleFocus: () {
                                  _resetIdleTimer();
                                  setState(() {
                                    _focusMode = !_focusMode;
                                    if (_focusMode) _lyricsVisible = true;
                                  });
                                },
                                onToggleVisualizer: () {
                                  _resetIdleTimer();
                                  ref
                                      .read(visualizerEnabledProvider.notifier)
                                      .toggle();
                                },
                                onClose: () {
                                  // Edge-to-edge mode: the cross leaves it.
                                  if (ref.read(nowPlayingImmersiveProvider)) {
                                    ref
                                        .read(
                                          nowPlayingImmersiveProvider.notifier,
                                        )
                                        .state = false;
                                    return;
                                  }
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
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Height of the top action bar (also the lyrics toolbar's row).
const double _kTopBarHeight = 54;

class _TopActionsBar extends StatelessWidget {
  final bool lyricsVisible;
  final bool focusMode;
  final bool visualizerEnabled;
  final VoidCallback onToggleLyrics;
  final VoidCallback onToggleFocus;
  final VoidCallback onToggleVisualizer;
  final VoidCallback onClose;

  const _TopActionsBar({
    required this.lyricsVisible,
    required this.focusMode,
    required this.visualizerEnabled,
    required this.onToggleLyrics,
    required this.onToggleFocus,
    required this.onToggleVisualizer,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: _kTopBarHeight,
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
                  message: focusMode ? 'Exit focus mode' : 'Focus on lyrics',
                  child: _FsIconButton(
                    icon: focusMode
                        ? FluentIcons.mini_contract
                        : WaveIcons.expand,
                    active: focusMode,
                    onTap: onToggleFocus,
                  ),
                ),
                LWTooltip(
                  message: visualizerEnabled
                      ? 'Disable visualizer'
                      : 'Enable visualizer',
                  child: _FsIconButton(
                    icon: WaveIcons.visualizer,
                    active: visualizerEnabled,
                    onTap: onToggleVisualizer,
                  ),
                ),
                LWTooltip(
                  message: 'Close (Esc)',
                  child: _FsIconButton(icon: WaveIcons.close, onTap: onClose),
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
  /// Top action bar height the body now sits under (see the page Stack).
  final double topInset;
  final PlayableTrack track;
  final bool lyricsVisible;
  final bool focusMode;

  const _DesktopDualPane({
    required this.topInset,
    required this.track,
    required this.lyricsVisible,
    this.focusMode = false,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        // [maxHeight] is the old body height (under the top bar); the lyrics
        // column is [fullHeight] tall because it also fills the top bar row.
        final maxHeight = math.max(
          0.0,
          constraints.maxHeight - 24.0 - topInset,
        );
        final fullHeight = maxHeight + topInset;

        // Symmetrical desktop dual pane layout:
        // When lyrics are visible, media column and lyrics column have harmonious, balanced
        // widths, leaving identical horizontal margins (emptiness) on both sides.
        final colWidth = lyricsVisible
            ? math.min(maxWidth * 0.36, maxHeight * 0.48).clamp(340.0, 420.0)
            : math.min(maxWidth * 0.55, maxHeight * 0.52).clamp(360.0, 480.0);

        final gap = lyricsVisible && !focusMode
            ? (maxWidth * 0.04).clamp(40.0, 64.0)
            : 0.0;

        // Harmonized lyrics column width, balancing the visual weight of the left column
        final targetLyricsWidth = (colWidth * 1.35).clamp(460.0, 580.0);
        final maxAllowedLyricsWidth = math.max(
          320.0,
          maxWidth - colWidth - gap - 48.0,
        );
        final lyricsWidth = focusMode
            ? math.min(760.0, math.max(320.0, maxWidth - 48.0))
            : lyricsVisible
            ? math.min(targetLyricsWidth, maxAllowedLyricsWidth)
            : 0.0;

        // Keep the lyrics toolbar clear of the top bar's action group.
        final total = (focusMode ? 0.0 : colWidth) + gap + lyricsWidth;
        final lyricsRight = (maxWidth + total) / 2;
        final toolbarInset = math.max(
          0.0,
          math.min(
            lyricsRight - (maxWidth - 24 - 250),
            math.max(0.0, lyricsWidth - 300),
          ),
        );

        return Center(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 24),
            child: SizedBox(
              height: fullHeight,
              child: Row(
                mainAxisSize: MainAxisSize.max,
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Left Column (Media Player) — the metadata keeps its
                  // intrinsic height; artwork takes whatever remains.
                  Padding(
                    padding: EdgeInsets.only(top: topInset),
                    child: AnimatedContainer(
                      duration: waveMotion(
                        context,
                        const Duration(milliseconds: 500),
                      ),
                      curve: Curves.easeInOutCubic,
                      width: focusMode ? 0.0 : colWidth,
                      height: maxHeight,
                      // Children keep their full width while the column
                      // collapses (focus mode), so nothing overflows mid-anim.
                      // Clip is outset (except in focus mode, where the column
                      // collapses) so the cover's drop shadow isn't cut off at
                      // the column edges.
                      child: ClipRect(
                        clipper: _OutsetClipper(focusMode ? 0 : 56),
                        child: OverflowBox(
                          alignment: Alignment.centerLeft,
                          minWidth: colWidth,
                          maxWidth: colWidth,
                          child: ExcludeFocus(
                            excluding: focusMode,
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
                                          child: _HeroArtworkCard(
                                            track: track,
                                            size: artSize,
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                  const SizedBox(height: 16),

                                  // Track Info & Badges — crossfades on track change.
                                  _TrackSwap(
                                    child: _TrackMetadataSection(
                                      key: ValueKey(track.queueKey),
                                      track: track,
                                      alignCenter: !lyricsVisible,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
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
                    height: fullHeight,
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
                              height: fullHeight,
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
                                      fontSize: 36.0,
                                      isActive: lyricsVisible,
                                      toolbarRightInset: toolbarInset,
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

  const _NarrowCenteredPane({required this.track, required this.lyricsVisible});

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
                      child: _HeroArtworkCard(track: track, size: artSize),
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
              _TrackSwap(
                child: _TrackMetadataSection(
                  key: ValueKey(track.queueKey),
                  track: track,
                  alignCenter: true,
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

  String _podcastVid = '\u0000';
  bool _isPodcast = false;
  String _aspectUrl = '';
  double? _aspect;

  /// Podcast episodes are the only tracks with a saved progress row.
  bool _podcast(PlayableTrack t) {
    if (_podcastVid != t.videoId) {
      _podcastVid = t.videoId;
      try {
        _isPodcast =
            t.videoId.isNotEmpty &&
            ref
                .read(podcastRepositoryProvider)
                .progressFor([t.videoId])
                .containsKey(t.videoId);
      } catch (_) {
        _isPodcast = false;
      }
    }
    return _isPodcast;
  }

  @override
  Widget build(BuildContext context) {
    final ref = this.ref;
    final track = widget.track;
    final size = widget.size;
    final dark = waveIsDark(context);
    // Podcasts keep their native shape: 16:9 art stays 16:9, square art
    // falls through to the normal 1:1 cover below.
    if (track.artworkUrl.isNotEmpty && _podcast(track)) {
      if (_aspectUrl != track.artworkUrl) {
        _aspectUrl = track.artworkUrl;
        _aspect = ImageAspect.peek(track.artworkUrl);
        if (_aspect == null) {
          final url = track.artworkUrl;
          ImageAspect.resolve(url).then((a) {
            if (mounted && _aspectUrl == url) setState(() => _aspect = a);
          });
        }
      }
    }
    if (track.artworkUrl.isNotEmpty &&
        _podcast(track) &&
        (_aspect ?? ImageAspect.wide) > 1.2) {
      final w = size;
      final h = size * 9 / 16;
      return Center(
        child: Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: dark ? 0.62 : 0.34),
                blurRadius: 28,
                offset: const Offset(0, 14),
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: dark ? 0.38 : 0.18),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: CachedNetworkImage(
              imageUrl: track.artworkUrl,
              fit: BoxFit.cover,
              width: w,
              height: h,
              errorWidget: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
        ),
      );
    }
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
      radius: 12,
      label: track.title,
      title: track.title,
      artist: track.artist,
    );

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        // Kept shallow on purpose: large blurs over a full-window ambient
        // stage retain big GPU surfaces on Windows ANGLE.
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.62 : 0.34),
            blurRadius: 28,
            offset: const Offset(0, 14),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.38 : 0.18),
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
          borderRadius: BorderRadius.circular(12),
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
    final quality = stream == null ? null : _streamQualityParts(stream);

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

class _OutsetClipper extends CustomClipper<Rect> {
  final double outset;
  const _OutsetClipper(this.outset);

  @override
  Rect getClip(Size size) => (Offset.zero & size).inflate(outset);

  @override
  bool shouldReclip(covariant _OutsetClipper old) => old.outset != outset;
}

class _NowAmbient extends ConsumerWidget {
  final String artworkUrl;

  const _NowAmbient({required this.artworkUrl});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (artworkUrl.isEmpty) return const SizedBox.shrink();
    return WaveAmbientMesh(
      artworkUrl: artworkUrl,
      isFullBleed: true,
      cinematic: true,
      apple: ref.watch(ambientStyleProvider) == AmbientStyle.apple,
    );
  }
}
