import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:audio_video_progress_bar/audio_video_progress_bar.dart' as avp;

import '../../core/storage/prefs.dart';
import '../../core/audio/stream_models.dart';
import '../../features/downloads/download_manager.dart';
import '../../core/network/network_monitor.dart';
import '../../features/settings/theme_controller.dart';
import '../../features/library/playlists.dart';
import '../../features/player/playback_service.dart';
import '../../features/equalizer/equalizer_panel.dart';
import '../../features/audio_output/output_controller.dart';
import '../components/artwork.dart';
import '../components/ambient.dart' show artworkSeedProvider;
import '../navigation/destinations.dart';
import '../queue/queue_panel.dart';
import '../components/buttons.dart' show LWVolumeSlider, WaveButton;
import '../player_dock/player_dock.dart' show WaveTimeline;
import '../now_playing/immersive.dart' show nowPlayingOverlayRequestProvider;
import '../theme/haze.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';
import '../collections/playlist_dialogs.dart' show showWaveAddToPlaylist;

// Main destinations follow LastWave-Native's three-item floating dock.
const _nativeMainDestinations = <WaveDestination>[
  WaveDestination('/home', 'Home', WaveIcons.home),
  WaveDestination('/search', 'Search', WaveIcons.search),
  WaveDestination('/liked', 'Liked Songs', WaveIcons.liked),
  WaveDestination('/playlists', 'Playlists', WaveIcons.playlists),
  WaveDestination('/downloads', 'Downloads', WaveIcons.downloads),
];

const _phoneMoreDestinations = <WaveDestination>[
  WaveDestination('/home-layout', 'Edit Home', WaveIcons.edit),
  WaveDestination('/albums', 'Albums', WaveIcons.albums),
  WaveDestination('/artists', 'Artists', WaveIcons.artists),
  WaveDestination('/podcasts', 'Podcasts', WaveIcons.podcasts),
  WaveDestination('/mixes', 'Mix Lab', WaveIcons.mixes),
  WaveDestination('/history', 'Listening history', WaveIcons.history),
  WaveDestination('/friends', 'Friends', WaveIcons.friends),
  WaveDestination('/stats', 'Stats', WaveIcons.stats),
  WaveDestination('/settings', 'Settings', WaveIcons.settings),
];

/// Touch-first shell for iPhone and iPad. It reuses the existing routes,
/// page widgets, playback service, and settings state; only the app chrome
/// changes from the desktop WaveShell.
class WaveMobileShell extends ConsumerStatefulWidget {
  final String location;
  final Widget child;

  const WaveMobileShell({
    super.key,
    required this.location,
    required this.child,
  });

  @override
  ConsumerState<WaveMobileShell> createState() => _WaveMobileShellState();
}

class _WaveMobileShellState extends ConsumerState<WaveMobileShell> {
  bool _showMore = false;
  bool _showEqualizer = false;
  bool _showQueue = false;
  bool _offlineNoticeDismissed = false;
  String get _route => waveRoutePath(widget.location);

  @override
  void didUpdateWidget(WaveMobileShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.location != widget.location &&
        (_showMore || _showEqualizer || _showQueue)) {
      // Route changes can also come from deep links, browser callbacks, or
      // the Now Playing stage. Never leave a stale overlay covering the
      // destination page.
      _showMore = false;
      _showEqualizer = false;
      _showQueue = false;
    }
  }

  void _go(String path) {
    setState(() {
      _showMore = false;
      _showEqualizer = false;
      _showQueue = false;
    });
    final branch = _branchForPath(path);
    final child = widget.child;
    if (branch != null && child is StatefulNavigationShell) {
      child.goBranch(
        branch,
        initialLocation: child.currentIndex == branch,
      );
      return;
    }
    context.go(path);
  }

  int? _branchForPath(String path) {
    final clean = path.split('?').first;
    if (clean == '/home' || clean == '/home-layout') return 0;
    if (clean == '/stats') return 1;
    if (clean == '/search') return 2;
    if (clean == '/liked') return 3;
    if (clean == '/albums' || clean.startsWith('/album/')) return 4;
    if (clean == '/artists' || clean.startsWith('/artist/')) return 5;
    if (clean == '/playlists' ||
        clean.startsWith('/ytplaylist/') ||
        clean.startsWith('/spotifyplaylist/')) {
      return 6;
    }
    if (clean == '/podcasts' || clean.startsWith('/podcasts/')) return 7;
    if (clean == '/downloads') return 8;
    return null;
  }

  void _openNowPlaying() {
    if (!_route.startsWith('/now')) context.push('/now');
  }

  void _back() {
    if (_showEqualizer || _showQueue) {
      setState(() {
        _showEqualizer = false;
        _showQueue = false;
      });
      return;
    }
    setState(() => _showMore = false);
    if (context.canPop()) {
      context.pop();
    } else {
      _go('/home');
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String?>(nowPlayingOverlayRequestProvider, (previous, action) {
      if (action == null || !mounted) return;
      setState(() {
        _showQueue = action == 'queue';
        _showEqualizer = action == 'equalizer';
      });
      ref.read(nowPlayingOverlayRequestProvider.notifier).state = null;
    });
    ref.listen<bool>(networkMonitorProvider, (previous, online) {
      if (online && _offlineNoticeDismissed && mounted) {
        setState(() => _offlineNoticeDismissed = false);
      }
    });
    return LayoutBuilder(
      builder: (context, constraints) {
        // Window width matters: Split View and Stage Manager can be narrower
        // than the iPad's physical display.
        final viewSize = MediaQuery.sizeOf(context);
        final tablet = constraints.maxWidth >= 680 ||
            (viewSize.shortestSide >= 600 && constraints.maxWidth >= 520);
        final nowPlaying = _route.startsWith('/now');
        final online = ref.watch(networkMonitorProvider);
        final activePath = waveActivePath(widget.location);
        final theme = ref.watch(themeControllerProvider);
        final scaleSetting = ref.watch(
          prefsProvider.select((prefs) => prefs.interfaceScale),
        );
        final systemTextScale = MediaQuery.textScalerOf(context).scale(1.0);
        final interfaceScale = switch (scaleSetting) {
          'compact' => 0.92,
          'large' => 1.08,
          'standard' => 1.0,
          _ => tablet ? 1.0 : 0.97,
        };
        final material = switch (theme.hazeMaterial) {
          'haze' => WaveMaterialMode.haze,
          'solid' => WaveMaterialMode.solid,
          _ => WaveMaterialMode.automatic,
        };
        final intensity = switch (theme.hazeIntensity) {
          'low' => WaveHazeIntensity.low,
          'high' => WaveHazeIntensity.high,
          _ => WaveHazeIntensity.medium,
        };
        final moreDestinations = _phoneMoreDestinations;
        final moreActive = _showMore ||
            moreDestinations.any((d) =>
                activePath == d.path ||
                _route.startsWith('${d.path}/'));

        final systemMedia = MediaQuery.of(context);
        return MediaQuery(
          data: systemMedia.copyWith(
            textScaler: TextScaler.linear(systemTextScale * interfaceScale),
          ),
          child: WaveHazeScope(
            material: material,
            intensity: intensity,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _AmbientArtworkBackdrop(showArtworkGlow: !nowPlaying),
                SafeArea(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Padding(
                        padding: EdgeInsets.only(
                          top: nowPlaying
                              ? 0
                              : WaveMobileChrome.miniPlayerContentInset,
                          bottom: nowPlaying
                              ? WaveMobileChrome.transportContentInset
                              : WaveMobileChrome.navigationContentInset,
                        ),
                        child: ColoredBox(
                          color: waveBackground(context),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              widget.child,
                              if (_showMore && !nowPlaying)
                                Positioned.fill(
                                  child: ColoredBox(
                                    color: waveBackground(context),
                                    child: _MorePage(
                                      destinations: moreDestinations,
                                      onGo: _go,
                                      onBack: () =>
                                          setState(() => _showMore = false),
                                    ),
                                  ),
                                ),
                              if (_showEqualizer && nowPlaying)
                                Positioned.fill(
                                  child: WaveEqualizerPanel(
                                    embedded: true,
                                    onClose: _back,
                                  ),
                                ),
                              if (_showQueue && nowPlaying)
                                Positioned.fill(
                                  child: ColoredBox(
                                    color: waveBackground(context),
                                    child: Column(
                                      children: [
                                        _MobileOverlayHeader(
                                          title: 'Queue',
                                          onClose: _back,
                                        ),
                                        Expanded(
                                          child: WaveQueuePanel(
                                            onClose: _back,
                                            embedded: true,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              if (!online && !_offlineNoticeDismissed)
                                Positioned.fill(
                                  child: ColoredBox(
                                    color: Colors.black.withValues(alpha: 0.38),
                                    child: Center(
                                      child: Container(
                                        constraints: const BoxConstraints(
                                          maxWidth: 360,
                                        ),
                                        margin: const EdgeInsets.all(24),
                                        padding: const EdgeInsets.all(22),
                                        decoration: BoxDecoration(
                                          color: waveSurfaceRaised(context),
                                          borderRadius:
                                              WaveRadius.floatingRadius,
                                          border: Border.all(
                                            color: waveDivider(context),
                                          ),
                                          boxShadow: WaveElevation.flyout(
                                            waveIsDark(context),
                                          ),
                                        ),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              "You're offline",
                                              textAlign: TextAlign.center,
                                              style: WaveType.sectionTitle,
                                            ),
                                            const SizedBox(height: 8),
                                            Text(
                                              'Check your internet connection. '
                                              'Some LastWave features need to be online.',
                                              textAlign: TextAlign.center,
                                              style: WaveType.meta.copyWith(
                                                color:
                                                    waveTextSecondary(context),
                                              ),
                                            ),
                                            const SizedBox(height: 16),
                                            WaveButton(
                                              onPressed: () => setState(
                                                () => _offlineNoticeDismissed =
                                                    true,
                                              ),
                                              child: const Text('Dismiss'),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      if (!nowPlaying)
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          height: WaveMobileChrome.miniPlayerContentInset,
                          child: _MobileMiniPlayer(
                            onOpen: _openNowPlaying,
                          ),
                        ),
                      if (nowPlaying)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: WaveMobileChrome.transportBottomInset,
                          child: const _MobileTransportDock(),
                        ),
                      if (!nowPlaying)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: _PhoneNavigation(
                            activePath: activePath,
                            moreActive: moreActive,
                            showMore: _showMore,
                            onGo: _go,
                            onMore: () =>
                                setState(() => _showMore = !_showMore),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Shared neutral canvas with a restrained, cached artwork glow.
///
/// The previous full-window image blur let bright album covers wash through
/// every route and the navigation chrome. Keep artwork atmosphere subtle and
/// keep the actual frosted blur bounded to the floating controls.
class _AmbientArtworkBackdrop extends ConsumerWidget {
  final bool showArtworkGlow;

  const _AmbientArtworkBackdrop({this.showArtworkGlow = true});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final base = waveBackground(context);
    final artworkUrl = ref.watch(
      playbackServiceProvider.select(
        (snapshot) => snapshot.current?.artworkUrl ?? '',
      ),
    );
    final tint = showArtworkGlow && artworkUrl.isNotEmpty
        ? ref.watch(artworkSeedProvider(artworkUrl)).valueOrNull
        : null;
    final glow = tint == null
        ? base
        : Color.lerp(
            base,
            tint,
            waveIsDark(context) ? 0.10 : 0.06,
          )!;

    return Positioned.fill(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: base,
          gradient: tint == null
              ? null
              : RadialGradient(
                  center: const Alignment(0, -0.85),
                  radius: 1.3,
                  colors: [glow, base],
                  stops: const [0, 1],
                ),
        ),
      ),
    );
  }
}

class _MobileOverlayHeader extends StatelessWidget {
  final String title;
  final VoidCallback onClose;

  const _MobileOverlayHeader({
    required this.title,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) => Container(
        height: 54,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: waveSurface(context),
          border: Border(bottom: BorderSide(color: waveDivider(context))),
        ),
        child: Row(
          children: [
            _TouchIconButton(
              icon: WaveIcons.back,
              tooltip: 'Back to Now Playing',
              onPressed: onClose,
            ),
            const SizedBox(width: 8),
            Text(title, style: WaveType.trackTitle),
          ],
        ),
      );
}

/// Floating five-shortcut dock adapted from LastWave-Native's
/// MainShell/FloatingNavBar, translated from Compose to Flutter.
class _PhoneNavigation extends StatelessWidget {
  final String activePath;
  final bool moreActive;
  final bool showMore;
  final void Function(String) onGo;
  final VoidCallback onMore;

  const _PhoneNavigation({
    required this.activePath,
    required this.moreActive,
    required this.showMore,
    required this.onGo,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 480;
    String? selectedPath;
    if (!moreActive) {
      for (final destination in _nativeMainDestinations) {
        if (activePath == destination.path ||
            activePath.startsWith('${destination.path}/')) {
          selectedPath = destination.path;
          break;
        }
      }
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(
        compact
            ? WaveMobileChrome.navigationSideInsetCompact
            : WaveMobileChrome.navigationSideInsetRegular,
        WaveMobileChrome.navigationTopGap,
        compact
            ? WaveMobileChrome.navigationSideInsetCompact
            : WaveMobileChrome.navigationSideInsetRegular,
        WaveMobileChrome.navigationBottomInset,
      ),
      child: Center(
        child: WaveHaze(
          level: LwHazeLevel.l2,
          base: waveSurfaceRaised(context),
          borderRadius: WaveRadius.floatingRadius,
          border: Border.all(color: waveDivider(context)),
          shadow: WaveElevation.lift(waveIsDark(context)),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 5 : 7,
              vertical: 6,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final destination in _nativeMainDestinations)
                  _NativeFloatingNavItem(
                    destination: destination,
                    selected: selectedPath == destination.path,
                    compact: compact,
                    onTap: () => onGo(destination.path),
                  ),
                SizedBox(width: compact ? 2 : 4),
                Tooltip(
                  message: 'More',
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onMore,
                    child: SizedBox(
                      width: compact
                          ? WaveMobileChrome.navigationCompactItemExtent
                          : WaveMobileChrome.navigationRegularItemExtent,
                      height: compact
                          ? WaveMobileChrome.navigationCompactItemExtent
                          : WaveMobileChrome.navigationRegularItemExtent,
                      child: Icon(
                        showMore ? WaveIcons.close : WaveIcons.more,
                        size: 23,
                        color: moreActive
                            ? waveAccent(context)
                            : waveTextSecondary(context),
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

class _NativeFloatingNavItem extends StatelessWidget {
  final WaveDestination destination;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;

  const _NativeFloatingNavItem({
    required this.destination,
    required this.selected,
    required this.compact,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final contentColor = selected
        ? waveTextPrimary(context)
        : waveTextSecondary(context);

    return Tooltip(
      message: destination.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        height: compact ? 44 : 48,
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 7 : selected ? 17 : 13,
        ),
        decoration: BoxDecoration(
          color: selected
              ? waveAccent(context).withValues(alpha: 0.16)
              : Colors.transparent,
          borderRadius: WaveRadius.controlsRadius,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(destination.icon, size: 23, color: contentColor),
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              alignment: Alignment.centerLeft,
              child: selected && !compact
                  ? Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text(
                        destination.label,
                        maxLines: 1,
                        softWrap: false,
                        style: WaveType.label.copyWith(
                          color: contentColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    )
                  : const SizedBox(width: 0, height: 0),
            ),
          ],
        ),
      ),
      ),
    );
  }
}

class _MobileTransportDock extends ConsumerWidget {
  const _MobileTransportDock();

  String _time(Duration value) {
    final minutes = value.inMinutes;
    final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(
      playbackServiceProvider.select((state) => (
        isPlaying: state.isPlaying,
        position: state.position,
        buffered: state.buffered,
        duration: state.duration,
        volume: state.volume,
        shuffleEnabled: state.shuffleEnabled,
        repeatMode: state.repeatMode,
      )),
    );
    final playback = ref.read(playbackServiceProvider.notifier);
    final output = ref.read(audioOutputProvider.notifier);
    final wavySeekbar = ref.watch(prefsProvider.select((prefs) => prefs.wavySeekbar));
    final duration = snapshot.duration;
    final hasDuration = duration > Duration.zero;
    final volume = snapshot.volume.clamp(0.0, 1.0).toDouble();

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: WaveHaze(
        level: LwHazeLevel.l2,
        base: waveSurfaceRaised(context),
        borderRadius: WaveRadius.floatingRadius,
        border: Border.all(color: waveDivider(context)),
        shadow: WaveElevation.lift(waveIsDark(context)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 38,
                    child: Text(hasDuration ? _time(snapshot.position) : '--:--',
                      style: WaveType.meta.copyWith(fontSize: 10)),
                  ),
                  Expanded(
                    child: wavySeekbar
                        ? WaveTimeline(
                            progress: snapshot.position,
                            buffered: snapshot.buffered,
                            total: duration,
                            showThumb: hasDuration,
                            onSeek: hasDuration ? playback.seek : null,
                            baseColor: waveTextSecondary(context).withValues(alpha: 0.12),
                            bufferedColor: waveTextSecondary(context).withValues(alpha: 0.18),
                            progressColor: waveTextPrimary(context),
                            thumbColor: waveTextPrimary(context),
                            thumbGlowColor: waveAccent(context).withValues(alpha: 0.25),
                          )
                        : avp.ProgressBar(
                            progress: snapshot.position,
                            buffered: snapshot.buffered,
                            total: hasDuration ? duration : const Duration(seconds: 1),
                            onSeek: hasDuration ? playback.seek : null,
                            barHeight: 3,
                            thumbRadius: hasDuration ? 5 : 0,
                            thumbColor: waveTextPrimary(context),
                            progressBarColor: waveTextPrimary(context),
                            bufferedBarColor: waveTextSecondary(context).withValues(alpha: 0.22),
                            baseBarColor: waveTextSecondary(context).withValues(alpha: 0.12),
                            timeLabelLocation: avp.TimeLabelLocation.none,
                          ),
                  ),
                  SizedBox(
                    width: 38,
                    child: Text(hasDuration ? _time(duration) : '--:--',
                      textAlign: TextAlign.end,
                      style: WaveType.meta.copyWith(fontSize: 10)),
                  ),
                ],
              ),
              const SizedBox(height: 7),
              LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 560;
                  final iconWidth = compact ? 32.0 : 44.0;
                  final gap = compact ? 1.0 : 9.0;
                  final sliderWidth = compact ? 54.0 : 104.0;
                  return Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _TouchIconButton(icon: WaveIcons.shuffle, tooltip: 'Shuffle',
                        selected: snapshot.shuffleEnabled, width: iconWidth,
                        onPressed: playback.toggleShuffle),
                      SizedBox(width: gap),
                      _TouchIconButton(icon: WaveIcons.previous, tooltip: 'Previous track',
                        width: iconWidth, onPressed: playback.previous),
                      SizedBox(width: gap),
                      Container(
                        width: compact ? 42 : 48,
                        height: compact ? 42 : 48,
                        decoration: BoxDecoration(
                          color: waveTextPrimary(context), shape: BoxShape.circle),
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: playback.toggle,
                          child: Icon(snapshot.isPlaying ? WaveIcons.pause : WaveIcons.play,
                            color: waveBackground(context), size: 22),
                        ),
                      ),
                      SizedBox(width: gap),
                      _TouchIconButton(icon: WaveIcons.next, tooltip: 'Next track',
                        width: iconWidth, onPressed: playback.next),
                      SizedBox(width: gap),
                      _TouchIconButton(
                        icon: snapshot.repeatMode.name == 'one' ? WaveIcons.repeatOne : WaveIcons.repeat,
                        tooltip: 'Repeat mode',
                        selected: snapshot.repeatMode.name != 'off',
                        width: iconWidth,
                        onPressed: playback.cycleRepeat),
                      SizedBox(width: compact ? 5 : 18),
                      _TouchIconButton(
                        icon: volume <= 0 ? WaveIcons.volumeMute : WaveIcons.volume,
                        tooltip: volume <= 0 ? 'Unmute' : 'Mute volume',
                        width: compact ? 30 : 38,
                        onPressed: output.toggleMute),
                      SizedBox(
                        width: sliderWidth,
                        child: LWVolumeSlider(value: volume, width: sliderWidth,
                          semanticLabel: 'Playback volume', onChanged: output.setVolume),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _mobileStreamDetails(ResolvedStream? stream) {
  if (stream == null) return '';
  final badge = stream.qualityBadge.trim();
  final codec = stream.audioCodec.trim();
  final badgeUpper = badge.toUpperCase();
  final codecUpper = codec.toUpperCase();
  String? codecDetail;
  if (codec.isNotEmpty && codecUpper != badgeUpper) {
    if (badgeUpper.isNotEmpty && codecUpper.contains(badgeUpper)) {
      final remainder = codec
          .replaceFirst(RegExp(RegExp.escape(badge), caseSensitive: false), '')
          .replaceFirst(RegExp(r'^[\s·\-]+'), '')
          .trim();
      if (remainder.isNotEmpty) codecDetail = remainder;
    } else if (badgeUpper.isEmpty || !badgeUpper.contains(codecUpper)) {
      codecDetail = codec;
    }
  }
  return [
    if (badge.isNotEmpty) badge,
    ?codecDetail,
    if (stream.bitrateKbps > 0) '${stream.bitrateKbps} kbps',
  ].join(' · ');
}

const double _mobileMiniPlayerCardHeight = WaveMobileChrome.miniPlayerHeight;
const double _mobileMiniPlayerTopMargin = WaveMobileChrome.miniPlayerTopInset;
const double _mobileMiniPlayerBottomMargin =
    WaveMobileChrome.miniPlayerBottomGap;

/// Mini-player proportions and single-card hierarchy adapted from
/// LastWave-Native's ui/player/MiniPlayer.kt, translated to Flutter.
class _MobileMiniPlayer extends ConsumerWidget {
  final VoidCallback onOpen;

  const _MobileMiniPlayer({required this.onOpen});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(
      playbackServiceProvider.select((state) => (
        current: state.current,
        isPlaying: state.isPlaying,
        isBuffering: state.isBuffering,
        position: state.position,
        buffered: state.buffered,
        duration: state.duration,
        stream: state.stream,
      )),
    );
    final playback = ref.read(playbackServiceProvider.notifier);
    final wavySeekbar =
        ref.watch(prefsProvider.select((prefs) => prefs.wavySeekbar));
    final playlists = ref.watch(playlistRepositoryProvider);
    final track = player.current;
    // Keep secondary track actions on tablet-sized layouts only.
    final showLibraryActions = MediaQuery.sizeOf(context).width >= 600;
    final artworkTint = ref
        .watch(artworkSeedProvider(track?.artworkUrl ?? ''))
        .valueOrNull;
    final trackKey = track == null
        ? ''
        : '${track.title.toLowerCase()}|${track.artist.toLowerCase()}';
    final isLiked = track != null && playlists.any((playlist) =>
        playlist.isLikedSongs &&
        playlist.tracks.any((saved) =>
            '${saved.name.toLowerCase()}|${saved.artist.toLowerCase()}' ==
            trackKey));
    final stream = player.stream;
    final streamDetails = _mobileStreamDetails(stream);
    final durationMs = player.duration.inMilliseconds;
    final progressRatio = durationMs > 0
        ? (player.position.inMilliseconds / durationMs)
            .clamp(0.0, 1.0)
            .toDouble()
        : 0.0;

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: WaveMobileChrome.miniPlayerMaxWidth,
        ),
        child: Container(
      height: _mobileMiniPlayerCardHeight,
      margin: const EdgeInsets.fromLTRB(
        14,
        _mobileMiniPlayerTopMargin,
        14,
        _mobileMiniPlayerBottomMargin,
      ),
      child: WaveHaze(
        level: LwHazeLevel.l2,
        base: waveSurfaceRaised(context),
        artworkTint: artworkTint,
        borderRadius: WaveRadius.heroRadius,
        border: Border.all(color: waveDivider(context)),
        shadow: [
          BoxShadow(
            color: waveTextPrimary(context).withValues(alpha: 0.035),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
        child: Padding(
          padding: const EdgeInsets.fromLTRB(11, 5, 11, 4),
          child: Column(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: track == null ? null : onOpen,
              child: Row(
                children: [
                  if (track != null)
                    WaveArtwork(
                      url: track.artworkUrl,
                      videoId: track.videoId,
                      size: 52,
                      radius: 14,
                      label: track.title,
                      title: track.title,
                      artist: track.artist,
                    )
                  else
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: waveSurface(context),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Icon(WaveIcons.music, size: 20),
                    ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _WaveAutoScrollText(
                          text: track?.title ?? 'Nothing playing',
                          style: WaveType.trackTitle,
                        ),
                        _WaveAutoScrollText(
                          text: track?.artist ?? 'Choose music from your library',
                          style: WaveType.meta.copyWith(
                            color: waveTextSecondary(context),
                          ),
                        ),
                        if (streamDetails.isNotEmpty)
                          _WaveAutoScrollText(
                            text: streamDetails,
                            style: WaveType.meta.copyWith(
                              fontSize: 10,
                              letterSpacing: 0.15,
                              color: waveTextSecondary(context).withValues(alpha: 0.82),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (showLibraryActions) ...[
                    _MobileDownloadButton(track: track, width: 36),
                    _TouchIconButton(
                      icon: isLiked ? FluentIcons.heart_fill : FluentIcons.heart,
                      tooltip: isLiked ? 'Remove from Liked Songs' : 'Like song',
                      width: 36,
                      onPressed: track == null
                          ? null
                          : () async {
                              final repository =
                                  ref.read(playlistRepositoryProvider.notifier);
                              if (isLiked) {
                                final liked = ref
                                    .read(playlistRepositoryProvider)
                                    .where((p) => p.isLikedSongs)
                                    .toList();
                                if (liked.isNotEmpty) {
                                  await repository.removeTrack(
                                    liked.first.id,
                                    trackKey,
                                  );
                                }
                              } else {
                                final liked = await repository.ensureLikedSongs();
                                await repository.addTrack(
                                  liked.id,
                                  StoredTrack.fromPlayable(track),
                                );
                              }
                            },
                    ),
                    _TouchIconButton(
                      icon: FluentIcons.add,
                      tooltip: 'Add to playlist',
                      width: 36,
                      onPressed: track == null
                          ? null
                          : () => showWaveAddToPlaylist(
                                context,
                                ref,
                                StoredTrack.fromPlayable(track),
                              ),
                    ),
                  ],
                  _TouchIconButton(
                    icon: WaveIcons.previous,
                    tooltip: 'Previous track',
                    width: 36,
                    onPressed: track == null ? null : playback.previous,
                  ),
                  _TouchIconButton(
                    icon: player.isBuffering
                        ? WaveIcons.music
                        : player.isPlaying
                            ? WaveIcons.pause
                            : WaveIcons.play,
                    tooltip: player.isPlaying ? 'Pause' : 'Play',
                    onPressed: track == null ? null : playback.toggle,
                    width: 36,
                  ),
                  _TouchIconButton(
                    icon: WaveIcons.next,
                    tooltip: 'Next track',
                    onPressed: track == null ? null : playback.next,
                    width: 36,
                  ),
                ],
              ),
            ),
          ),
          if (wavySeekbar)
            WaveTimeline(
              progress: player.position,
              buffered: player.buffered,
              total: player.duration,
              showThumb: false,
              onSeek: null,
              baseColor: waveTextSecondary(context).withValues(alpha: 0.12),
              bufferedColor: waveTextSecondary(context).withValues(alpha: 0.18),
              progressColor: waveTextPrimary(context),
              thumbColor: waveTextPrimary(context),
              thumbGlowColor: waveAccent(context).withValues(alpha: 0.25),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Container(
                height: 2,
                decoration: BoxDecoration(
                  color: waveTextSecondary(context).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(2),
                ),
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: progressRatio,
                  child: Container(
                    decoration: BoxDecoration(
                      color: waveTextPrimary(context),
                      borderRadius: BorderRadius.circular(2),
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
      ),
    );
  }
}

class _TouchIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;
  final double width;

  const _TouchIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
    this.width = 48,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: SizedBox(
          width: width,
          height: 48,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: selected
                  ? waveAccent(context).withValues(alpha: 0.14)
                  : Colors.transparent,
              borderRadius: WaveRadius.controlsRadius,
            ),
            child: Icon(
              icon,
              size: 21,
              color: onPressed == null
                  ? waveTextSecondary(context).withValues(alpha: 0.35)
                  : selected
                      ? waveTextPrimary(context)
                      : waveTextSecondary(context),
            ),
          ),
        ),
      ),
    );
  }
}

class _MobileDownloadButton extends ConsumerWidget {
  final PlayableTrack? track;
  final double width;

  const _MobileDownloadButton({
    required this.track,
    required this.width,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = track;
    if (current == null) {
      return _TouchIconButton(
        icon: FluentIcons.download,
        tooltip: 'Download',
        width: width,
        onPressed: null,
      );
    }
    final entries = ref.watch(downloadManagerProvider);
    final key = DownloadManager.keyOf(current.title, current.artist);
    DownloadEntry? entry;
    for (final candidate in entries) {
      if (candidate.key == key) {
        entry = candidate;
        break;
      }
    }
    final done = entry?.status == DownloadStatus.done;
    final downloading = entry?.status == DownloadStatus.downloading ||
        entry?.status == DownloadStatus.queued;
    final manager = ref.read(downloadManagerProvider.notifier);
    return _TouchIconButton(
      icon: done ? FluentIcons.check_mark : FluentIcons.download,
      tooltip: done
          ? 'Downloaded'
          : downloading
              ? 'Downloading…'
              : entry?.status == DownloadStatus.error
                  ? 'Retry download'
                  : 'Download',
      selected: done,
      width: width,
      onPressed: done || downloading
          ? null
          : () => manager.downloadTrack(
                title: current.title,
                artist: current.artist,
                album: current.album,
                artworkUrl: current.artworkUrl,
                videoId: current.videoId,
              ),
    );
  }
}

class _WaveAutoScrollText extends StatefulWidget {
  final String text;
  final TextStyle style;

  const _WaveAutoScrollText({required this.text, required this.style});

  @override
  State<_WaveAutoScrollText> createState() => _WaveAutoScrollTextState();
}

class _WaveAutoScrollTextState extends State<_WaveAutoScrollText> {
  final ScrollController _controller = ScrollController();
  bool _overflow = false;
  bool _loopRunning = false;

  @override
  void didUpdateWidget(_WaveAutoScrollText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _controller.hasClients) _controller.jumpTo(0);
      });
    }
  }

  Future<void> _runScrollLoop() async {
    if (_loopRunning) return;
    _loopRunning = true;
    while (mounted && _overflow) {
      await Future<void>.delayed(const Duration(milliseconds: 650));
      if (!mounted || !_overflow || !_controller.hasClients) break;
      final end = _controller.position.maxScrollExtent;
      if (end <= 1) break;
      await _controller.animateTo(
        end,
        duration: Duration(milliseconds: (end * 22).round().clamp(900, 3200).toInt()),
        curve: Curves.linear,
      );
      await Future<void>.delayed(const Duration(milliseconds: 750));
      if (!mounted || !_overflow || !_controller.hasClients) break;
      await _controller.animateTo(
        0,
        duration: const Duration(milliseconds: 650),
        curve: Curves.easeOut,
      );
    }
    _loopRunning = false;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final painter = TextPainter(
            text: TextSpan(text: widget.text, style: widget.style),
            maxLines: 1,
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
          )..layout();
          final overflows = painter.width > constraints.maxWidth + 1;
          if (_overflow != overflows) {
            _overflow = overflows;
            if (_overflow) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _runScrollLoop();
              });
            } else {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && _controller.hasClients) _controller.jumpTo(0);
              });
            }
          }
          if (!overflows) {
            return Text(widget.text, maxLines: 1, style: widget.style);
          }
          return ClipRect(
            child: SingleChildScrollView(
              controller: _controller,
              scrollDirection: Axis.horizontal,
              physics: const NeverScrollableScrollPhysics(),
              child: Text(widget.text, maxLines: 1, softWrap: false, style: widget.style),
            ),
          );
        },
      );
}

class _MorePage extends StatelessWidget {
  final List<WaveDestination> destinations;
  final void Function(String) onGo;
  final VoidCallback onBack;

  const _MorePage({
    required this.destinations,
    required this.onGo,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          height: 54,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: waveSurface(context),
            border: Border(bottom: BorderSide(color: waveDivider(context))),
          ),
          child: Row(
            children: [
              _TouchIconButton(
                icon: WaveIcons.back,
                tooltip: 'Back',
                onPressed: onBack,
              ),
              const SizedBox(width: 8),
              Text('More', style: WaveType.trackTitle),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
            children: [
              for (final destination in destinations)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => onGo(destination.path),
                    child: Container(
                      height: 60,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      decoration: BoxDecoration(
                        color: waveSurface(context),
                        borderRadius: WaveRadius.floatingRadius,
                        border: Border.all(color: waveDivider(context)),
                      ),
                      child: Row(
                        children: [
                          Icon(destination.icon, size: 22),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Text(destination.label, style: WaveType.trackTitle),
                          ),
                          Icon(
                            WaveIcons.chevronRight,
                            size: 16,
                            color: waveTextSecondary(context),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
