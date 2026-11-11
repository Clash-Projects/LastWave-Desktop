import 'dart:io' show Platform;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:audio_video_progress_bar/audio_video_progress_bar.dart' as avp;

import '../../core/storage/prefs.dart';
import '../../core/audio/stream_models.dart';
import '../../features/downloads/download_manager.dart';
import '../../core/network/network_monitor.dart';
import '../../features/settings/theme_controller.dart';
import '../../features/player/playback_service.dart';
import '../../features/equalizer/equalizer_panel.dart';
import '../../features/audio_output/output_controller.dart';
import '../components/artwork.dart';
import '../components/ambient.dart' show artworkSeedProvider;
import '../components/touch_kit.dart';
import '../navigation/destinations.dart';
import '../queue/queue_panel.dart';
import '../components/buttons.dart' show LWVolumeSlider, WaveButton;
import '../player_dock/player_dock.dart' show WaveTimeline;
import '../now_playing/immersive.dart' show nowPlayingOverlayRequestProvider;
import '../theme/haze.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

/// iPhone tab bar: five destinations plus More, so every tab keeps an icon
/// *and* a label at one-handed thumb size. Everything else lives in More.
const _phoneDestinations = <WaveDestination>[
  WaveDestination('/home', 'Home', WaveIcons.home),
  WaveDestination('/search', 'Search', WaveIcons.search),
  WaveDestination('/liked', 'Liked', WaveIcons.liked),
  WaveDestination('/playlists', 'Playlists', WaveIcons.playlists),
  WaveDestination('/settings', 'Settings', WaveIcons.settings),
];

const _phoneMoreDestinations = <WaveDestination>[
  WaveDestination('/home-layout', 'Edit Home', WaveIcons.edit),
  WaveDestination('/albums', 'Albums', WaveIcons.albums),
  WaveDestination('/artists', 'Artists', WaveIcons.artists),
  WaveDestination('/downloads', 'Downloads', WaveIcons.downloads),
  WaveDestination('/stats', 'Stats', WaveIcons.stats),
  WaveDestination('/podcasts', 'Podcasts', WaveIcons.podcasts),
  WaveDestination('/mixes', 'Mix Lab', WaveIcons.mixes),
  WaveDestination('/history', 'Listening history', WaveIcons.history),
  WaveDestination('/friends', 'Friends', WaveIcons.friends),
];

/// iPad floating top bar: a tablet has the width for Albums and Downloads
/// in the bar itself.
const _tabletDestinations = <WaveDestination>[
  WaveDestination('/home', 'Home', WaveIcons.home),
  WaveDestination('/search', 'Search', WaveIcons.search),
  WaveDestination('/liked', 'Liked Songs', WaveIcons.liked),
  WaveDestination('/playlists', 'Playlists', WaveIcons.playlists),
  WaveDestination('/albums', 'Albums', WaveIcons.albums),
  WaveDestination('/downloads', 'Downloads', WaveIcons.downloads),
  WaveDestination('/settings', 'Settings', WaveIcons.settings),
];

const _tabletMoreDestinations = <WaveDestination>[
  WaveDestination('/home-layout', 'Edit Home', WaveIcons.edit),
  WaveDestination('/artists', 'Artists', WaveIcons.artists),
  WaveDestination('/stats', 'Stats', WaveIcons.stats),
  WaveDestination('/podcasts', 'Podcasts', WaveIcons.podcasts),
  WaveDestination('/mixes', 'Mix Lab', WaveIcons.mixes),
  WaveDestination('/history', 'Listening history', WaveIcons.history),
  WaveDestination('/friends', 'Friends', WaveIcons.friends),
];

/// Touch-first shell for iPhone and iPad. It reuses the existing routes,
/// page widgets, playback service, and settings state; only the app chrome
/// changes from the desktop WaveShell.
///
/// Chrome model ("floating glass over artwork aura"):
/// - The page always fills the screen between a slim top zone and the
///   bottom dock; chrome never sits flush against an edge.
/// - iPhone: a floating mini-player above a floating tab bar.
/// - iPad: a floating icon-led navigation capsule at the top (no side rail)
///   and a floating mini-player at the bottom, both capped at
///   [WaveTouch.floatMaxWidth] and centred so they stay composed in Split
///   View, Stage Manager and landscape.
/// - Now Playing replaces the dock with one floating control tray.
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

  void _back(List<WaveDestination> more) {
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
    } else if (more.any((d) => d.path == _route)) {
      // A library page reached from the More list goes back to that list.
      setState(() => _showMore = true);
    } else {
      _go('/home');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Now Playing's top bar asks the shell to open the queue / equalizer.
    ref.listen<String?>(nowPlayingOverlayRequestProvider, (previous, action) {
      if (action == null || !mounted) return;
      setState(() {
        _showMore = false;
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
        final tabs = tablet ? _tabletDestinations : _phoneDestinations;
        final moreDestinations =
            tablet ? _tabletMoreDestinations : _phoneMoreDestinations;
        final moreActive = _showMore ||
            moreDestinations.any((d) =>
                activePath == d.path ||
                _route.startsWith('${d.path}/'));
        // Tab roots have nothing to go back to; every other page does.
        final showBack = !nowPlaying &&
            !_showMore &&
            !tabs.any((d) => d.path == _route);

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
                  child: Column(
                      children: [
                        if (tablet && !nowPlaying)
                          _TabletTopBar(
                            destinations: tabs,
                            activePath: activePath,
                            moreActive: moreActive,
                            showBack: showBack,
                            showLabels: constraints.maxWidth >= 1000,
                            onGo: _go,
                            onMore: () =>
                                setState(() => _showMore = !_showMore),
                            onBack: () => _back(moreDestinations),
                          ),
                        if (!tablet && showBack)
                          _BackHeader(
                            onBack: () => _back(moreDestinations),
                          ),
                        Expanded(
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
                                    onClose: () => _back(moreDestinations),
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
                                          onClose: () =>
                                              _back(moreDestinations),
                                        ),
                                        Expanded(
                                          child: WaveQueuePanel(
                                            onClose: () =>
                                                _back(moreDestinations),
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
                                        margin: const EdgeInsets.all(
                                          WaveSpacing.x20,
                                        ),
                                        padding: const EdgeInsets.all(
                                          WaveSpacing.x20,
                                        ),
                                        decoration: BoxDecoration(
                                          color: waveSurfaceRaised(context),
                                          borderRadius:
                                              WaveRadius.floatingRadius,
                                          border: Border.all(
                                            color: waveDivider(context),
                                          ),
                                          boxShadow: WaveElevation.floating(
                                            waveIsDark(context),
                                          ),
                                        ),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              "You're offline",
                                              textAlign: TextAlign.center,
                                              style: WaveTouchType.rowTitle
                                                  .copyWith(
                                                color:
                                                    waveTextPrimary(context),
                                              ),
                                            ),
                                            const SizedBox(
                                              height: WaveSpacing.x4,
                                            ),
                                            Text(
                                              'Check your internet connection. '
                                              'Some LastWave features need to be online.',
                                              textAlign: TextAlign.center,
                                              style:
                                                  WaveTouchType.rowMeta.copyWith(
                                                color:
                                                    waveTextSecondary(context),
                                              ),
                                            ),
                                            const SizedBox(
                                              height: WaveSpacing.x12,
                                            ),
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
                        if (nowPlaying)
                          _DockFrame(
                            child: _MobileTransportDock(
                              // iPad keeps queue / equalizer / download in
                              // the Now Playing top bar; on a compact phone
                              // that bar has no room, so the tray carries them.
                              showUtilities:
                                  Platform.isIOS && viewSize.shortestSide < 600,
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
                          )
                        else
                          _DockFrame(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _MobileMiniPlayer(onOpen: _openNowPlaying),
                                if (!tablet) ...[
                                  const SizedBox(height: WaveTouch.floatGap),
                                  _PhoneTabBar(
                                    destinations: tabs,
                                    activePath: activePath,
                                    moreActive: moreActive,
                                    onGo: _go,
                                    onMore: () => setState(
                                      () => _showMore = !_showMore,
                                    ),
                                  ),
                                ],
                              ],
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

/// Positions floating bottom chrome: inset from the screen edge, centred and
/// capped at [WaveTouch.floatMaxWidth] so it stays composed on iPad.
class _DockFrame extends StatelessWidget {
  final Widget child;

  const _DockFrame({required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        WaveTouch.floatInset,
        0,
        WaveTouch.floatInset,
        WaveTouch.floatGap,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints:
              const BoxConstraints(maxWidth: WaveTouch.floatMaxWidth),
          child: child,
        ),
      ),
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

/// Glass square back chip used by the phone header and the iPad top bar.
class _BackChip extends StatelessWidget {
  final VoidCallback onBack;

  const _BackChip({required this.onBack});

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    return Semantics(
      button: true,
      label: 'Back',
      excludeSemantics: true,
      child: WavePressable(
        onTap: onBack,
        haptic: true,
        child: Container(
          width: WaveTouch.hit,
          height: WaveTouch.hit,
          decoration: BoxDecoration(
            color: waveSurface(context).withValues(alpha: 0.78),
            borderRadius: WaveRadius.menuRadius,
            border: Border.all(
              color: (dark ? Colors.white : Colors.black)
                  .withValues(alpha: dark ? 0.09 : 0.08),
            ),
          ),
          child: Center(
            child: Icon(
              WaveIcons.back,
              size: WaveTouch.iconSecondary,
              color: waveTextPrimary(context),
            ),
          ),
        ),
      ),
    );
  }
}

/// iPhone header: present only on pages with somewhere to go back to, so tab
/// roots get their full height back.
class _BackHeader extends StatelessWidget {
  final VoidCallback onBack;

  const _BackHeader({required this.onBack});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        WaveTouch.floatInset,
        WaveSpacing.x2,
        WaveTouch.floatInset,
        WaveSpacing.x2,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: _BackChip(onBack: onBack),
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
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(
          WaveTouch.floatInset,
          WaveSpacing.x2,
          WaveTouch.floatInset,
          WaveSpacing.x4,
        ),
        child: Row(
          children: [
            _BackChip(onBack: onClose),
            const SizedBox(width: WaveSpacing.x8),
            Text(
              title,
              style: WaveTouchType.rowTitle.copyWith(
                color: waveTextPrimary(context),
              ),
            ),
          ],
        ),
      );
}

/// iPhone floating tab bar.
class _PhoneTabBar extends StatelessWidget {
  final List<WaveDestination> destinations;
  final String activePath;
  final bool moreActive;
  final void Function(String) onGo;
  final VoidCallback onMore;

  const _PhoneTabBar({
    required this.destinations,
    required this.activePath,
    required this.moreActive,
    required this.onGo,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    return WaveFloatingSurface(
      child: SizedBox(
        height: WaveTouch.tabBarHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: WaveSpacing.x2),
          child: Row(
            children: [
              for (final destination in destinations)
                Expanded(
                  child: _PhoneTab(
                    icon: destination.icon,
                    label: destination.label,
                    selected: !moreActive &&
                        (activePath == destination.path ||
                            activePath.startsWith('${destination.path}/')),
                    onTap: () => onGo(destination.path),
                  ),
                ),
              Expanded(
                child: _PhoneTab(
                  icon: WaveIcons.more,
                  label: 'More',
                  selected: moreActive,
                  onTap: onMore,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PhoneTab extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _PhoneTab({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color =
        selected ? waveTextPrimary(context) : waveTextTertiary(context);
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: WavePressable(
        onTap: onTap,
        haptic: true,
        child: AnimatedContainer(
          duration: waveMotion(context, WaveMotion.normal),
          curve: WaveMotion.standard,
          margin: const EdgeInsets.symmetric(
            horizontal: WaveSpacing.x2,
            vertical: WaveSpacing.x4,
          ),
          decoration: BoxDecoration(
            color: selected ? waveWash(context, 0.10) : Colors.transparent,
            borderRadius: WaveRadius.menuRadius,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: WaveTouch.iconPrimary - 2, color: color),
              const SizedBox(height: 3),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: WaveTouchType.tabLabel.copyWith(
                  color: color,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// iPad floating navigation capsule, centred at the top of the window.
///
/// Icon-led: the selected destination expands to show its label (every
/// destination does once the window is wide enough). Back, when the page has
/// somewhere to go back to, sits at the leading edge.
class _TabletTopBar extends StatelessWidget {
  final List<WaveDestination> destinations;
  final String activePath;
  final bool moreActive;
  final bool showBack;
  final bool showLabels;
  final void Function(String) onGo;
  final VoidCallback onMore;
  final VoidCallback onBack;

  const _TabletTopBar({
    required this.destinations,
    required this.activePath,
    required this.moreActive,
    required this.showBack,
    required this.showLabels,
    required this.onGo,
    required this.onMore,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        WaveTouch.floatInset,
        WaveSpacing.x4,
        WaveTouch.floatInset,
        WaveSpacing.x2,
      ),
      child: SizedBox(
        height: WaveTouch.tabletBarHeight,
        child: Stack(
          children: [
            if (showBack)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: Center(child: _BackChip(onBack: onBack)),
              ),
            Center(
              // Scale-down is a safety net for very narrow Split View
              // windows: the capsule shrinks instead of overflowing.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: WaveFloatingSurface(
                  borderRadius: BorderRadius.circular(WaveRadius.hero),
                  child: Padding(
                    padding: const EdgeInsets.all(WaveSpacing.x2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final destination in destinations)
                          _TabletTab(
                            icon: destination.icon,
                            label: destination.label,
                            showLabel: showLabels ||
                                (!moreActive &&
                                    (activePath == destination.path ||
                                        activePath.startsWith(
                                            '${destination.path}/'))),
                            selected: !moreActive &&
                                (activePath == destination.path ||
                                    activePath
                                        .startsWith('${destination.path}/')),
                            onTap: () => onGo(destination.path),
                          ),
                        _TabletTab(
                          icon: WaveIcons.more,
                          label: 'More',
                          showLabel: showLabels || moreActive,
                          selected: moreActive,
                          onTap: onMore,
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
    );
  }
}

class _TabletTab extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool showLabel;
  final bool selected;
  final VoidCallback onTap;

  const _TabletTab({
    required this.icon,
    required this.label,
    required this.showLabel,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color =
        selected ? waveTextPrimary(context) : waveTextSecondary(context);
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: WavePressable(
        onTap: onTap,
        haptic: true,
        child: AnimatedContainer(
          duration: waveMotion(context, WaveMotion.normal),
          curve: WaveMotion.standard,
          height: WaveTouch.hit,
          constraints: const BoxConstraints(minWidth: WaveTouch.hit),
          padding: EdgeInsets.symmetric(
            horizontal: showLabel ? WaveSpacing.x8 : WaveSpacing.x4,
          ),
          decoration: BoxDecoration(
            color: selected ? waveWash(context, 0.12) : Colors.transparent,
            borderRadius: WaveRadius.menuRadius,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: WaveTouch.iconSecondary, color: color),
              if (showLabel) ...[
                const SizedBox(width: WaveSpacing.x4 - 2),
                Text(
                  label,
                  maxLines: 1,
                  style: WaveTouchType.rowMeta.copyWith(
                    color: color,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Now Playing control tray: one floating surface holding the seek bar,
/// transport, and utility actions. Nothing scrolls — the transport row is a
/// fixed five-control layout, and the utility row gives the volume slider
/// whatever width is left, so it adapts from a 320pt phone to a 13" iPad.
class _MobileTransportDock extends ConsumerWidget {
  final bool showUtilities;
  final bool queueActive;
  final bool equalizerActive;
  final VoidCallback onQueue;
  final VoidCallback onEqualizer;

  const _MobileTransportDock({
    required this.showUtilities,
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
        isBuffering: state.isBuffering,
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
    final wavySeekbar =
        ref.watch(prefsProvider.select((prefs) => prefs.wavySeekbar));
    final duration = snapshot.duration;
    final hasDuration = duration > Duration.zero;
    final volume = snapshot.volume.clamp(0.0, 1.0).toDouble();
    final captionStyle = WaveTouchType.caption.copyWith(
      color: waveTextSecondary(context),
    );

    return WaveFloatingSurface(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          WaveSpacing.x12,
          WaveSpacing.x8,
          WaveSpacing.x12,
          WaveSpacing.x4,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 28,
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
                      barHeight: 4,
                      thumbRadius: hasDuration ? 6 : 0,
                      thumbColor: waveTextPrimary(context),
                      progressBarColor: waveTextPrimary(context),
                      bufferedBarColor:
                          waveTextSecondary(context).withValues(alpha: 0.22),
                      baseBarColor:
                          waveTextSecondary(context).withValues(alpha: 0.12),
                      timeLabelLocation: avp.TimeLabelLocation.none,
                    ),
            ),
            Row(
              children: [
                Text(
                  hasDuration ? _time(snapshot.position) : '--:--',
                  style: captionStyle,
                ),
                const Spacer(),
                Text(
                  hasDuration ? _time(duration) : '--:--',
                  style: captionStyle,
                ),
              ],
            ),
            const SizedBox(height: WaveSpacing.x2),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                WaveTouchIconButton(
                  icon: WaveIcons.shuffle,
                  label: 'Shuffle',
                  selected: snapshot.shuffleEnabled,
                  onPressed: playback.toggleShuffle,
                ),
                WaveTouchIconButton(
                  icon: WaveIcons.previous,
                  label: 'Previous track',
                  size: WaveTouch.transportButton,
                  iconSize: WaveTouch.iconPrimary + 2,
                  color: waveTextPrimary(context),
                  onPressed: playback.previous,
                ),
                WavePlayDisc(
                  playing: snapshot.isPlaying,
                  busy: snapshot.isBuffering,
                  onPressed: playback.toggle,
                ),
                WaveTouchIconButton(
                  icon: WaveIcons.next,
                  label: 'Next track',
                  size: WaveTouch.transportButton,
                  iconSize: WaveTouch.iconPrimary + 2,
                  color: waveTextPrimary(context),
                  onPressed: playback.next,
                ),
                WaveTouchIconButton(
                  icon: snapshot.repeatMode.name == 'one'
                      ? WaveIcons.repeatOne
                      : WaveIcons.repeat,
                  label: 'Repeat mode',
                  selected: snapshot.repeatMode.name != 'off',
                  onPressed: playback.cycleRepeat,
                ),
              ],
            ),
            const SizedBox(height: WaveSpacing.x2),
            Row(
              children: [
                if (showUtilities) ...[
                  WaveTouchIconButton(
                    icon: WaveIcons.queue,
                    label: 'Queue',
                    selected: queueActive,
                    onPressed: onQueue,
                  ),
                  WaveTouchIconButton(
                    icon: WaveIcons.equalizer,
                    label: 'Equalizer',
                    selected: equalizerActive,
                    onPressed: onEqualizer,
                  ),
                  _MobileDownloadButton(track: snapshot.current),
                  const SizedBox(width: WaveSpacing.x4),
                ],
                WaveTouchIconButton(
                  icon: volume <= 0
                      ? WaveIcons.volumeMute
                      : WaveIcons.volume,
                  label: volume <= 0
                      ? 'Unmute'
                      : 'Mute (${(volume * 100).round()}%)',
                  onPressed: output.toggleMute,
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) => LWVolumeSlider(
                      value: volume,
                      width: constraints.maxWidth,
                      semanticLabel: 'Playback volume',
                      onChanged: output.setVolume,
                    ),
                  ),
                ),
              ],
            ),
          ],
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
  ].join(' · ');
}

/// Floating mini-player: artwork, title / artist, play-pause and next, with a
/// hairline progress along the bottom edge. Tap opens Now Playing; swiping
/// left or right skips to the next or previous track. Everything else (like,
/// add to playlist, download, quality) lives on Now Playing, where it has room.
/// Hidden entirely while nothing is loaded.
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
        stream: state.stream,
      )),
    );
    final track = player.current;
    if (track == null) return const SizedBox.shrink();
    final streamDetails = _mobileStreamDetails(player.stream);
    final playback = ref.read(playbackServiceProvider.notifier);
    final artworkTint =
        ref.watch(artworkSeedProvider(track.artworkUrl)).valueOrNull;

    return Semantics(
      container: true,
      label: 'Now playing: ${track.title} by ${track.artist}',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragEnd: (details) {
          final velocity = details.primaryVelocity ?? 0;
          if (velocity < -300) {
            playback.next();
          } else if (velocity > 300) {
            playback.previous();
          }
        },
        child: WaveFloatingSurface(
          artworkTint: artworkTint,
          base: waveSurfaceRaised(context),
          child: SizedBox(
            height: WaveTouch.miniPlayerHeight,
            child: Stack(
              children: [
                Positioned.fill(
                  child: Row(
                  children: [
                    Expanded(
                      child: WavePressable(
                        onTap: onOpen,
                        pressedScale: 0.98,
                        child: Padding(
                          padding: const EdgeInsets.only(
                            left: WaveSpacing.x4,
                            right: WaveSpacing.x2,
                          ),
                          child: Row(
                            children: [
                              WaveArtwork(
                                url: track.artworkUrl,
                                videoId: track.videoId,
                                size: WaveTouch.miniArtwork,
                                radius: WaveRadius.controls,
                                label: track.title,
                                title: track.title,
                                artist: track.artist,
                              ),
                              const SizedBox(width: WaveSpacing.x8),
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    _WaveAutoScrollText(
                                      text: track.title,
                                      style: WaveTouchType.rowTitle.copyWith(
                                        color: waveTextPrimary(context),
                                      ),
                                    ),
                                    _WaveAutoScrollText(
                                      text: track.artist,
                                      style: WaveTouchType.rowMeta.copyWith(
                                        color: waveTextSecondary(context),
                                      ),
                                    ),
                                    if (streamDetails.isNotEmpty)
                                      _WaveAutoScrollText(
                                        text: streamDetails,
                                        style: WaveTouchType.tabLabel.copyWith(
                                          color: waveTextTertiary(context),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    WaveTouchIconButton(
                      icon: player.isBuffering
                          ? WaveIcons.music
                          : player.isPlaying
                              ? WaveIcons.pause
                              : WaveIcons.play,
                      label: player.isPlaying ? 'Pause' : 'Play',
                      iconSize: WaveTouch.iconPrimary,
                      color: waveTextPrimary(context),
                      onPressed: playback.toggle,
                    ),
                    WaveTouchIconButton(
                      icon: WaveIcons.next,
                      label: 'Next track',
                      iconSize: WaveTouch.iconPrimary,
                      color: waveTextPrimary(context),
                      onPressed: playback.next,
                    ),
                    const SizedBox(width: WaveSpacing.x2),
                  ],
                  ),
                ),
                const Positioned(
                  left: WaveSpacing.x8,
                  right: WaveSpacing.x8,
                  bottom: 0,
                  child: _MiniProgressLine(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Hairline playback progress along the mini-player's bottom edge. Watches
/// position on its own so the card above doesn't rebuild every tick.
class _MiniProgressLine extends ConsumerWidget {
  const _MiniProgressLine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(
      playbackServiceProvider.select((state) => (
        position: state.position,
        buffered: state.buffered,
        duration: state.duration,
      )),
    );
    final wavySeekbar =
        ref.watch(prefsProvider.select((prefs) => prefs.wavySeekbar));
    if (wavySeekbar) {
      // Same wavy timeline as the full player, display-only.
      return WaveTimeline(
        progress: progress.position,
        buffered: progress.buffered,
        total: progress.duration,
        showThumb: false,
        onSeek: null,
        baseColor: waveTextSecondary(context).withValues(alpha: 0.12),
        bufferedColor: waveTextSecondary(context).withValues(alpha: 0.18),
        progressColor: waveTextPrimary(context),
        thumbColor: waveTextPrimary(context),
        thumbGlowColor: waveAccent(context).withValues(alpha: 0.25),
      );
    }
    final durationMs = progress.duration.inMilliseconds;
    final ratio = durationMs > 0
        ? (progress.position.inMilliseconds / durationMs)
            .clamp(0.0, 1.0)
            .toDouble()
        : 0.0;
    return Container(
      height: 3,
      decoration: BoxDecoration(
        color: waveWash(context, 0.12),
        borderRadius: WaveRadius.tinyRadius,
      ),
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: ratio,
        child: Container(
          decoration: BoxDecoration(
            color: waveTextPrimary(context),
            borderRadius: WaveRadius.tinyRadius,
          ),
        ),
      ),
    );
  }
}

class _MobileDownloadButton extends ConsumerWidget {
  final PlayableTrack? track;

  const _MobileDownloadButton({required this.track});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = track;
    if (current == null) {
      return const WaveTouchIconButton(
        icon: FluentIcons.download,
        label: 'Download',
        onPressed: null,
      );
    }
    final key = DownloadManager.keyOf(current.title, current.artist);
    DownloadEntry? entry;
    for (final candidate in ref.watch(downloadManagerProvider)) {
      if (candidate.key == key) {
        entry = candidate;
        break;
      }
    }
    final done = entry?.status == DownloadStatus.done;
    final failed = entry?.status == DownloadStatus.error;
    final inProgress = entry?.status == DownloadStatus.queued ||
        entry?.status == DownloadStatus.downloading;
    final manager = ref.read(downloadManagerProvider.notifier);
    // Same behaviour as the Now Playing top bar: tap cancels an active
    // download, deletes a finished one, and starts / retries otherwise.
    return WaveTouchIconButton(
      icon: inProgress
          ? FluentIcons.cancel
          : done
              ? FluentIcons.delete
              : FluentIcons.download,
      label: inProgress
          ? 'Cancel download'
          : done
              ? 'Delete download'
              : failed
                  ? 'Download failed — retry'
                  : 'Download',
      selected: done || failed,
      onPressed: () {
        if (inProgress) {
          manager.cancelDownload(key);
        } else if (done) {
          manager.delete(key);
        } else {
          manager.downloadTrack(
            title: current.title,
            artist: current.artist,
            album: current.album,
            artworkUrl: current.artworkUrl,
            videoId: current.videoId,
          );
        }
      },
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

/// Library destinations that don't earn a tab: a large-title list of
/// shared-material rows.
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
    final dark = waveIsDark(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            WaveTouch.floatInset,
            WaveSpacing.x2,
            WaveTouch.floatInset,
            WaveSpacing.x4,
          ),
          child: _BackChip(onBack: onBack),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            WaveSpacing.x12,
            WaveSpacing.x2,
            WaveSpacing.x12,
            WaveSpacing.x8,
          ),
          child: Text(
            'More',
            style: WaveTouchType.largeTitle.copyWith(
              color: waveTextPrimary(context),
            ),
          ),
        ),
        Expanded(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints:
                  const BoxConstraints(maxWidth: WaveTouch.floatMaxWidth),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  WaveSpacing.x12,
                  WaveSpacing.x2,
                  WaveSpacing.x12,
                  WaveSpacing.x20,
                ),
                children: [
                  for (final destination in destinations)
                    Padding(
                      padding: const EdgeInsets.only(bottom: WaveSpacing.x4),
                      child: Semantics(
                        button: true,
                        label: destination.label,
                        excludeSemantics: true,
                        child: WavePressable(
                          onTap: () => onGo(destination.path),
                          pressedScale: 0.98,
                          child: Container(
                            height: 60,
                            padding: const EdgeInsets.symmetric(
                              horizontal: WaveSpacing.x12,
                            ),
                            decoration: BoxDecoration(
                              color: waveSurface(context),
                              borderRadius: WaveRadius.floatingRadius,
                              border: Border.all(
                                color: (dark ? Colors.white : Colors.black)
                                    .withValues(alpha: dark ? 0.07 : 0.08),
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  destination.icon,
                                  size: WaveTouch.iconSecondary,
                                  color: waveTextPrimary(context),
                                ),
                                const SizedBox(width: WaveSpacing.x12),
                                Expanded(
                                  child: Text(
                                    destination.label,
                                    style: WaveTouchType.rowTitle.copyWith(
                                      color: waveTextPrimary(context),
                                    ),
                                  ),
                                ),
                                Icon(
                                  WaveIcons.chevronRight,
                                  size: 16,
                                  color: waveTextTertiary(context),
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
        ),
      ],
    );
  }
}
