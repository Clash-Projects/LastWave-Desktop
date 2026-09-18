import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../../app/window.dart';
import '../../core/audio/stream_models.dart';
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

class _WaveShellState extends ConsumerState<WaveShell> with TrayListener {
  bool _railExpanded = true;
  bool _queueOpen = false;
  bool _lyricsOpen = false;
  bool _miniOpen = false;
  bool _draggingFiles = false;
  late final TextEditingController _searchController;
  final FocusNode _searchFocus = FocusNode();
  final List<String> _backStack = [];
  final List<String> _forwardStack = [];
  bool _historyLocked = false;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    // Global hotkeys → playback. Re-registers the window.dart bindings
    // with Riverpod-aware handlers (HotKeyManager stores per-identifier
    // handlers, so re-register overwrites the no-op placeholders).
    _wireHotkeys();
    try {
      trayManager.addListener(this);
    } catch (_) {}
  }

  Future<void> _wireHotkeys() async {
    // No global backend on Wayland — the shell offers the same combos
    // as in-app shortcuts instead (see build()).
    if (!globalHotkeysSupported) return;
    try {
      Future<void> toggle(HotKey _) async {
        if (!mounted) return;
        await ref.read(playbackServiceProvider.notifier).toggle();
      }

      Future<void> next(HotKey _) async {
        if (!mounted) return;
        await ref.read(playbackServiceProvider.notifier).next();
      }

      Future<void> prev(HotKey _) async {
        if (!mounted) return;
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
    try {
      trayManager.removeListener(this);
    } catch (_) {}
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        windowManager.show().then((_) => windowManager.focus()).catchError((_) {});
      case 'toggle':
        ref.read(playbackServiceProvider.notifier).toggle();
      case 'next':
        ref.read(playbackServiceProvider.notifier).next();
      case 'prev':
        ref.read(playbackServiceProvider.notifier).previous();
      case 'quit':
        windowManager.close().catchError((_) {});
    }
  }

  @override
  void onTrayIconMouseDown() {
    windowManager.show().then((_) => windowManager.focus()).catchError((_) {});
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
    if (_searchFocus.hasFocus) return true;
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

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true):
            _goBack,
        const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true):
            _goForward,
        const SingleActivator(LogicalKeyboardKey.keyK, control: true):
            _openPalette,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            () => _searchFocus.requestFocus(),
        const SingleActivator(LogicalKeyboardKey.keyL, control: true): () {
          if (hasTrack) {
            setState(() {
              _lyricsOpen = !_lyricsOpen;
              if (_lyricsOpen) _queueOpen = false;
            });
          }
        },
        // Wayland fallback: global hotkeys can't register there, so the
        // same transport combos work in-app while the window is focused.
        // (On X11/Windows/macOS the global backend owns these keys, so
        // these entries stay dormant and can never double-fire.)
        if (!globalHotkeysSupported)
          const SingleActivator(LogicalKeyboardKey.keyP,
              control: true, alt: true): () {
            ref.read(playbackServiceProvider.notifier).toggle();
          },
        if (!globalHotkeysSupported)
          const SingleActivator(LogicalKeyboardKey.keyN,
              control: true, alt: true): () {
            ref.read(playbackServiceProvider.notifier).next();
          },
        if (!globalHotkeysSupported)
          const SingleActivator(LogicalKeyboardKey.keyB,
              control: true, alt: true): () {
            ref.read(playbackServiceProvider.notifier).previous();
          },
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_searchFocus.hasFocus) {
            _searchFocus.unfocus();
          } else if (_lyricsOpen) {
            setState(() => _lyricsOpen = false);
          } else if (_queueOpen) {
            setState(() => _queueOpen = false);
          } else if (_miniOpen) {
            setState(() => _miniOpen = false);
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
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.space) {
            if (_isTyping()) {
              return KeyEventResult.ignored;
            }
            if (hasTrack) {
              _togglePlay();
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: Mica(
          backgroundColor:
              dark ? WaveColors.background : WaveColors.lightBackground,
          child: Column(
            children: [
              WaveTitleBar(
                searchController: _searchController,
                searchFocus: _searchFocus,
                onSearchSubmit: _submitSearch,
                onPalette: _openPalette,
                onToggleRail: () =>
                    setState(() => _railExpanded = !_railExpanded),
                canGoBack: _backStack.isNotEmpty,
                canGoForward: _forwardStack.isNotEmpty,
                onBack: _goBack,
                onForward: _goForward,
              ),
              const WaveInfoBarHost(),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    WaveSideRail(
                      expanded: !collapsed,
                      active: active,
                      onGo: _go,
                    ),
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
                                      Positioned.fill(child: widget.child),
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
                                      Positioned(
                                        left: 0,
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
                                            child: WaveQueuePanel(
                                              onClose: () => setState(
                                                  () => _queueOpen = false),
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
                                            child: WaveLyricsSidePanel(
                                              onClose: () => setState(
                                                  () => _lyricsOpen = false),
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
                          // Dock is structural: reserves 80px on every view,
                          // including Now Playing — its in-page transport was
                          // removed so this dock is the single control surface.
                          WavePlayerDock(
                            onExpand: () => _go('/now'),
                            lyricsActive: _lyricsOpen || isLyrics,
                            queueActive: _queueOpen,
                            onToggleMini: () =>
                                setState(() => _miniOpen = !_miniOpen),
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
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
