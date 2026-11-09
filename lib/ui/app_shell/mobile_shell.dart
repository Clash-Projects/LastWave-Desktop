import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:audio_video_progress_bar/audio_video_progress_bar.dart' as avp;

import '../../core/storage/prefs.dart';
import '../../core/network/network_monitor.dart';
import '../../features/settings/theme_controller.dart';
import '../../features/library/playlists.dart';
import '../../features/player/playback_service.dart';
import '../../features/equalizer/equalizer_panel.dart';
import '../../features/audio_output/output_controller.dart';
import '../components/artwork.dart';
import '../navigation/destinations.dart';
import '../queue/queue_panel.dart';
import '../components/buttons.dart' show LWVolumeSlider, WaveButton;
import '../player_dock/player_dock.dart' show WaveTimeline;
import '../theme/haze.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';
import '../collections/playlist_dialogs.dart' show showWaveAddToPlaylist;

const _phoneDestinations = <WaveDestination>[
  WaveDestination('/home', 'Home', WaveIcons.home),
  WaveDestination('/search', 'Search', WaveIcons.search),
  WaveDestination('/liked', 'Liked', WaveIcons.liked),
  WaveDestination('/playlists', 'Playlists', WaveIcons.playlists),
  WaveDestination('/settings', 'Settings', WaveIcons.settings),
];

const _phoneMoreDestinations = <WaveDestination>[
  WaveDestination('/albums', 'Albums', WaveIcons.albums),
  WaveDestination('/artists', 'Artists', WaveIcons.artists),
  WaveDestination('/downloads', 'Downloads', WaveIcons.downloads),
  WaveDestination('/stats', 'Listening statistics', WaveIcons.stats),
  WaveDestination('/podcasts', 'Podcasts', WaveIcons.podcasts),
  WaveDestination('/mixes', 'Mix Lab', WaveIcons.mixes),
  WaveDestination('/history', 'Listening history', WaveIcons.history),
  WaveDestination('/friends', 'Friends', WaveIcons.friends),
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
  Offset? _touchStart;

  String get _route => waveRoutePath(widget.location);

  void _handleTouchStart(PointerDownEvent event) {
    if (event.kind == PointerDeviceKind.touch) _touchStart = event.position;
  }

  void _handleTouchEnd(PointerUpEvent event) {
    final start = _touchStart;
    _touchStart = null;
    if (start == null || event.kind != PointerDeviceKind.touch) return;
    final delta = event.position - start;
    if (delta.dx.abs() < 140 || delta.dy.abs() > 64) return;
    final focusedContext = FocusManager.instance.primaryFocus?.context;
    if (focusedContext?.findAncestorWidgetOfExactType<EditableText>() != null) {
      return;
    }
    final playback = ref.read(playbackServiceProvider.notifier);
    if (delta.dx < 0) {
      playback.next();
    } else {
      playback.previous();
    }
  }

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
            child: ColoredBox(
              color: waveBackground(context),
              child: SafeArea(
                child: Listener(
                  onPointerDown: _handleTouchStart,
                  onPointerUp: _handleTouchEnd,
                  onPointerCancel: (_) => _touchStart = null,
                  child: Column(
                  children: [
                    if (!nowPlaying)
                      _MobileMiniPlayer(onOpen: _openNowPlaying),
                    if (!tablet && !nowPlaying)
                      _MobileToolbar(
                        tabletLayout: tablet,
                        showBack: _route != '/home' && _route != '/search',
                        onBack: _back,
                        onSearch: () => _go('/search'),
                        onMore: () => setState(() => _showMore = !_showMore),
                      ),
                    if (tablet && moreActive && !_showMore && !nowPlaying)
                      _MobileToolbar(
                        tabletLayout: true,
                        showBack: true,
                        onBack: _back,
                        onSearch: () => _go('/search'),
                        onMore: () => setState(() => _showMore = true),
                      ),
                    Expanded(
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
                                  onBack: () => setState(() => _showMore = false),
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
                                    constraints:
                                        const BoxConstraints(maxWidth: 360),
                                    margin: const EdgeInsets.all(24),
                                    padding: const EdgeInsets.all(22),
                                    decoration: BoxDecoration(
                                      color: waveSurfaceRaised(context),
                                      borderRadius: BorderRadius.circular(22),
                                      border: Border.all(
                                        color: waveDivider(context),
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withValues(
                                            alpha: 0.22,
                                          ),
                                          blurRadius: 28,
                                          offset: const Offset(0, 12),
                                        ),
                                      ],
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
                                            color: waveTextSecondary(context),
                                          ),
                                        ),
                                        const SizedBox(height: 16),
                                        WaveButton(
                                          onPressed: () => setState(
                                            () => _offlineNoticeDismissed = true,
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
                    if (nowPlaying)
                      _MobileTransportDock(
                        onQueue: () => setState(() {
                          _showQueue = !_showQueue;
                          _showEqualizer = false;
                        }),
                        onEqualizer: () => setState(() {
                          _showEqualizer = !_showEqualizer;
                          _showQueue = false;
                        }),
                        queueActive: _showQueue,
                        equalizerActive: _showEqualizer,
                      ),
                    if (!nowPlaying)
                      _PhoneNavigation(
                        activePath: activePath,
                        moreActive: moreActive,
                        onGo: _go,
                        onMore: () =>
                            setState(() => _showMore = !_showMore),
                      ),
                  ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MobileToolbar extends StatelessWidget {
  final bool tabletLayout;
  final bool showBack;
  final VoidCallback onBack;
  final VoidCallback onSearch;
  final VoidCallback onMore;

  const _MobileToolbar({
    required this.tabletLayout,
    required this.showBack,
    required this.onBack,
    required this.onSearch,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: waveBackground(context),
        border: Border(bottom: BorderSide(color: waveDivider(context))),
      ),
      child: Row(
        children: [
          if (showBack)
            _TouchIconButton(
              icon: WaveIcons.back,
              tooltip: 'Back',
              onPressed: onBack,
            ),
          const Spacer(),
          if (!tabletLayout)
            _TouchIconButton(
              icon: WaveIcons.search,
              tooltip: 'Search',
              onPressed: onSearch,
            ),
          _TouchIconButton(
            icon: WaveIcons.more,
            tooltip: 'More',
            onPressed: onMore,
          ),
        ],
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

class _PhoneNavigation extends StatelessWidget {
  final String activePath;
  final bool moreActive;
  final void Function(String) onGo;
  final VoidCallback onMore;

  const _PhoneNavigation({
    required this.activePath,
    required this.moreActive,
    required this.onGo,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 74,
      margin: const EdgeInsets.fromLTRB(14, 5, 14, 8),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: waveSurface(context),
        borderRadius: BorderRadius.circular(25),
        border: Border.all(color: waveDivider(context)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: waveIsDark(context) ? 0.24 : 0.08),
            blurRadius: 22,
            offset: const Offset(0, 7),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(19),
        child: Row(
        children: [
          for (final destination in _phoneDestinations)
            Expanded(
              child: _PhoneTab(
                destination: destination,
                selected: !moreActive &&
                    (activePath == destination.path ||
                        activePath.startsWith('${destination.path}/')),
                onTap: () => onGo(destination.path),
              ),
            ),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onMore,
              child: _PhoneTabContent(
                icon: WaveIcons.more,
                label: 'More',
                selected: moreActive,
              ),
            ),
          ),
        ],
        ),
      ),
    );
  }
}

class _PhoneTab extends StatelessWidget {
  final WaveDestination destination;
  final bool selected;
  final VoidCallback onTap;

  const _PhoneTab({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: _PhoneTabContent(
          icon: destination.icon,
          label: destination.label,
          selected: selected,
        ),
      );
}

class _PhoneTabContent extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;

  const _PhoneTabContent({
    required this.icon,
    required this.label,
    required this.selected,
  });

  @override
  Widget build(BuildContext context) {
    final color =
        selected ? waveTextPrimary(context) : waveTextSecondary(context);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 21, color: color),
        const SizedBox(height: 3),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: WaveType.meta.copyWith(
            fontSize: 10,
            color: color,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ],
    );
  }
}

class _MobileTransportDock extends ConsumerWidget {
  final bool queueActive;
  final bool equalizerActive;
  final VoidCallback onQueue;
  final VoidCallback onEqualizer;

  const _MobileTransportDock({
    required this.onQueue,
    required this.onEqualizer,
    required this.queueActive,
    required this.equalizerActive,
  });

  String _time(Duration value) {
    final minutes = value.inMinutes;
    final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(
      playbackServiceProvider.select((state) => (
        current: state.current,
        isPlaying: state.isPlaying,
        position: state.position,
        buffered: state.buffered,
        duration: state.duration,
        volume: state.volume,
        stream: state.stream,
        shuffleEnabled: state.shuffleEnabled,
        repeatMode: state.repeatMode,
      )),
    );
    final playback = ref.read(playbackServiceProvider.notifier);
    final output = ref.read(audioOutputProvider.notifier);
    final wavySeekbar =
        ref.watch(prefsProvider.select((prefs) => prefs.wavySeekbar));
    final duration = snapshot.duration;
    final hasDuration = duration > Duration.zero;
    final volume = snapshot.volume.clamp(0.0, 1.0).toDouble();
    final quality = snapshot.stream?.qualityBadge ?? '';

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 3, 12, 8),
      decoration: BoxDecoration(
        color: waveSurface(context),
        border: Border(top: BorderSide(color: waveDivider(context))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              SizedBox(
                width: 38,
                child: Text(
                  hasDuration ? _time(snapshot.position) : '--:--',
                  style: WaveType.meta,
                ),
              ),
              Expanded(
                child: wavySeekbar
                    ? WaveTimeline(
                        progress: snapshot.position,
                        buffered: snapshot.buffered,
                        total: duration,
                        showThumb: hasDuration,
                        onSeek: hasDuration ? playback.seek : null,
                        baseColor:
                            waveTextSecondary(context).withValues(alpha: 0.12),
                        bufferedColor:
                            waveTextSecondary(context).withValues(alpha: 0.18),
                        progressColor: waveTextPrimary(context),
                        thumbColor: waveTextPrimary(context),
                        thumbGlowColor:
                            waveAccent(context).withValues(alpha: 0.25),
                      )
                    : avp.ProgressBar(
                        progress: snapshot.position,
                        buffered: snapshot.buffered,
                        total:
                            hasDuration ? duration : const Duration(seconds: 1),
                        onSeek: hasDuration ? playback.seek : null,
                        barHeight: 3,
                        thumbRadius: hasDuration ? 5 : 0,
                        thumbColor: waveTextPrimary(context),
                        progressBarColor: waveTextPrimary(context),
                        bufferedBarColor:
                            waveTextSecondary(context).withValues(alpha: 0.22),
                        baseBarColor:
                            waveTextSecondary(context).withValues(alpha: 0.12),
                        timeLabelLocation: avp.TimeLabelLocation.none,
                      ),
              ),
              SizedBox(
                width: 38,
                child: Text(
                  hasDuration ? _time(duration) : '--:--',
                  textAlign: TextAlign.end,
                  style: WaveType.meta,
                ),
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _TouchIconButton(
                icon: WaveIcons.shuffle,
                tooltip: 'Shuffle',
                selected: snapshot.shuffleEnabled,
                onPressed: playback.toggleShuffle,
              ),
              _TouchIconButton(
                icon: WaveIcons.previous,
                tooltip: 'Previous track',
                onPressed: playback.previous,
              ),
              Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  color: waveTextPrimary(context),
                  shape: BoxShape.circle,
                ),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: playback.toggle,
                  child: Icon(
                    snapshot.isPlaying ? WaveIcons.pause : WaveIcons.play,
                    color: waveBackground(context),
                    size: 23,
                  ),
                ),
              ),
              _TouchIconButton(
                icon: WaveIcons.next,
                tooltip: 'Next track',
                onPressed: playback.next,
              ),
              _TouchIconButton(
                icon: snapshot.repeatMode.name == 'one'
                    ? WaveIcons.repeatOne
                    : WaveIcons.repeat,
                tooltip: 'Repeat mode',
                selected: snapshot.repeatMode.name != 'off',
                onPressed: playback.cycleRepeat,
              ),
            ],
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 420;
              return Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _TouchIconButton(
                    icon: WaveIcons.queue,
                    tooltip: 'Queue',
                    selected: queueActive,
                    width: compact ? 42 : 48,
                    onPressed: onQueue,
                  ),
                  _TouchIconButton(
                    icon: WaveIcons.equalizer,
                    tooltip: 'Equalizer',
                    selected: equalizerActive,
                    width: compact ? 42 : 48,
                    onPressed: onEqualizer,
                  ),
                  if (!compact && quality.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        border: Border.all(color: waveDivider(context)),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        quality,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: WaveType.overline.copyWith(fontSize: 9),
                      ),
                    ),
                  const SizedBox(width: 12),
                  _TouchIconButton(
                    icon: volume <= 0 ? WaveIcons.volumeMute : WaveIcons.volume,
                    tooltip: volume <= 0
                        ? 'Unmute'
                        : 'Mute (${(volume * 100).round()}%)',
                    width: compact ? 42 : 48,
                    onPressed: output.toggleMute,
                  ),
                  const SizedBox(width: 2),
                  LWVolumeSlider(
                    value: volume,
                    width: compact ? 64 : 88,
                    semanticLabel: 'Playback volume',
                    onChanged: output.setVolume,
                  ),
                  if (!compact) ...[
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 46,
                      child: Text(
                        '${(volume * 100).round()}%',
                        maxLines: 1,
                        softWrap: false,
                        textAlign: TextAlign.center,
                        style: WaveType.meta,
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

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
    final trackKey = track == null
        ? ''
        : '${track.title.toLowerCase()}|${track.artist.toLowerCase()}';
    final isLiked = track != null && playlists.any((playlist) =>
        playlist.isLikedSongs &&
        playlist.tracks.any((saved) =>
            '${saved.name.toLowerCase()}|${saved.artist.toLowerCase()}' ==
            trackKey));
    final stream = player.stream;
    final codec = stream == null
        ? ''
        : stream.audioCodec.trim().isNotEmpty
            ? stream.audioCodec.trim().toUpperCase()
            : stream.mimeType.split('/').last.split(';').first.toUpperCase();
    final streamDetails = [
      if (stream != null && stream.qualityBadge.isNotEmpty)
        stream.qualityBadge,
      if (codec.isNotEmpty) codec,
      if ((stream?.bitrateKbps ?? 0) > 0) '${stream!.bitrateKbps} kbps',
    ].join(' · ');
    final durationMs = player.duration.inMilliseconds;
    final progressRatio = durationMs > 0
        ? (player.position.inMilliseconds / durationMs)
            .clamp(0.0, 1.0)
            .toDouble()
        : 0.0;

    return Container(
      height: 78,
      margin: const EdgeInsets.fromLTRB(10, 7, 10, 7),
      child: WaveHaze(
        level: LwHazeLevel.l2,
        base: waveSurfaceRaised(context),
        borderRadius: BorderRadius.circular(16),
        border: waveIsDark(context)
            ? Border.all(color: waveDivider(context).withValues(alpha: 0.8))
            : null,
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
                      size: 44,
                      radius: 7,
                      label: track.title,
                      title: track.title,
                      artist: track.artist,
                    )
                  else
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: waveSurface(context),
                        borderRadius: BorderRadius.circular(7),
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
              borderRadius: BorderRadius.circular(12),
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
                        borderRadius: BorderRadius.circular(12),
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
