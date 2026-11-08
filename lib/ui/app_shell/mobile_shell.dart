import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/audio/stream_models.dart';
import '../../features/player/playback_service.dart';
import '../../features/player/player_state.dart';
import '../../features/equalizer/equalizer_panel.dart';
import '../components/artwork.dart';
import '../navigation/destinations.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

const _phoneDestinations = <WaveDestination>[
  WaveDestination('/home', 'Home', WaveIcons.home),
  WaveDestination('/search', 'Search', WaveIcons.search),
  WaveDestination('/liked', 'Liked', WaveIcons.liked),
  WaveDestination('/playlists', 'Playlists', WaveIcons.playlists),
];

const _tabletDestinations = <WaveDestination>[
  WaveDestination('/home', 'Home', WaveIcons.home),
  WaveDestination('/search', 'Search', WaveIcons.search),
  WaveDestination('/liked', 'Liked Songs', WaveIcons.liked),
  WaveDestination('/albums', 'Albums', WaveIcons.albums),
  WaveDestination('/artists', 'Artists', WaveIcons.artists),
  WaveDestination('/playlists', 'Playlists', WaveIcons.playlists),
  WaveDestination('/downloads', 'Downloads', WaveIcons.downloads),
];

const _moreDestinations = <WaveDestination>[
  WaveDestination('/stats', 'Listening statistics', WaveIcons.stats),
  WaveDestination('/podcasts', 'Podcasts', WaveIcons.podcasts),
  WaveDestination('/mixes', 'Mix Lab', WaveIcons.mixes),
  WaveDestination('/friends', 'Friends', WaveIcons.friends),
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

  String get _route => waveRoutePath(widget.location);

  String get _title {
    if (_showMore) return 'More';
    for (final destination in [..._tabletDestinations, ..._moreDestinations]) {
      if (_route == destination.path ||
          _route.startsWith('${destination.path}/')) {
        return destination.label;
      }
    }
    if (_route.startsWith('/now')) return 'Now Playing';
    if (_route.startsWith('/album/')) return 'Album';
    if (_route.startsWith('/artist/')) return 'Artist';
    if (_route.startsWith('/history')) return 'History';
    return 'LastWave';
  }

  void _go(String path) {
    setState(() {
      _showMore = false;
      _showEqualizer = false;
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
        clean.startsWith('/spotifyplaylist/')) return 6;
    if (clean == '/podcasts' || clean.startsWith('/podcasts/')) return 7;
    if (clean == '/downloads') return 8;
    return null;
  }

  void _openNowPlaying() {
    if (!_route.startsWith('/now')) context.push('/now');
  }

  void _back() {
    if (_showEqualizer) {
      setState(() => _showEqualizer = false);
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
    final PlayerSnapshot player = ref.watch(playbackServiceProvider);
    final playback = ref.read(playbackServiceProvider.notifier);

    return LayoutBuilder(
      builder: (context, constraints) {
        // Window width matters: Split View and Stage Manager can be narrower
        // than the iPad's physical display.
        final tablet = constraints.maxWidth >= 720;
        final nowPlaying = _route.startsWith('/now');
        final activePath = waveActivePath(widget.location);
        final moreActive = _showMore ||
            _moreDestinations.any((d) =>
                activePath == d.path ||
                _route.startsWith('${d.path}/'));

        return ColoredBox(
          color: waveBackground(context),
          child: SafeArea(
            child: Row(
              children: [
                if (tablet && !nowPlaying)
                  _TabletRail(
                    activePath: activePath,
                    moreActive: moreActive,
                    onGo: _go,
                    onMore: () => setState(() => _showMore = true),
                  ),
                Expanded(
                  child: Column(
                    children: [
                      if (nowPlaying)
                        _NowPlayingToolbar(
                          onBack: _back,
                          onEqualizer: () =>
                              setState(() => _showEqualizer = true),
                          showingEqualizer: _showEqualizer,
                        )
                      else
                        _MobileToolbar(
                          title: _title,
                          showBack: _route != '/home' && _route != '/search',
                          showSearch: tablet && _route != '/search',
                          onBack: _back,
                          onSearch: () => _go('/search'),
                          onMore: () => setState(() => _showMore = !_showMore),
                        ),
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 150),
                          child: _showEqualizer && nowPlaying
                              ? const WaveEqualizerPanel(
                                  key: ValueKey('mobile-equalizer'),
                                  embedded: true,
                                )
                              : _showMore && !nowPlaying
                                  ? _MorePage(
                                      key: const ValueKey('mobile-more'),
                                      onGo: _go,
                                    )
                                  : KeyedSubtree(
                                      key: ValueKey(widget.location),
                                      child: widget.child,
                                    ),
                        ),
                      ),
                      if (nowPlaying)
                        _MobileTransportDock(
                          snapshot: player,
                          onSeek: playback.seek,
                          onPrevious: playback.previous,
                          onToggle: playback.toggle,
                          onNext: playback.next,
                          onShuffle: playback.toggleShuffle,
                          onRepeat: playback.cycleRepeat,
                        )
                      else
                        _MobileMiniPlayer(
                          current: player.current,
                          isPlaying: player.isPlaying,
                          isBuffering: player.isBuffering,
                          onOpen: _openNowPlaying,
                          onToggle: player.current == null
                              ? null
                              : playback.toggle,
                          onNext: player.current == null ? null : playback.next,
                        ),
                      if (!tablet && !nowPlaying)
                        _PhoneNavigation(
                          activePath: activePath,
                          moreActive: moreActive,
                          onGo: _go,
                          onMore: () => setState(() => _showMore = !_showMore),
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

class _MobileToolbar extends StatelessWidget {
  final String title;
  final bool showBack;
  final bool showSearch;
  final VoidCallback onBack;
  final VoidCallback onSearch;
  final VoidCallback onMore;

  const _MobileToolbar({
    required this.title,
    required this.showBack,
    required this.showSearch,
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
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: WaveType.pageTitle.copyWith(fontSize: 22),
              ),
            ),
          ),
          if (showSearch)
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

class _NowPlayingToolbar extends StatelessWidget {
  final VoidCallback onBack;
  final VoidCallback onEqualizer;
  final bool showingEqualizer;

  const _NowPlayingToolbar({
    required this.onBack,
    required this.onEqualizer,
    required this.showingEqualizer,
  });

  @override
  Widget build(BuildContext context) => Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            _TouchIconButton(
              icon: WaveIcons.back,
              tooltip: showingEqualizer ? 'Back to Now Playing' : 'Back',
              onPressed: onBack,
            ),
            Expanded(
              child: Text(
                showingEqualizer ? 'Equalizer' : 'Now Playing',
                style: WaveType.trackTitle,
              ),
            ),
            if (!showingEqualizer)
              _TouchIconButton(
                icon: WaveIcons.equalizer,
                tooltip: 'Equalizer',
                onPressed: onEqualizer,
              ),
          ],
        ),
      );
}

class _TabletRail extends StatelessWidget {
  final String activePath;
  final bool moreActive;
  final void Function(String) onGo;
  final VoidCallback onMore;

  const _TabletRail({
    required this.activePath,
    required this.moreActive,
    required this.onGo,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 76,
      decoration: BoxDecoration(
        color: waveSurface(context),
        border: Border(right: BorderSide(color: waveDivider(context))),
      ),
      child: Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 46,
            height: 46,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: waveSurfaceRaised(context),
              borderRadius: BorderRadius.circular(13),
            ),
            child: const Icon(WaveIcons.music, size: 24),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 4),
              children: [
                for (final destination in _tabletDestinations)
                  _RailButton(
                    destination: destination,
                    selected: activePath == destination.path ||
                        activePath.startsWith('${destination.path}/'),
                    onTap: () => onGo(destination.path),
                  ),
              ],
            ),
          ),
          _TouchIconButton(
            icon: WaveIcons.more,
            tooltip: 'More destinations',
            selected: moreActive,
            onPressed: onMore,
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

class _RailButton extends StatelessWidget {
  final WaveDestination destination;
  final bool selected;
  final VoidCallback onTap;

  const _RailButton({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      child: Tooltip(
        message: destination.label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 130),
            width: 56,
            height: 52,
            decoration: BoxDecoration(
              color: selected
                  ? waveAccent(context).withValues(alpha: 0.14)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              border: selected
                  ? Border(
                      left: BorderSide(color: waveAccent(context), width: 3),
                    )
                  : null,
            ),
            child: Icon(
              destination.icon,
              size: 22,
              color: selected
                  ? waveTextPrimary(context)
                  : waveTextSecondary(context),
            ),
          ),
        ),
      ),
    );
  }
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
      height: 62,
      decoration: BoxDecoration(
        color: waveSurface(context),
        border: Border(top: BorderSide(color: waveDivider(context))),
      ),
      child: Row(
        children: [
          for (final destination in _phoneDestinations)
            Expanded(
              child: _PhoneTab(
                destination: destination,
                selected: activePath == destination.path ||
                    activePath.startsWith('${destination.path}/'),
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

class _MobileTransportDock extends StatefulWidget {
  final PlayerSnapshot snapshot;
  final Future<void> Function(Duration) onSeek;
  final Future<void> Function() onPrevious;
  final Future<void> Function() onToggle;
  final Future<void> Function() onNext;
  final Future<void> Function() onShuffle;
  final Future<void> Function() onRepeat;

  const _MobileTransportDock({
    required this.snapshot,
    required this.onSeek,
    required this.onPrevious,
    required this.onToggle,
    required this.onNext,
    required this.onShuffle,
    required this.onRepeat,
  });

  @override
  State<_MobileTransportDock> createState() => _MobileTransportDockState();
}

class _MobileTransportDockState extends State<_MobileTransportDock> {
  double? _dragMilliseconds;

  String _time(Duration value) {
    final minutes = value.inMinutes;
    final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final durationMs = widget.snapshot.duration.inMilliseconds;
    final maxMs = durationMs > 0 ? durationMs.toDouble() : 1.0;
    final positionMs = (_dragMilliseconds ??
            widget.snapshot.position.inMilliseconds.toDouble())
        .clamp(0.0, maxMs);

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
              Text(_time(Duration(milliseconds: positionMs.round())),
                  style: WaveType.meta),
              Expanded(
                child: Slider(
                  value: positionMs,
                  min: 0,
                  max: maxMs,
                  onChanged: durationMs <= 0
                      ? null
                      : (value) => setState(() => _dragMilliseconds = value),
                  onChangeEnd: durationMs <= 0
                      ? null
                      : (value) {
                          setState(() => _dragMilliseconds = null);
                          widget.onSeek(Duration(milliseconds: value.round()));
                        },
                ),
              ),
              Text(_time(widget.snapshot.duration), style: WaveType.meta),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _TouchIconButton(
                icon: WaveIcons.shuffle,
                tooltip: 'Shuffle',
                selected: widget.snapshot.shuffleEnabled,
                onPressed: widget.onShuffle,
              ),
              _TouchIconButton(
                icon: WaveIcons.previous,
                tooltip: 'Previous track',
                onPressed: widget.onPrevious,
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
                  onTap: widget.onToggle,
                  child: Icon(
                    widget.snapshot.isPlaying
                        ? WaveIcons.pause
                        : WaveIcons.play,
                    color: waveBackground(context),
                    size: 23,
                  ),
                ),
              ),
              _TouchIconButton(
                icon: WaveIcons.next,
                tooltip: 'Next track',
                onPressed: widget.onNext,
              ),
              _TouchIconButton(
                icon: WaveIcons.repeat,
                tooltip: 'Repeat mode',
                selected: widget.snapshot.repeatMode.name != 'off',
                onPressed: widget.onRepeat,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MobileMiniPlayer extends StatelessWidget {
  final PlayableTrack? current;
  final bool isPlaying;
  final bool isBuffering;
  final VoidCallback onOpen;
  final VoidCallback? onToggle;
  final VoidCallback? onNext;

  const _MobileMiniPlayer({
    required this.current,
    required this.isPlaying,
    required this.isBuffering,
    required this.onOpen,
    required this.onToggle,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    final track = current;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: track == null ? null : onOpen,
      child: Container(
        height: 66,
        margin: const EdgeInsets.fromLTRB(10, 7, 10, 7),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: waveSurfaceRaised(context),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: waveDivider(context)),
        ),
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
                  Text(
                    track?.title ?? 'Nothing playing',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: WaveType.trackTitle,
                  ),
                  Text(
                    track?.artist ?? 'Choose music from your library',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: WaveType.meta.copyWith(
                      color: waveTextSecondary(context),
                    ),
                  ),
                ],
              ),
            ),
            _TouchIconButton(
              icon: isBuffering
                  ? WaveIcons.music
                  : isPlaying
                      ? WaveIcons.pause
                      : WaveIcons.play,
              tooltip: isPlaying ? 'Pause' : 'Play',
              onPressed: onToggle,
            ),
            _TouchIconButton(
              icon: WaveIcons.next,
              tooltip: 'Next track',
              onPressed: onNext,
            ),
          ],
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

  const _TouchIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: SizedBox(
          width: 48,
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

class _MorePage extends StatelessWidget {
  final void Function(String) onGo;
  const _MorePage({super.key, required this.onGo});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
      children: [
        for (final destination in _moreDestinations)
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
                      child: Text(
                        destination.label,
                        style: WaveType.trackTitle,
                      ),
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
    );
  }
}
