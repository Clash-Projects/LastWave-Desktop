import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../../app/window.dart';
import '../../app/window_lifecycle.dart';
import '../../core/audio/stream_models.dart';
import '../../features/equalizer/equalizer_panel.dart';
import '../../features/player/playback_service.dart';
import '../../features/search/search_repository.dart';
import '../mini_player/mini_player.dart';
import '../components/infobar_host.dart';
import '../lyrics/lyrics_side_panel.dart';
import '../navigation/destinations.dart';
import '../navigation/route_origin.dart';
import '../navigation/side_rail.dart';
import '../navigation/wave_nav.dart';
import '../player_dock/player_dock.dart';
import '../queue/queue_panel.dart';
import '../theme/tokens.dart';
import '../updates/update_dialog.dart';
import '../../core/storage/prefs.dart';
import '../../features/updates/update_service.dart';
import 'command_palette.dart';
import 'title_bar.dart';
import 'wave_hotkeys.dart';

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

/// Drawer lyrics gate: Offstage skips raster while shut; TickerMode mutes
/// the karaoke ticker while shut OR while the window is minimized.
/// Side-by-side (unfocused but visible) keeps ticking. Single gate on
/// purpose (nested TickerModes don't AND — nearest wins — so nothing may
/// add an inner gate inside the side panel). Scoped ConsumerWidget so
/// visibility flips rebuild only this leaf, never the shell.
class _DrawerTicker extends ConsumerWidget {
  final bool open;
  final Widget child;
  const _DrawerTicker({required this.open, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visible = ref.watch(windowVisibleProvider);
    return Offstage(
      offstage: !open,
      child: TickerMode(
        enabled: open && visible,
        child: child,
      ),
    );
  }
}

class _WaveShellState extends ConsumerState<WaveShell> {
  // Boot collapsed: the overlay rail covers content when open, so it
  // starts shut (toggle via hamburger, auto-collapses on outside tap).
  bool _railExpanded = false;
  bool _queueOpen = false;
  bool _lyricsOpen = false;
  bool _equalizerOpen = false;
  bool _miniOpen = false;
  bool _draggingFiles = false;

  Size? _savedWindowSize;
  Offset? _savedWindowPos;
  bool _savedWasMaximized = false;
  Offset? _lastMiniPos;

  Future<void> _checkUpdatesOnLaunch() async {
    // Non-blocking delay after launch so the initial UI renders seamlessly
    await Future<void>.delayed(const Duration(seconds: 3));
    if (!mounted) return;

    try {
      final update = await ref.read(updateServiceProvider).checkForUpdate();
      if (update == null || !mounted) return;

      final prefs = ref.read(prefsProvider);
      // If user selected "Don't show again" for this version, skip automatic popup
      if (prefs.ignoredUpdateVersion == update.version) {
        return;
      }

      await showUpdateDialog(context, update, isManualCheck: false);
    } catch (_) {}
  }

  void _toggleMiniPlayer() {
    if (_miniOpen) {
      _exitMiniPlayer();
    } else {
      _enterMiniPlayer();
    }
  }

  Future<void> _enterMiniPlayer() async {
    final hasTrack =
        ref.read(playbackServiceProvider.select((s) => s.current != null));
    if (!hasTrack) return;

    try {
      _savedWasMaximized = await windowManager.isMaximized();
      if (_savedWasMaximized) {
        await windowManager.unmaximize();
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
      _savedWindowSize = await windowManager.getSize();
      _savedWindowPos = await windowManager.getPosition();
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      _miniOpen = true;
      _queueOpen = false;
      _lyricsOpen = false;
      _equalizerOpen = false;
    });

    try {
      await windowManager.setMinimumSize(const Size(300, 64));
      const miniSize = Size(380, 78);
      await windowManager.setSize(miniSize);
      if (_lastMiniPos != null) {
        await windowManager.setPosition(_lastMiniPos!);
      } else if (_savedWindowPos != null && _savedWindowSize != null) {
        final targetX = _savedWindowPos!.dx +
            (_savedWindowSize!.width - miniSize.width - 24);
        final targetY = _savedWindowPos!.dy +
            (_savedWindowSize!.height - miniSize.height - 24);
        await windowManager.setPosition(Offset(
          targetX.clamp(10.0, 10000.0),
          targetY.clamp(10.0, 10000.0),
        ));
      }
      await windowManager.setAlwaysOnTop(true);
    } catch (_) {}
  }

  Future<void> _exitMiniPlayer({bool expand = false}) async {
    if (!_miniOpen) return;

    try {
      _lastMiniPos = await windowManager.getPosition();
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      _miniOpen = false;
    });

    try {
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setMinimumSize(const Size(1024, 640));
      if (_savedWasMaximized) {
        await windowManager.maximize();
      } else {
        final restoreSize = _savedWindowSize ?? const Size(1360, 860);
        final restorePos = _savedWindowPos;
        if (restorePos != null) {
          await windowManager.setPosition(restorePos);
        }
        await windowManager.setSize(restoreSize);
      }
    } catch (_) {}

    if (expand) {
      _go('/now');
    }
  }
  late final TextEditingController _searchController;
  final FocusNode _searchFocus = FocusNode();
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
  Widget? _equalizerPanelCache;
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
  bool _dockEqualizerActive = false;
  bool _dockIsLyrics = false;

  void _closeQueue() => setState(() => _queueOpen = false);
  void _closeLyrics() => setState(() => _lyricsOpen = false);
  void _closeEqualizer() => setState(() => _equalizerOpen = false);

  /// Cached dock: same instance across navigations (glyphs + cover art
  /// skip reconstruction). Rebuilt only when a behaviorally relevant
  /// input flips.
  Widget _dockFor({
    required bool lyricsActive,
    required bool queueActive,
    required bool equalizerActive,
    required bool isLyrics,
  }) {
    if (_dockCache == null ||
        _dockLyricsActive != lyricsActive ||
        _dockQueueActive != queueActive ||
        _dockEqualizerActive != equalizerActive ||
        _dockIsLyrics != isLyrics) {
      _dockLyricsActive = lyricsActive;
      _dockQueueActive = queueActive;
      _dockEqualizerActive = equalizerActive;
      _dockIsLyrics = isLyrics;
      // The dock is structural: reserves 80px on every view, including
      // Now Playing — its in-page transport was removed so this dock is
      // the single control surface.
      _dockCache = WavePlayerDock(
        onExpand: _openNowPlaying,
        lyricsActive: lyricsActive,
        queueActive: queueActive,
        equalizerActive: equalizerActive,
        onToggleMini: _toggleMiniPlayer,
        onToggleLyrics: () {
          if (isLyrics) {
            _go('/now');
          } else {
            setState(() {
              _lyricsOpen = !_lyricsOpen;
              if (_lyricsOpen) {
                _queueOpen = false;
                _equalizerOpen = false;
              }
            });
          }
        },
        onToggleQueue: () => setState(() {
          _queueOpen = !_queueOpen;
          if (_queueOpen) {
            _lyricsOpen = false;
            _equalizerOpen = false;
          }
        }),
        onToggleEqualizer: () => setState(() {
          _equalizerOpen = !_equalizerOpen;
          if (_equalizerOpen) {
            _queueOpen = false;
            _lyricsOpen = false;
          }
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
    // Global hotkeys → playback. Re-registers the window.dart bindings
    // with Riverpod-aware handlers (HotKeyManager stores per-identifier
    // handlers, so re-register overwrites the no-op placeholders).
    _wireHotkeys();
    // Truly global in-app shortcuts: HardwareKeyboard fires before focus
    // dispatch, so Space/arrows can't be eaten by the focused button or
    // list (see wave_hotkeys.dart).
    HardwareKeyboard.instance.addHandler(_onGlobalKey);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkUpdatesOnLaunch();
    });
  }

  /// OS-level hotkeys are background-only: the in-app global handler (§
  /// _onGlobalKey) already toggles while the window is focused, so the OS
  /// handler must stand down then or every press would fire twice.
  Future<bool> _windowFocused() async {
    try {
      return await windowManager.isFocused();
    } catch (_) {
      return false;
    }
  }

  bool _onGlobalKey(KeyEvent event) {
    if (!mounted) return false;
    return handleWaveHotkey(
      event,
      WaveHotkeyActions(
        isTyping: () => waveIsTypingFocused(_searchFocus),
        hasTrack: () =>
            ref.read(playbackServiceProvider).current != null,
        togglePlay: () {
          if (mounted) ref.read(playbackServiceProvider.notifier).toggle();
        },
        next: () {
          if (mounted) ref.read(playbackServiceProvider.notifier).next();
        },
        previous: () {
          if (mounted) ref.read(playbackServiceProvider.notifier).previous();
        },
        openPalette: () {
          if (mounted) _openPalette();
        },
        focusSearch: () => _searchFocus.requestFocus(),
        toggleLyrics: () {
          if (!mounted) return;
          setState(() {
            _lyricsOpen = !_lyricsOpen;
            if (_lyricsOpen) _queueOpen = false;
          });
        },
        goBack: () {
          if (mounted) _goBack();
        },
        goForward: () {
          if (mounted) _goForward();
        },
        handleEscape: () {
          if (!mounted) return false;
          return _handleEscape();
        },
        seekBySeconds: _seekBySeconds,
        volumeByDelta: _volumeByDelta,
      ),
    );
  }

  /// Esc priority chain. Returns true when something was closed/unfocused.
  bool _handleEscape() {
    if (_searchFocus.hasFocus) {
      _searchFocus.unfocus();
      return true;
    } else if (_equalizerOpen) {
      setState(() => _equalizerOpen = false);
      return true;
    } else if (_lyricsOpen) {
      setState(() => _lyricsOpen = false);
      return true;
    } else if (_queueOpen) {
      setState(() => _queueOpen = false);
      return true;
    } else if (_miniOpen) {
      _exitMiniPlayer();
      return true;
    } else if (_lastCollapsed == false) {
      // Overlay rail light-dismisses via keyboard too.
      setState(() => _railExpanded = false);
      return true;
    } else if (_lastIsNowPlaying) {
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/home');
      }
      return true;
    }
    return false;
  }

  void _seekBySeconds(int delta) {
    if (!mounted) return;
    final snap = ref.read(playbackServiceProvider);
    if (snap.current == null) return;
    final target = snap.position + Duration(seconds: delta);
    final clamped = target.isNegative
        ? Duration.zero
        : (target > snap.duration ? snap.duration : target);
    ref.read(playbackServiceProvider.notifier).seek(clamped);
  }

  void _volumeByDelta(double delta) {
    if (!mounted) return;
    final snap = ref.read(playbackServiceProvider);
    if (snap.current == null) return;
    final v = (snap.volume + delta).clamp(0.0, 1.0);
    ref.read(playbackServiceProvider.notifier).setVolume(v);
  }

  Future<void> _wireHotkeys() async {
    // No global backend on Wayland — the in-app global handler covers
    // these combos while the window is focused instead.
    if (!globalHotkeysSupported) return;
    try {
      Future<void> toggle(HotKey _) async {
        if (!mounted) return;
        if (await _windowFocused()) return;
        await ref.read(playbackServiceProvider.notifier).toggle();
      }

      Future<void> next(HotKey _) async {
        if (!mounted) return;
        if (await _windowFocused()) return;
        await ref.read(playbackServiceProvider.notifier).next();
      }

      Future<void> prev(HotKey _) async {
        if (!mounted) return;
        if (await _windowFocused()) return;
        await ref.read(playbackServiceProvider.notifier).previous();
      }

      await hotKeyManager.register(
        HotKey(
          key: PhysicalKeyboardKey.keyP,
          modifiers: [HotKeyModifier.control, HotKeyModifier.alt],
          identifier: 'lastwave-toggle',
        ),
        keyDownHandler: toggle,
      );
      await hotKeyManager.register(
        HotKey(
          key: PhysicalKeyboardKey.keyN,
          modifiers: [HotKeyModifier.control, HotKeyModifier.alt],
          identifier: 'lastwave-next',
        ),
        keyDownHandler: next,
      );
      await hotKeyManager.register(
        HotKey(
          key: PhysicalKeyboardKey.keyB,
          modifiers: [HotKeyModifier.control, HotKeyModifier.alt],
          identifier: 'lastwave-prev',
        ),
        keyDownHandler: prev,
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onGlobalKey);
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
  }

  int? _branchForPath(String path) {
    final clean = path.split('?').first;
    if (clean == '/home' || clean.startsWith('/home/')) return 0;
    if (clean == '/stats' || clean.startsWith('/stats/') || clean == '/discover') return 1;
    if (clean == '/search' || clean.startsWith('/search/')) return 2;
    if (clean == '/liked' || clean.startsWith('/liked/')) return 3;
    if (clean == '/albums' || clean.startsWith('/albums/') || clean.startsWith('/album/')) return 4;
    if (clean == '/artists' || clean.startsWith('/artists/') || clean.startsWith('/artist/')) return 5;
    if (clean == '/playlists' || clean.startsWith('/playlists/') || clean.startsWith('/ytplaylist/')) return 6;
    if (clean == '/downloads' || clean.startsWith('/downloads/')) return 7;
    return null;
  }

  void _applyRoute(String path) {
    setState(() {
      _queueOpen = false;
      _lyricsOpen = false;
      _equalizerOpen = false;
    });
    if (path == widget.location) {
      _historyLocked = false;
      return;
    }
    final branchIndex = _branchForPath(path);
    if (branchIndex != null && widget.child is StatefulNavigationShell) {
      final shell = widget.child as StatefulNavigationShell;
      shell.goBranch(
        branchIndex,
        initialLocation: branchIndex == shell.currentIndex,
      );
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

  /// Opens Now Playing *on top* of the current page, so the page the user was
  /// on is still underneath when it crossfades closed over it (see waveOpen).
  void _openNowPlaying() {
    // Already there (the dock is on every view, Now Playing included).
    if (widget.location.startsWith('/now')) return;
    if (_searchFocus.hasFocus) _searchFocus.unfocus();
    _searchController.clear();
    setState(() {
      _miniOpen = false;
      _queueOpen = false;
      _lyricsOpen = false;
    });
    waveOpen(context, '/now');
  }

  void _goBack() {
    // A page that was opened on top of another (an album, an artist, a
    // playlist) closes back over the surface it grew out of — the reverse of
    // its entrance. Location history is only replayed once there is nothing
    // left to pop. Mirror it into forward history so the pair stays symmetric.
    if (context.canPop()) {
      _forwardStack.add(widget.location);
      _historyLocked = true;
      context.pop();
      return;
    }
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
      _equalizerOpen = false;
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

  /// Latest layout/route snapshot for the focus-independent Esc chain
  /// (the global key handler outlives individual builds, so it reads
  /// these fields instead of capturing stale build locals).
  bool _lastCollapsed = true;
  bool _lastIsNowPlaying = false;

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

    // Snapshot for the focus-independent Esc chain (the global
    // HardwareKeyboard handler reads these fields).
    _lastCollapsed = collapsed;
    _lastIsNowPlaying = isNowPlaying;

    if (_miniOpen) {
      return Mica(
        backgroundColor: waveBackground(context),
        child: WaveMiniPlayer(
          onClose: () => _exitMiniPlayer(),
          onExpand: () => _exitMiniPlayer(expand: true),
        ),
      );
    }

    // NOTE: no CallbackShortcuts / Focus(onKeyEvent) wrapper here on
    // purpose. Those only fire via focus-bubbling, so focused buttons and
    // lists ate Space/arrows before the shell saw them. All app-wide keys
    // live in the HardwareKeyboard handler (see initState/_onGlobalKey +
    // wave_hotkeys.dart), which runs before focus dispatch and works from
    // anywhere. Enter is deliberately left to focused controls.
    return Mica(
          backgroundColor: waveBackground(context),
          // Single pointer observer for the whole chrome. Route
          // transitions anchor at wherever the user last released the
          // pointer (see WaveRouteOrigin): one Listener here beats a global
          // key per card, translucent keeps it out of the hit-test verdict,
          // and pointer-up is dispatched before the gesture arena resolves
          // the tap, so the anchor is always in place for the navigation it
          // caused.
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerUp: (event) => WaveRouteOrigin.record(event.position),
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
                                  final ew = (constraints.maxWidth * 0.52)
                                      .clamp(440.0, 560.0)
                                      .toDouble();
                                  final showOverlay =
                                      _queueOpen ||
                                      _equalizerOpen ||
                                      (_lyricsOpen && hasTrack);
                                  final lyricsOnly =
                                      _lyricsOpen &&
                                      hasTrack &&
                                      !_queueOpen &&
                                      !_equalizerOpen;

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
                                            ? (_queueOpen
                                                ? qw
                                                : (_equalizerOpen ? ew : lw))
                                            : 0,
                                        child: IgnorePointer(
                                          ignoring: !showOverlay,
                                          child: AnimatedOpacity(
                                            duration: waveMotion(context, WaveMotion.normal),
                                            curve: Curves.easeOutCubic,
                                            opacity: showOverlay ? 1.0 : 0.0,
                                            child: GestureDetector(
                                              onTap: () => setState(() {
                                                _queueOpen = false;
                                                _lyricsOpen = false;
                                                _equalizerOpen = false;
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
                                        duration: waveMotion(context, WaveMotion.normal),
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
                                      // Contextual Equalizer & Studio Master Clarity drawer — slides smoothly from right.
                                      AnimatedPositioned(
                                        duration: waveMotion(
                                            context, WaveMotion.normal),
                                        curve: Curves.easeOutCubic,
                                        top: 0,
                                        bottom: 0,
                                        right: _equalizerOpen ? 0 : -(ew + 12),
                                        width: ew,
                                        child: ExcludeFocus(
                                          excluding: !_equalizerOpen,
                                          child: IgnorePointer(
                                            ignoring: !_equalizerOpen,
                                            child: Offstage(
                                              offstage: !_equalizerOpen,
                                              child: _equalizerPanelCache ??=
                                                  WaveEqualizerPanel(
                                                onClose: _closeEqualizer,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      // Contextual Apple Music Karaoke Lyrics drawer — slides smoothly from right.
                                      AnimatedPositioned(
                                        duration: waveMotion(context, WaveMotion.normal),
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
                                        child: _DrawerTicker(
                                          // See queue panel above: skips
                                          // rasterizing the hidden karaoke
                                          // view on every navigation.
                                          // Mutes the karaoke ticker while
                                          // shut or unfocused: it would
                                          // otherwise fire 30Hz into an
                                          // off-screen or invisible layer.
                                          // Resumes transparently
                                          // (position resyncs).
                                          open: _lyricsOpen && hasTrack,
                                          child: _lyricsPanelFor(
                                              _lyricsOpen && hasTrack),
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
                          _dockFor(
                            lyricsActive: _lyricsOpen || isLyrics,
                            queueActive: _queueOpen,
                            equalizerActive: _equalizerOpen,
                            isLyrics: isLyrics,
                          ),
                        ],
                      ),
                    ),
            ],
          ),
          ),
        );
  }
}
