import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/audio/stream_models.dart';
import '../../features/player/playback_service.dart';
import '../../features/search/search_repository.dart';
import '../mini_player/mini_player.dart';
import '../components/infobar_host.dart';
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
  bool _miniOpen = false;
  bool _draggingFiles = false;
  late final TextEditingController _searchController;
  final FocusNode _searchFocus = FocusNode();

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

  void _go(String path) {
    setState(() => _queueOpen = false);
    context.go(path);
  }

  void _submitSearch(String value) {
    final q = value.trim();
    if (q.isEmpty) {
      _openPalette();
      return;
    }
    ref.read(searchRepositoryProvider).pushHistory(q);
    setState(() => _queueOpen = false);
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

  void _maybeTogglePlay() {
    // Space is the global play/pause shortcut, but never while the
    // user is typing, editing, or adjusting a focused control.
    if (_searchFocus.hasFocus) return;
    final focus = FocusManager.instance.primaryFocus;
    if (focus != null) {
      final widget = focus.context?.widget;
      if (widget is EditableText) return;
      // Focused buttons/sliders already handle Space/Enter themselves;
      // letting the global shortcut fire too would double-toggle.
      if (widget is Focus) return;
    }
    _togglePlay();
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
    final isLyrics = widget.location.startsWith('/lyrics');

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true):
            _openPalette,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            () => _searchFocus.requestFocus(),
        const SingleActivator(LogicalKeyboardKey.keyL, control: true): () {
          if (hasTrack) _go('/lyrics');
        },
        const SingleActivator(LogicalKeyboardKey.space): _maybeTogglePlay,
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_searchFocus.hasFocus) {
            _searchFocus.unfocus();
          } else if (_queueOpen) {
            setState(() => _queueOpen = false);
          } else if (_miniOpen) {
            setState(() => _miniOpen = false);
          }
        },
      },
      child: Focus(
        autofocus: true,
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
                canGoBack: widget.location != '/home',
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
                              child: Stack(
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
                                  // Contextual queue — overlays, never permanent.
                                  // Width clamps to 90% of content so it
                                  // never covers the whole workspace on
                                  // narrow windows.
                                  if (_queueOpen)
                                    Positioned.fill(
                                      child: GestureDetector(
                                        onTap: () => setState(() =>
                                            _queueOpen = false),
                                        child: Container(
                                          color: Colors.black.withValues(
                                              alpha: 0.45),
                                        ),
                                      ),
                                    ),
                                  if (_queueOpen)
                                    Positioned(
                                      top: 0,
                                      bottom: 0,
                                      right: 0,
                                      child: LayoutBuilder(
                                        builder: (context, qc) {
                                          // Queue overlay lives inside the
                                          // content Stack; qc.maxWidth is
                                          // the content width already.
                                          final w = (qc.maxWidth * 0.9)
                                              .clamp(280.0, 360.0)
                                              .toDouble();
                                          return AnimatedContainer(
                                            duration: WaveMotion.normal,
                                            curve: Curves.easeOutCubic,
                                            width: w,
                                            child: WaveQueuePanel(
                                              onClose: () => setState(() =>
                                                  _queueOpen = false),
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  // Mini player — floats ABOVE the dock.
                                  // The dock stays mounted so content never
                                  // jumps 80px when mini opens.
                                  if (_miniOpen && hasTrack)
                                    Positioned(
                                      right: 16,
                                      bottom: 16,
                                      child: WaveMiniPlayer(
                                        onClose: () => setState(() =>
                                            _miniOpen = false),
                                        onExpand: () {
                                          setState(
                                              () => _miniOpen = false);
                                          _go('/now');
                                        },
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          // Dock is structural: always reserves 80px so
                          // content never renders beneath it and never
                          // shifts when mini opens.
                          WavePlayerDock(
                            onExpand: () => _go('/now'),
                            lyricsActive: isLyrics,
                            queueActive: _queueOpen,
                            onToggleMini: () => setState(
                                () => _miniOpen = !_miniOpen),
                            onToggleLyrics: () {
                              if (isLyrics) {
                                _go('/now');
                              } else {
                                setState(() => _queueOpen = false);
                                _go('/lyrics');
                              }
                            },
                            onToggleQueue: () => setState(
                                () => _queueOpen = !_queueOpen),
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
