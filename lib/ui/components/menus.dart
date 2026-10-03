import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/track_actions.dart';
import '../../core/audio/stream_models.dart';
import '../../core/shortcuts/app_shortcuts.dart';
import '../../features/downloads/download_manager.dart';
import '../../features/home/home_providers.dart';
import '../../features/library/playlists.dart';
import '../../features/player/playback_service.dart';
import '../../features/search/shared_providers.dart';
import '../theme/tokens.dart';
import 'buttons.dart' show LWTooltip;

/// Snappy flyout entrance shared by every DropDownButton/menu in the
/// app. Same slide-from-edge language as fluent's default, compressed
/// into the first ~55% of the 167ms controller (≈90ms) plus a fast
/// fade — the full-length slide reads as lag on click. Pass as
/// `transitionBuilder:` on DropDownButton, or mirror with an explicit
/// 90ms `transitionDuration` on direct `showFlyout` calls.
Widget fastFlyoutTransition(
  BuildContext context,
  Animation<double> animation,
  FlyoutPlacementMode placementMode,
  Widget flyout,
) {
  if (animation.isCompleted || animation.isDismissed) return flyout;
  if (animation.status == AnimationStatus.reverse) {
    return FadeTransition(opacity: animation, child: flyout);
  }
  final textDirection = Directionality.of(context);
  final begin = switch (placementMode) {
    FlyoutPlacementMode.topCenter ||
    FlyoutPlacementMode.topLeft ||
    FlyoutPlacementMode.topRight =>
      const Offset(0, 1),
    _ => const Offset(0, -1),
  };
  const fast = Interval(0.0, 0.55, curve: Curves.easeOutCubic);
  return ClipRect(
    child: FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: fast),
      child: SlideTransition(
        textDirection: textDirection,
        position: Tween<Offset>(begin: begin, end: Offset.zero).animate(
          CurvedAnimation(parent: animation, curve: fast),
        ),
        child: flyout,
      ),
    ),
  );
}

/// Menu data model for [WaveFlyoutPanel].
///
/// Labels are plain strings (not Text widgets) so rows can enforce
/// single-line ellipsis inside the fixed-width panel. Carries no layout
/// of its own — rendering is owned by the panel.
sealed class WaveMenuEntry {
  const WaveMenuEntry();
}

/// One tappable row. `onPressed == null` renders disabled.
class WaveMenuAction extends WaveMenuEntry {
  final Widget? leading;
  final String label;
  final String? hint;
  final VoidCallback? onPressed;
  const WaveMenuAction({
    this.leading,
    required this.label,
    this.hint,
    this.onPressed,
  });
}

/// Horizontal divider.
class WaveMenuSeparator extends WaveMenuEntry {
  const WaveMenuSeparator();
}

/// Hover-cascade nested menu (e.g. "Add to playlist").
class WaveMenuSubmenu extends WaveMenuEntry {
  final Widget? leading;
  final String label;
  final List<WaveMenuEntry> Function() items;
  const WaveMenuSubmenu({
    this.leading,
    required this.label,
    required this.items,
  });
}

/// Single Fluent menu source for every track row / card / hero.
///
/// One builder produces [WaveMenuEntry] lists rendered by
/// [WaveFlyoutPanel] (right-click menus). Plugin DropDownButtons keep
/// their own inline item lists and are unaffected.
List<WaveMenuEntry> waveTrackMenuItems({
  required WidgetRef ref,
  required String title,
  required String artist,
  String artworkUrl = '',
  String videoId = '',
  PlayableTrack? playable,
  String? removeLabel,
  VoidCallback? onRemove,
}) {
  final player = ref.read(playbackServiceProvider.notifier);
  final track = playable ??
      PlayableTrack(
        title: title,
        artist: artist,
        artworkUrl: artworkUrl,
        videoId: videoId,
      );
  final library = ref.read(playlistRepositoryProvider.notifier);
  final liked = library.likedKeys().contains(track.queueKey);
  final playlists = ref.read(playlistRepositoryProvider);
  final downloads = ref.read(downloadManagerProvider.notifier);

  StoredTrack stored() => StoredTrack(
        name: title,
        artist: artist,
        artworkUrl: artworkUrl,
        videoId: track.videoId,
      );

  final items = <WaveMenuEntry>[
    WaveMenuAction(
      leading: const Icon(FluentIcons.play, size: 15),
      label: 'Play',
      hint: 'Enter',
      onPressed: () =>
          player.play(track, sourceLabel: 'Context menu'),
    ),
    WaveMenuAction(
      leading: const Icon(FluentIcons.add, size: 15),
      label: 'Play next',
      onPressed: () => player.playNext(track),
    ),
    WaveMenuAction(
      leading: const Icon(FluentIcons.list, size: 15),
      label: 'Add to queue',
      onPressed: () => player.addToQueue(track),
    ),
    const WaveMenuSeparator(),
    WaveMenuAction(
      leading: Icon(
        liked ? FluentIcons.heart_fill : FluentIcons.heart,
        size: 15,
      ),
      label: liked ? 'Unlike' : 'Like',
      onPressed: () => library.toggleLiked(stored()),
    ),
    WaveMenuAction(
      leading: const Icon(FluentIcons.download, size: 15),
      label: 'Download',
      hint: AppShortcuts.label(AppShortcut.download),
      onPressed: () => downloads.downloadTrack(
        title: title,
        artist: artist,
        artworkUrl: artworkUrl,
      ),
    ),
  ];
  if (playlists.isNotEmpty) {
    items.add(
      WaveMenuSubmenu(
        leading: const Icon(FluentIcons.list_mirrored, size: 15),
        label: 'Add to playlist',
        items: () => [
          for (final p in playlists)
            WaveMenuAction(
              leading: Icon(
                p.isLikedSongs
                    ? FluentIcons.heart
                    : FluentIcons.list_mirrored,
                size: 15,
              ),
              label: p.title,
              onPressed: () => library.addTrack(p.id, stored()),
            ),
        ],
      ),
    );
  }
  items.add(const WaveMenuSeparator());
  items.add(
    WaveMenuAction(
      leading: const Icon(FluentIcons.album, size: 15),
      label: 'Go to album',
      onPressed: () => goToAlbumOfTrack(
        ref,
        title: title,
        artist: artist,
        album: track.album,
      ),
    ),
  );
  items.add(
    WaveMenuAction(
      leading: const Icon(FluentIcons.microphone, size: 15),
      label: 'Go to artist',
      onPressed: () => ref.context
          .go('/artist/${Uri.encodeComponent(artist)}'),
    ),
  );
  items.add(const WaveMenuSeparator());
  items.add(
    WaveMenuAction(
      leading: const Icon(FluentIcons.info, size: 15),
      label: 'Properties',
      onPressed: () => showWaveTrackProperties(
        ref.context,
        title: title,
        artist: artist,
        artworkUrl: artworkUrl,
      ),
    ),
  );
  if (removeLabel != null && onRemove != null) {
    items.add(const WaveMenuSeparator());
    items.add(
      WaveMenuAction(
        leading: const Icon(FluentIcons.delete, size: 15),
        label: removeLabel,
        hint: 'Del',
        onPressed: onRemove,
      ),
    );
  }
  items.add(const WaveMenuSeparator());
  items.add(
    WaveMenuAction(
      leading: const Icon(FluentIcons.blocked, size: 15),
      label: "Don't recommend",
      onPressed: () {
        try {
          ref
              .read(databaseProvider)
              .addExclusion(name: title, artist: artist);
          // Recommendations rebuild without it on next load.
          ref.invalidate(feedProvider);
        } catch (_) {}
      },
    ),
  );
  return items;
}

/// Track properties dialog (Fluent ContentDialog).
Future<void> showWaveTrackProperties(
  BuildContext context, {
  required String title,
  required String artist,
  String artworkUrl = '',
}) {
  return showDialog(
    context: context,
    builder: (context) => ContentDialog(
      title: const Text('Properties'),
      constraints: const BoxConstraints(maxWidth: 440),
      content: SizedBox(
        width: double.infinity,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: WaveType.trackTitle),
            const SizedBox(height: 4),
            Text(artist, style: WaveType.body),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

/// Opaque fixed-width menu surface replacing plugin [MenuFlyout] /
/// [FlyoutContent] for our popups.
///
/// WHY: plugin MenuFlyout wraps content in IntrinsicWidth (an uncached
/// bottom-up measurement of the whole subtree on every open — the
/// RenderPhysicalModel/ClipPath/CustomPaint intrinsics cascade from the
/// profiles) plus an Acrylic/PhysicalModel shell. This panel sizes by
/// top-down constraints instead (stretch inside a fixed max width: O(n),
/// cached, nothing to measure) with an opaque surface + cacheable
/// BoxShadows. Rows are the theme's own [FlyoutListTile], so item
/// visuals (hover fill, typography, trailing style) are pixel-identical.
class WaveFlyoutPanel extends StatefulWidget {
  final List<WaveMenuEntry>? entries;
  final Widget? child;
  final double maxWidth;
  const WaveFlyoutPanel.items({
    super.key,
    required this.entries,
    this.maxWidth = 280,
  }) : child = null;
  const WaveFlyoutPanel.child({
    super.key,
    required this.child,
    this.maxWidth = 280,
  }) : entries = null;
  @override
  State<WaveFlyoutPanel> createState() => _WaveFlyoutPanelState();
}

class _WaveFlyoutPanelState extends State<WaveFlyoutPanel> {
  int _highlight = -1;
  FlyoutController? _openSubmenu;
  final Map<int, GlobalKey<_WaveSubmenuRowState>> _subKeys = {};

  @override
  void dispose() {
    // Cascaded submenu is its own route: close it with the parent.
    // Guarded + caught: dispose order vs. the child route is not
    // contractual, and close() asserts attached+open in debug.
    try {
      final sub = _openSubmenu;
      _openSubmenu = null;
      if (sub != null && sub.isOpen) sub.close();
    } catch (_) {}
    super.dispose();
  }

  /// Indices of keyboard-focusable rows (actions + submenus, no dividers).
  List<int> get _actionable => [
        for (var i = 0; i < (widget.entries?.length ?? 0); i++)
          if (widget.entries![i] is WaveMenuAction ||
              widget.entries![i] is WaveMenuSubmenu)
            i,
      ];

  void _moveHighlight(int dir) {
    final stops = _actionable;
    if (stops.isEmpty) return;
    setState(() {
      final at = stops.indexOf(_highlight);
      _highlight = at < 0
          ? (dir > 0 ? stops.first : stops.last)
          : stops[(at + dir) % stops.length];
    });
  }

  void _activate(BuildContext context, int index) {
    final entry = widget.entries![index];
    if (entry is WaveMenuSubmenu) {
      _subKeys[index]?.currentState?.openNow();
    } else if (entry is WaveMenuAction) {
      final onPressed = entry.onPressed;
      if (onPressed == null) return;
      Navigator.of(context).maybePop();
      onPressed();
    }
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
      _moveHighlight(1);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
      _moveHighlight(-1);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.enter &&
        _highlight >= 0 &&
        widget.entries != null &&
        _highlight < widget.entries!.length) {
      _activate(context, _highlight);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    Widget body;
    if (widget.child != null) {
      body = widget.child!;
    } else {
      final rows = <Widget>[];
      for (var i = 0; i < widget.entries!.length; i++) {
        final entry = widget.entries![i];
        if (entry is WaveMenuSeparator) {
          // Same spec as the plugin separator: 5px bottom pad, zero-margin
          // divider. Built inline — the plugin's is not a Widget.
          rows.add(const Padding(
            padding: EdgeInsetsDirectional.only(bottom: 5),
            child: Divider(
              style: DividerThemeData(
                  horizontalMargin: EdgeInsetsDirectional.zero),
            ),
          ));
        } else if (entry is WaveMenuSubmenu) {
          rows.add(_WaveSubmenuRow(
            key: _subKeys.putIfAbsent(
                i, () => GlobalKey<_WaveSubmenuRowState>()),
            entry: entry,
            highlighted: i == _highlight,
            onOpened: (c) {
              if (_openSubmenu != null &&
                  _openSubmenu != c &&
                  _openSubmenu!.isOpen) {
                _openSubmenu!.close();
              }
              _openSubmenu = c;
            },
          ));
        } else if (entry is WaveMenuAction) {
          final onPressed = entry.onPressed;
          rows.add(FlyoutListTile(
            margin: EdgeInsetsDirectional.zero,
            selected: i == _highlight,
            showSelectedIndicator: false,
            icon: entry.leading,
            text: Text(
              entry.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: entry.hint == null
                ? null
                : Text(entry.hint!,
                    style: const TextStyle(fontSize: 11)),
            onPressed: onPressed == null
                ? null
                : () {
                    Navigator.of(context).maybePop();
                    onPressed();
                  },
          ));
        }
      }
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: rows,
      );
    }

    final panel = Container(
      decoration: BoxDecoration(
        color: theme.menuColor,
        borderRadius: BorderRadius.circular(7),
        boxShadow: const [
          BoxShadow(
            color: Color(0x21000000),
            blurRadius: 7.2,
            offset: Offset(0, 3.2),
          ),
          BoxShadow(
            color: Color(0x1C000000),
            blurRadius: 1.8,
            offset: Offset(0, 0.68),
          ),
        ],
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: widget.maxWidth),
        child: Padding(
          padding:
              const EdgeInsetsDirectional.symmetric(vertical: 2, horizontal: 4),
          child: body,
        ),
      ),
    );

    if (widget.entries == null) return panel;
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: panel,
    );
  }
}

/// Cascading submenu row: same [FlyoutListTile] visuals as actions, opens
/// a nested [WaveFlyoutPanel] on hover (250ms) or tap/click/Enter.
class _WaveSubmenuRow extends StatefulWidget {
  final WaveMenuSubmenu entry;
  final bool highlighted;
  final ValueChanged<FlyoutController> onOpened;
  const _WaveSubmenuRow({
    super.key,
    required this.entry,
    required this.highlighted,
    required this.onOpened,
  });

  @override
  State<_WaveSubmenuRow> createState() => _WaveSubmenuRowState();
}

class _WaveSubmenuRowState extends State<_WaveSubmenuRow> {
  final _controller = FlyoutController();
  Timer? _hoverTimer;

  @override
  void dispose() {
    _hoverTimer?.cancel();
    // If the parent route is torn down with our submenu open, close it
    // ourselves; the panel dispose covers the reverse order. Caught:
    // the target may already be detached in debug asserts.
    try {
      if (_controller.isOpen) _controller.close();
    } catch (_) {}
    _controller.dispose();
    super.dispose();
  }

  void openNow() {
    _hoverTimer?.cancel();
    if (_controller.isOpen) return;
    _controller.showFlyout(
      barrierColor: Colors.transparent,
      placementMode: FlyoutPlacementMode.rightTop,
      transitionDuration: const Duration(milliseconds: 90),
      transitionBuilder: fastFlyoutTransition,
      builder: (context) => WaveFlyoutPanel.items(
        entries: widget.entry.items(),
      ),
    );
    widget.onOpened(_controller);
  }

  @override
  Widget build(BuildContext context) {
    return FlyoutTarget(
      controller: _controller,
      child: MouseRegion(
        onEnter: (_) {
          _hoverTimer?.cancel();
          _hoverTimer = Timer(
            const Duration(milliseconds: 250),
            openNow,
          );
        },
        onExit: (_) => _hoverTimer?.cancel(),
        child: FlyoutListTile(
          margin: EdgeInsetsDirectional.zero,
          selected: widget.highlighted,
          showSelectedIndicator: false,
          icon: widget.entry.leading,
          text: Text(
            widget.entry.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(FluentIcons.chevron_right, size: 12),
          onPressed: openNow,
        ),
      ),
    );
  }
}

/// Right-click region opening a [WaveFlyoutPanel] at the cursor.
class WaveContextMenu extends StatefulWidget {
  final List<WaveMenuEntry> Function() items;
  final Widget child;
  const WaveContextMenu({
    super.key,
    required this.items,
    required this.child,
  });
  @override
  State<WaveContextMenu> createState() => _WaveContextMenuState();
}

class _WaveContextMenuState extends State<WaveContextMenu> {
  final _controller = FlyoutController();
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _open() {
    if (widget.items().isEmpty) return;
    _controller.showFlyout(
      barrierColor: Colors.transparent,
      placementMode: FlyoutPlacementMode.auto,
      transitionDuration: const Duration(milliseconds: 90),
      transitionBuilder: fastFlyoutTransition,
      builder: (context) => WaveFlyoutPanel.items(
        entries: widget.items(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FlyoutTarget(
      controller: _controller,
      child: GestureDetector(
        onSecondaryTapDown: (_) => _open(),
        onLongPressStart: (_) => _open(),
        child: widget.child,
      ),
    );
  }
}

/// Canonical context-menu alias: [LWContextMenu] is [WaveContextMenu].
///
/// Right-click / long-press region opening a 7px Fluent menu flyout.
class LWContextMenu extends WaveContextMenu {
  const LWContextMenu({
    super.key,
    required super.items,
    required super.child,
  });
}

/// Button opening a [WaveFlyoutPanel]; the trigger keeps caller visuals
/// verbatim (replaces plugin DropDownButton, whose MenuFlyout pays the
/// IntrinsicWidth measurement on every open).
class WaveMenuButton extends StatefulWidget {
  final List<WaveMenuEntry> entries;
  final FlyoutPlacementMode placement;
  final Widget Function(BuildContext context, VoidCallback onOpen)
      buttonBuilder;
  const WaveMenuButton({
    super.key,
    required this.entries,
    required this.buttonBuilder,
    this.placement = FlyoutPlacementMode.auto,
  });
  @override
  State<WaveMenuButton> createState() => _WaveMenuButtonState();
}

class _WaveMenuButtonState extends State<WaveMenuButton> {
  final _controller = FlyoutController();
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _open() {
    if (widget.entries.isEmpty) return;
    _controller.showFlyout(
      barrierColor: Colors.transparent,
      placementMode: widget.placement,
      transitionDuration: const Duration(milliseconds: 90),
      transitionBuilder: fastFlyoutTransition,
      builder: (context) => WaveFlyoutPanel.items(
        entries: widget.entries,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FlyoutTarget(
      controller: _controller,
      child: widget.buttonBuilder(context, _open),
    );
  }
}

/// Overflow button opening a [WaveFlyoutPanel] below-right.
class WaveOverflowButton extends StatelessWidget {
  final String tooltip;
  final List<WaveMenuEntry> items;
  final IconData icon;
  const WaveOverflowButton({
    super.key,
    this.tooltip = 'More',
    required this.items,
    this.icon = FluentIcons.more,
  });

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    return LWTooltip(
      message: tooltip,
      child: WaveMenuButton(
        entries: items,
        placement: FlyoutPlacementMode.bottomRight,
        buttonBuilder: (context, onOpen) => SizedBox(
          width: WaveDensity.hitArea,
          height: WaveDensity.hitArea,
          child: IconButton(
            icon: Icon(
              icon,
              size: 15,
              color: dark
                  ? WaveColors.textSecondary
                  : WaveColors.lightTextSecondary,
            ),
            onPressed: onOpen,
          ),
        ),
      ),
    );
  }
}

/// Add-to-playlist picker dialog (Fluent ContentDialog).
Future<void> showWaveAddToPlaylist(
  BuildContext context,
  WidgetRef ref, {
  required String title,
  required String artist,
  String artworkUrl = '',
  String videoId = '',
}) async {
  final playlists = ref.read(playlistRepositoryProvider);
  if (playlists.isEmpty) return;
  final selected = await showDialog<int>(
    context: context,
    builder: (context) => ContentDialog(
      title: const Text('Add to playlist'),
      constraints: const BoxConstraints(maxWidth: 440),
      content: SizedBox(
        width: double.infinity,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final p in playlists)
              ListTile.selectable(
                title: Text(p.title),
                subtitle: Text('${p.tracks.length} tracks'),
                leading: Icon(
                  p.isLikedSongs
                      ? FluentIcons.heart
                      : FluentIcons.list_mirrored,
                  size: 15,
                ),
                selectionMode: ListTileSelectionMode.single,
                selected: false,
                onPressed: () =>
                    Navigator.of(context).pop(p.id),
              ),
          ],
        ),
      ),
      actions: [
        Button(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
  if (selected != null) {
    await ref.read(playlistRepositoryProvider.notifier).addTrack(
          selected,
          StoredTrack(
            name: title,
            artist: artist,
            artworkUrl: artworkUrl,
            videoId: videoId,
          ),
        );
  }
}

/// Like toggle helper for the new layer (no legacy toast host).
Future<bool> waveToggleLike(
  WidgetRef ref, {
  required String title,
  required String artist,
  String artworkUrl = '',
  String videoId = '',
}) {
  return ref.read(playlistRepositoryProvider.notifier).toggleLiked(
        StoredTrack(
          name: title,
          artist: artist,
          artworkUrl: artworkUrl,
          videoId: videoId,
        ),
      );
}
