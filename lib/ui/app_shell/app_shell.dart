import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

import '../../app/window.dart';
import '../../core/audio/stream_models.dart';
import '../../core/shortcuts/app_shortcuts.dart';
import '../../features/downloads/download_manager.dart';
import '../../features/library/playlists.dart';
import '../../features/player/playback_service.dart';
import '../../features/search/search_repository.dart';
import '../mini_player/mini_player.dart';
import '../components/infobar_host.dart';
import '../lyrics/lyrics_side_panel.dart';
import '../navigation/destinations.dart';
import '../navigation/side_rail.dart';
import '../player_dock/player_dock.dart';
import '../queue/queue_panel.dart';
import '../theme/tokens.dart';
import 'command_palette.dart';
import 'title_bar.dart';

/// Rebuilt desktop shell — THIS IS A MUSIC PLAYER.
///
/// ```
/// ┌─────────────────────────────────────────────┐
/// │ compact title / nav / search (44px)         │
/// ├────────┬────────────────────────────────────┤
/// │ compact│        MUSIC CONTENT               │
/// │ nav    │                                    │
/// ├────────┴────────────────────────────────────┤
/// │ PLAYBACK PLAYER (80px, one object)          │
/// └─────────────────────────────────────────────┘
/// ```
/// No permanent right panel. Queue slides over content when requested.
class WaveShell extends ConsumerStatefulWidget {
  final String location;
  final Widget child;
  const WaveShell({super.key, required this.location, required this.child});

  @override
  ConsumerState<WaveShell> createState() => _WaveShellState();
}

class _WaveShellState extends ConsumerState<WaveShell> {
  static const _mediaChannel = MethodChannel('lastwave/media_keys');

  // Boot collapsed: the overlay rail covers content when open, so it
  // starts shut (toggle via hamburger, auto-collapses on outside tap).
  bool _railExpanded = false;
  bool _queueOpen = false;
  bool _lyricsOpen = false;
  bool _miniOpen = false;
  bool _draggingFiles = false;
  late final TextEditingController _searchController;
  final FocusNode _searchFocus = FocusNode();
  // Root shell focus node. Sits inside the Shortcuts widget so that
  // key events always reach it after navigation or search dismissal.
  final FocusNode _shellFocus = FocusNode(debugLabel: 'WaveShell');
  final List<String> _backStack = [];
  final List<String> _forwardStack = [];
  bool _historyLocked = false;
  // Memoized slide-over panels: the content LayoutBuilder below re-runs on
  // every rail-animation tick (width animates 60<->200px), which would
  // otherwise reconstruct + rebuild both panels ~15x per toggle (queue =
  // full row list, lyrics = karaoke view). Same widget instance across
  // ticks => element update short-circuits, zero child builds. Queue has
  // no changing params (reads providers internally); lyrics is recreated
  // only on visibility flips (reopen refollows to the current line).
  Widget? _queuePanelCache;
  Widget? _lyricsPanelCache;
  bool _lyricsCacheVisible = false;
  // Memoized title bar (owns the search box + its TextField machinery):
  // the shell rebuilds on every navigation, which would otherwise
  // reconstruct the whole title bar each time. All inputs except the
  // back/forward ability are stable across navigations, so the cache
  // invalidates only when those flip (first nav, back/forward jumps).
  Widget? _titleBarCache;
  bool _titleCanBack = false;
  bool _titleCanForward = false;
  // Memoized dock (glyphs + cover art): same instance across
  // navigations so the element skips it. The toggle closures capture
  // route state (lyrics toggle branches on isLyrics), so the cache
  // key covers everything behaviorally relevant.
  Widget? _dockCache;
  bool _dockLyricsActive = false;
  bool _dockQueueActive = false;
  bool _dockIsLyrics = false;

  void _closeQueue() => setState(() => _queueOpen = false);
  void _closeLyrics() => setState(() => _lyricsOpen = false);

  /// Cached dock: same instance across navigations (glyphs + cover art
  /// skip reconstruction). Rebuilt only when a behaviorally relevant
  /// input flips.
  Widget _dockFor({
    required bool lyricsActive,
    required bool queueActive,
    required bool isLyrics,
  }) {
    if (_dockCache == null ||
        _dockLyricsActive != lyricsActive ||
        _dockQueueActive != queueActive ||
        _dockIsLyrics != isLyrics) {
      _dockLyricsActive = lyricsActive;
      _dockQueueActive = queueActive;
      _dockIsLyrics = isLyrics;
      // The dock is structural: reserves 80px on every view, including
      // Now Playing — its in-page transport was removed so this dock is
      // the single control surface.
      _dockCache = WavePlayerDock(
        onExpand: () => _go('/now'),
        lyricsActive: lyricsActive,
        queueActive: queueActive,
        onToggleMini: () => setState(() => _miniOpen = !_miniOpen),
        onToggleLyrics: () {
          if (isLyrics) {
            _go('/now');
          } else {
            setState(() {
              _lyricsOpen = !_lyricsOpen;
              if (_lyricsOpen) _queueOpen = false;
            });
          }
        },
        onToggleQueue: () => setState(() {
          _queueOpen = !_queueOpen;
          if (_queueOpen) _lyricsOpen = false;
        }),
      );
    }
    return _dockCache!;
  }

  /// Cached title bar: same instance across navigations so the element
  /// skips it (no search-box reconstruction). Rebuilt only when the
  /// back/forward ability flips.
  Widget _titleBarFor(bool canGoBack, bool canGoForward) {
    if (_titleBarCache == null ||
        _titleCanBack != canGoBack ||
        _titleCanForward != canGoForward) {
      _titleCanBack = canGoBack;
      _titleCanForward = canGoForward;
      _titleBarCache = WaveTitleBar(
        searchController: _searchController,
        searchFocus: _searchFocus,
        onSearchSubmit: _submitSearch,
        onPalette: _openPalette,
        onToggleRail: () => setState(() => _railExpanded = !_railExpanded),
        canGoBack: canGoBack,
        canGoForward: canGoForward,
        onBack: _goBack,
        onForward: _goForward,
      );
    }
    return _titleBarCache!;
  }

  /// Cached lyrics panel: recreated only when visibility flips so the
  /// LayoutBuilder ticks during rail animation reuse the same instance
  /// (no karaoke rebuilds). Reopen refollows to the current line.
  Widget _lyricsPanelFor(bool visible) {
    if (_lyricsPanelCache == null || _lyricsCacheVisible != visible) {
      _lyricsCacheVisible = visible;
      _lyricsPanelCache = WaveLyricsSidePanel(
        visible: visible,
        onClose: _closeLyrics,
      );
    }
    return _lyricsPanelCache!;
  }

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    // Restore shell focus after any navigation or panel change so that
    // the Shortcuts ancestor always sits in the active focus chain.
    // Only reclaims if nothing else inside the shell has primary focus
    // (e.g. a text field or list row).
    _shellFocus.addListener(_reclaimFocusIfOrphaned);

    _mediaChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'play_pause':
          ref.read(playbackServiceProvider.notifier).toggle();
          break;
        case 'next':
          ref.read(playbackServiceProvider.notifier).next();
          break;
        case 'previous':
          ref.read(playbackServiceProvider.notifier).previous();
          break;
      }
    });
  }

  void _reclaimFocusIfOrphaned() {
    // Called whenever _shellFocus changes. If it just lost focus and no
    // other meaningful node owns primary focus, take it back so Shortcuts
    // keeps receiving key events.
    if (_shellFocus.hasFocus) return;               // gained focus — fine
    if (!mounted) return;
    final primary = FocusManager.instance.primaryFocus;
    // If nothing has focus, reclaim immediately.
    if (primary == null) {
      _shellFocus.requestFocus();
      return;
    }
    // If an EditableText (search, dialogs, text rows) has focus, let it
    // keep it — _isTyping() will gate single-key shortcuts correctly.
    final ctx = primary.context;
    if (ctx == null) {
      _shellFocus.requestFocus();
      return;
    }
    if (ctx.widget is EditableText) return;
    if (ctx.findAncestorWidgetOfExactType<EditableText>() != null) return;
    if (ctx.findAncestorStateOfType<EditableTextState>() != null) return;
    if (ctx.findAncestorWidgetOfExactType<TextBox>() != null) return;
    // Non-text widget stole focus (list row, button, etc.). Reclaim so
    // Shortcuts still intercepts subsequent key events.
    _shellFocus.requestFocus();
  }

  @override
  void dispose() {
    _mediaChannel.setMethodCallHandler(null);
    _shellFocus.removeListener(_reclaimFocusIfOrphaned);
    _shellFocus.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(WaveShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.location == widget.location) return;
    _syncSearchField(widget.location);
    if (_historyLocked) {
      _historyLocked = false;
      return;
    }
    _backStack.add(oldWidget.location);
    if (_backStack.length > 50) _backStack.removeAt(0);
    _forwardStack.clear();
  }

  void _syncSearchField(String location) {
    if (!location.startsWith('/search')) {
      if (_searchController.text.isNotEmpty) {
        _searchController.clear();
      }
      if (_searchFocus.hasFocus) {
        _searchFocus.unfocus();
      }
      return;
    }
    if (_searchFocus.hasFocus) return;
    final q = Uri.splitQueryString(
          location.contains('?')
              ? location.substring(location.indexOf('?') + 1)
              : '',
        )['q'] ??
        '';
    if (_searchController.text != q) {
      _searchController.text = q;
    }
    
    // Ensure the input receives focus after the search UI is mounted
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_searchFocus.hasFocus) {
        _searchFocus.requestFocus();
      }
    });
  }

  void _applyRoute(String path) {
    setState(() {
      _queueOpen = false;
      _lyricsOpen = false;
    });
    if (path == widget.location) {
      _historyLocked = false;
      return;
    }
    context.go(path);
  }

  void _go(String path) {
    if (!path.startsWith('/search?')) {
      _searchController.clear();
      if (_searchFocus.hasFocus) _searchFocus.unfocus();
    }
    _applyRoute(path);
  }

  void _goBack() {
    while (_backStack.isNotEmpty) {
      final dest = _backStack.removeLast();
      if (dest == widget.location) continue;
      _forwardStack.add(widget.location);
      _historyLocked = true;
      setState(() {});
      _applyRoute(dest);
      return;
    }
  }

  void _goForward() {
    while (_forwardStack.isNotEmpty) {
      final dest = _forwardStack.removeLast();
      if (dest == widget.location) continue;
      _backStack.add(widget.location);
      _historyLocked = true;
      setState(() {});
      _applyRoute(dest);
      return;
    }
  }

  void _submitSearch(String value) {
    final q = value.trim();
    if (q.isEmpty) {
      _openPalette();
      return;
    }
    ref.read(searchRepositoryProvider).pushHistory(q);
    setState(() {
      _queueOpen = false;
      _lyricsOpen = false;
    });
    context.go('/search?q=${Uri.encodeComponent(q)}');
    _searchFocus.unfocus();
  }

  void _openPalette() {
    final history = ref.read(searchRepositoryProvider).history();
    showWaveCommandPalette(
      context,
      recentSearches: history.take(6).toList(),
      onSearch: (q) {
        ref.read(searchRepositoryProvider).pushHistory(q);
        context.go('/search?q=${Uri.encodeComponent(q)}');
      },
      onGo: _go,
    );
  }

  void _togglePlay() {
    ref.read(playbackServiceProvider.notifier).toggle();
  }

  bool _isTyping() {
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null) return false;
    final ctx = focus.context;
    if (ctx == null) return false;
    if (ctx.widget is EditableText) return true;
    if (ctx.findAncestorWidgetOfExactType<EditableText>() != null) return true;
    if (ctx.findAncestorStateOfType<EditableTextState>() != null) return true;
    if (ctx.findAncestorWidgetOfExactType<TextBox>() != null) return true;
    final debugLabel = focus.debugLabel;
    if (debugLabel != null && debugLabel.contains('EditableText')) return true;
    return false;
  }

  Future<void> _dropFiles(List<String> paths) async {
    final tracks = <PlayableTrack>[];
    for (final path in paths) {
      final file = File(path);
      if (!await file.exists()) continue;
      final ext = path.split('.').last.toLowerCase();
      if (![
        'mp3',
        'flac',
        'm4a',
        'mp4',
        'ogg',
        'opus',
        'wav',
        'webm'
      ].contains(ext)) {
        continue;
      }
      final base = path
          .split(Platform.pathSeparator)
          .last
          .replaceAll(RegExp(r'\.\w+$'), '');
      final parts = base.split(' - ');
      tracks.add(PlayableTrack(
        title: parts.length > 1 ? parts.sublist(1).join(' - ') : base,
        artist: parts.length > 1 ? parts.first : 'Local file',
        playbackUrl: path,
      ));
    }
    if (tracks.isEmpty || !mounted) return;
    await ref
        .read(playbackServiceProvider.notifier)
        .playQueue(tracks, 0, sourceLabel: 'Local files');
  }

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final width = MediaQuery.sizeOf(context).width;
    final active = waveActivePath(widget.location);
    final hasTrack = ref.watch(
      playbackServiceProvider.select((s) => s.current != null),
    );
    // Responsive: rail collapses at canonical compact breakpoint (900),
    // never a permanent right panel.
    final collapsed = width < 900 ? true : !_railExpanded;
    final routePath = waveRoutePath(widget.location);
    final isLyrics = routePath.startsWith('/lyrics');
    final isNowPlaying = routePath.startsWith('/now');

    return Shortcuts(
      shortcuts: {
        AppShortcuts.activator(AppShortcut.playPause): const PlayPauseIntent(),
        AppShortcuts.activator(AppShortcut.next): const NextTrackIntent(),
        AppShortcuts.activator(AppShortcut.previous): const PreviousTrackIntent(),
        AppShortcuts.activator(AppShortcut.like): const LikeTrackIntent(),
        AppShortcuts.activator(AppShortcut.fullscreen): const FullscreenIntent(),
        AppShortcuts.activator(AppShortcut.download): const DownloadTrackIntent(),
        AppShortcuts.activator(AppShortcut.queue): const QueueIntent(),
        AppShortcuts.activator(AppShortcut.search): const SearchIntent(),
        AppShortcuts.activator(AppShortcut.downloads): const DownloadsIntent(),
        AppShortcuts.activator(AppShortcut.sleepTimer): const SleepTimerIntent(),
        AppShortcuts.activator(AppShortcut.playlists): const PlaylistsIntent(),
        AppShortcuts.activator(AppShortcut.lyrics): const LyricsIntent(),
        AppShortcuts.activator(AppShortcut.commandPalette): const CommandPaletteIntent(),
      },
      child: Actions(
        actions: {
          PlayPauseIntent: _WaveAction<PlayPauseIntent>(
            singleKey: true,
            isTyping: _isTyping,
            onInvokeCallback: () {
              if (hasTrack) _togglePlay();
            },
          ),
          NextTrackIntent: _WaveAction<NextTrackIntent>(
            singleKey: true,
            isTyping: _isTyping,
            onInvokeCallback: () {
              ref.read(playbackServiceProvider.notifier).next();
            },
          ),
          PreviousTrackIntent: _WaveAction<PreviousTrackIntent>(
            singleKey: true,
            isTyping: _isTyping,
            onInvokeCallback: () {
              ref.read(playbackServiceProvider.notifier).previous();
            },
          ),
          LikeTrackIntent: _WaveAction<LikeTrackIntent>(
            singleKey: true,
            isTyping: _isTyping,
            onInvokeCallback: () {
              final track = ref.read(playbackServiceProvider).current;
              if (track != null) {
                ref.read(playlistRepositoryProvider.notifier).toggleLiked(
                  StoredTrack(
                    name: track.title,
                    artist: track.artist,
                    artworkUrl: track.artworkUrl,
                    videoId: track.videoId,
                  ),
                );
              }
            },
          ),
          FullscreenIntent: _WaveAction<FullscreenIntent>(
            singleKey: true,
            isTyping: _isTyping,
            onInvokeCallback: () {
              _go('/now');
            },
          ),
          DownloadTrackIntent: _WaveAction<DownloadTrackIntent>(
            singleKey: true,
            isTyping: _isTyping,
            onInvokeCallback: () {
              final track = ref.read(playbackServiceProvider).current;
              if (track != null) {
                ref.read(downloadManagerProvider.notifier).downloadTrack(
                  title: track.title,
                  artist: track.artist,
                  album: track.album,
                  artworkUrl: track.artworkUrl,
                );
              }
            },
          ),
          QueueIntent: _WaveAction<QueueIntent>(
            singleKey: true,
            isTyping: _isTyping,
            onInvokeCallback: () {
              setState(() {
                _queueOpen = !_queueOpen;
                if (_queueOpen) _lyricsOpen = false;
              });
            },
          ),
          SearchIntent: _WaveAction<SearchIntent>(
            singleKey: true,
            isTyping: _isTyping,
            onInvokeCallback: () {
              if (!widget.location.startsWith('/search')) {
                _go('/search');
              } else {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _searchFocus.requestFocus();
                });
              }
            },
          ),
          DownloadsIntent: _WaveAction<DownloadsIntent>(
            isTyping: _isTyping,
            onInvokeCallback: () => _go('/downloads'),
          ),
          SleepTimerIntent: _WaveAction<SleepTimerIntent>(
            isTyping: _isTyping,
            onInvokeCallback: () {
              final notifier = ref.read(playbackServiceProvider.notifier);
              if (ref.read(playbackServiceProvider).sleepRemaining != null) {
                notifier.setSleepTimer(null);
              } else {
                notifier.setSleepTimer(const Duration(minutes: 30));
              }
            },
          ),
          PlaylistsIntent: _WaveAction<PlaylistsIntent>(
            isTyping: _isTyping,
            onInvokeCallback: () => _go('/playlists'),
          ),
          LyricsIntent: _WaveAction<LyricsIntent>(
            isTyping: _isTyping,
            onInvokeCallback: () {
              if (hasTrack) {
                setState(() {
                  _lyricsOpen = !_lyricsOpen;
                  if (_lyricsOpen) _queueOpen = false;
                });
              }
            },
          ),
          CommandPaletteIntent: _WaveAction<CommandPaletteIntent>(
            isTyping: _isTyping,
            onInvokeCallback: _openPalette,
          ),
        },
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true):
                _goBack,
            const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true):
                _goForward,
            const SingleActivator(LogicalKeyboardKey.escape): () {
              if (_searchFocus.hasFocus) {
                _searchFocus.unfocus();
              } else if (_lyricsOpen) {
                setState(() => _lyricsOpen = false);
              } else if (_queueOpen) {
                setState(() => _queueOpen = false);
              } else if (_miniOpen) {
                setState(() => _miniOpen = false);
              } else if (!collapsed) {
                // Overlay rail light-dismisses via keyboard too.
                setState(() => _railExpanded = false);
              } else if (isNowPlaying) {
                if (context.canPop()) {
                  context.pop();
                } else {
                  context.go('/home');
                }
              }
            },
          },
          child: Focus(
            focusNode: _shellFocus,
            autofocus: true,
            child: Mica(
          backgroundColor:
              dark ? WaveColors.background : WaveColors.lightBackground,
          child: Column(
            children: [
              _titleBarFor(
                _backStack.isNotEmpty,
                _forwardStack.isNotEmpty,
              ),
              const WaveInfoBarHost(),
              // Overlay rail: the content below keeps full width and the
              // rail floats above its left edge (60 collapsed, 200
              // expanded). Toggling used to reflow the whole window, so
              // every animation frame re-laid-out every page + panel.
              // Now constraints stay constant during the animation and
              // only the tiny rail subtree lays out per tick.
              Expanded(
                child: Column(
                  children: [
                    Expanded(
                      child: DropTarget(
                              onDragEntered: (_) => setState(
                                  () => _draggingFiles = true),
                              onDragExited: (_) => setState(
                                  () => _draggingFiles = false),
                              onDragDone: (details) {
                                setState(
                                    () => _draggingFiles = false);
                                _dropFiles(details.files
                                    .map((f) => f.path)
                                    .toList());
                              },
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  final qw = (constraints.maxWidth * 0.9)
                                      .clamp(280.0, 360.0)
                                      .toDouble();
                                  final lw = (constraints.maxWidth * 0.46)
                                      .clamp(460.0, 720.0)
                                      .toDouble();
                                  final showOverlay =
                                      _queueOpen || (_lyricsOpen && hasTrack);
                                  final lyricsOnly =
                                      _lyricsOpen && hasTrack && !_queueOpen;

                                  return Stack(
                                    children: [
                                      // Page reserves the collapsed rail
                                      // strip; the rail floats above it.
                                      Positioned.fill(
                                        left: WaveDensity.railCollapsed,
                                        child: widget.child,
                                      ),
                                      // Light-dismiss: tapping outside the
                                      // expanded rail collapses it (tap is
                                      // absorbed, content doesn't activate).
                                      // Below the rail + panels, so those
                                      // keep working while it is open.
                                      if (!collapsed)
                                        Positioned.fill(
                                          child: ExcludeSemantics(
                                            child: GestureDetector(
                                              behavior: HitTestBehavior
                                                  .translucent,
                                              onTap: () => setState(() =>
                                                  _railExpanded = false),
                                              child:
                                                  const SizedBox.expand(),
                                            ),
                                          ),
                                        ),
                                      // Overlay rail: width animates
                                      // internally; content constraints
                                      // stay constant, so nothing reflows
                                      // or rebuilds during the animation.
                                      Positioned(
                                        left: 0,
                                        top: 0,
                                        bottom: 0,
                                        child: WaveSideRail(
                                          expanded: !collapsed,
                                          active: active,
                                          onGo: _go,
                                        ),
                                      ),
                                      if (_draggingFiles)
                                        Positioned.fill(
                                          child: Container(
                                            color: Colors.black
                                                .withValues(alpha: 0.4),
                                            child: const Center(
                                              child: Text(
                                                'Drop audio files to play',
                                                style: WaveType.sectionTitle,
                                              ),
                                            ),
                                          ),
                                        ),
                                      // Dim only the page beside the drawer so
                                      // the lyrics panel can frost the artwork.
                                      // Starts past the rail (which is never
                                      // dimmed) — the rail floats above.
                                      Positioned(
                                        left: WaveDensity.railCollapsed,
                                        top: 0,
                                        bottom: 0,
                                        right: showOverlay
                                            ? (_queueOpen ? qw : lw)
                                            : 0,
                                        child: IgnorePointer(
                                          ignoring: !showOverlay,
                                          child: AnimatedOpacity(
                                            duration: WaveMotion.normal,
                                            curve: Curves.easeOutCubic,
                                            opacity: showOverlay ? 1.0 : 0.0,
                                            child: GestureDetector(
                                              onTap: () => setState(() {
                                                _queueOpen = false;
                                                _lyricsOpen = false;
                                              }),
                                              child: Container(
                                                color: Colors.black
                                                    .withValues(
                                                        alpha: lyricsOnly
                                                            ? 0.10
                                                            : 0.45),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      // Contextual queue — slides smoothly from right.
                                      AnimatedPositioned(
                                        duration: WaveMotion.normal,
                                        curve: Curves.easeOutCubic,
                                        top: 0,
                                        bottom: 0,
                                        right: _queueOpen ? 0 : -(qw + 12),
                                        width: qw,
                                        child: ExcludeFocus(
                                          excluding: !_queueOpen,
                                          child: IgnorePointer(
                                            ignoring: !_queueOpen,
                                            // Offstage when slid shut: the 8-row
                                            // list (images, menus, tooltips)
                                            // skips paint/raster entirely, so
                                            // every page navigation no longer
                                            // rasterizes a hidden panel.
                                            // Layout still runs (cheap box
                                            // math); scroll offset is kept.
                                            child: Offstage(
                                              offstage: !_queueOpen,
                                              child: _queuePanelCache ??=
                                                  WaveQueuePanel(
                                                onClose: _closeQueue,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      // Contextual Apple Music Karaoke Lyrics drawer — slides smoothly from right.
                                      AnimatedPositioned(
                                        duration: WaveMotion.normal,
                                        curve: Curves.easeOutCubic,
                                        top: 0,
                                        bottom: 0,
                                        right: (_lyricsOpen && hasTrack)
                                            ? 0
                                            : -(lw + 12),
                                        width: lw,
                                        child: ExcludeFocus(
                                          excluding: !(_lyricsOpen && hasTrack),
                                          child: IgnorePointer(
                                            ignoring: !(_lyricsOpen && hasTrack),
                                        child: Offstage(
                                          // See queue panel above: skips
                                          // rasterizing the hidden karaoke
                                          // view on every navigation.
                                          // TickerMode mutes the karaoke
                                          // ticker itself while shut: it
                                          // would otherwise fire 30Hz
                                          // setStates into an off-screen
                                          // layer on every page. Resumes
                                          // transparently (position resyncs).
                                          offstage:
                                              !(_lyricsOpen && hasTrack),
                                          child: TickerMode(
                                            enabled:
                                                _lyricsOpen && hasTrack,
                                            child: _lyricsPanelFor(
                                                _lyricsOpen && hasTrack),
                                          ),
                                        ),
                                          ),
                                        ),
                                      ),
                                      // Mini player — floats ABOVE the dock.
                                      if (_miniOpen && hasTrack)
                                        Positioned(
                                          right: 16,
                                          bottom: 16,
                                          child: WaveMiniPlayer(
                                            onClose: () => setState(
                                                () => _miniOpen = false),
                                            onExpand: () {
                                              setState(
                                                  () => _miniOpen = false);
                                              _go('/now');
                                            },
                                          ),
                                        ),
                                    ],
                                  );
                                },
                              ),
                            ),
                          ),
                          _dockFor(
                            lyricsActive: _lyricsOpen || isLyrics,
                            queueActive: _queueOpen,
                            isLyrics: isLyrics,
                          ),
                        ],
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

class _WaveAction<T extends Intent> extends Action<T> {
  final void Function() onInvokeCallback;
  final bool Function() isTyping;
  final bool singleKey;

  _WaveAction({
    required this.onInvokeCallback,
    required this.isTyping,
    this.singleKey = false,
  });

  @override
  bool isEnabled(covariant T intent) {
    if (singleKey && isTyping()) return false;
    return true;
  }

  @override
  Object? invoke(covariant T intent) {
    onInvokeCallback();
    return null;
  }
}
