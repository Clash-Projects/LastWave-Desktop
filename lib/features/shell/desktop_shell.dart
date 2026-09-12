import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../design_system/icons.dart';
import 'package:window_manager/window_manager.dart';

import '../../design_system/tokens.dart';
import '../library/playlists.dart';
import '../player/playback_service.dart';
import 'command_palette.dart';
import 'player_bar.dart';
import 'queue_panel.dart';

class _NavItem {
  final String path;
  final String label;
  final IconData icon;
  const _NavItem(this.path, this.label, this.icon);
}

const _primaryNav = [
  _NavItem('/home', 'Home', LwIcons.home),
  _NavItem('/search', 'Search', LwIcons.search),
  _NavItem('/library', 'Library', LwIcons.library),
  _NavItem('/liked', 'Liked Songs', LwIcons.heart),
  _NavItem('/albums', 'Albums', LwIcons.disc3),
  _NavItem('/artists', 'Artists', LwIcons.mic),
  _NavItem('/playlists', 'Playlists', LwIcons.listMusic),
  _NavItem('/mixes', 'Mix Lab', LwIcons.wand2),
  _NavItem('/downloads', 'Downloads', LwIcons.download),
  _NavItem('/history', 'History', LwIcons.history),
];

const _bottomNav = [
  _NavItem('/friends', 'Friends', LwIcons.users),
  _NavItem('/profile', 'Profile', LwIcons.user),
  _NavItem('/settings', 'Settings', LwIcons.settings),
];

/// Desktop shell: custom title bar, collapsible sidebar, adaptive
/// content + contextual panel, persistent player bar.
class DesktopShell extends ConsumerStatefulWidget {
  final String location;
  final Widget child;
  const DesktopShell({
    super.key,
    required this.location,
    required this.child,
  });

  @override
  ConsumerState<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends ConsumerState<DesktopShell> {
  bool _sidebarCollapsed = false;
  bool _rightPanelOpen = true;

  String _activePath(String location) {
    for (final item in [..._primaryNav, ..._bottomNav]) {
      if (location == item.path ||
          location.startsWith('${item.path}/')) {
        return item.path;
      }
    }
    if (location.startsWith('/playlists')) return '/playlists';
    return '/home';
  }

  void _go(String path) => context.go(path);

  @override
  Widget build(BuildContext context) {
    final breakpoint =
        breakpointFor(MediaQuery.sizeOf(context).width);
    final active = _activePath(widget.location);
    final player = ref.watch(playbackServiceProvider);
    final hasTrack = player.current != null;
    final showRightPanel = breakpoint == LwBreakpoint.wide &&
        _rightPanelOpen &&
        hasTrack;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK,
            control: true): () =>
            showCommandPalette(context, ref),
        for (var i = 0; i < _primaryNav.length && i < 9; i++)
          SingleActivator(
            LogicalKeyboardKey(
                0x31 + i), // Digit1..Digit9
            control: true,
          ): () => _go(_primaryNav[i].path),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor:
              Theme.of(context).scaffoldBackgroundColor,
          body: Column(
            children: [
              _TitleBar(
                onToggleSidebar: () => setState(
                    () => _sidebarCollapsed = !_sidebarCollapsed),
                onPalette: () =>
                    showCommandPalette(context, ref),
              ),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Sidebar(
                      collapsed: _sidebarCollapsed,
                      active: active,
                      onGo: _go,
                    ),
                    Expanded(
                      child: Column(
                        children: [
                          Expanded(child: widget.child),
                          if (hasTrack)
                            PlayerBar(
                              onExpand: () => _go('/now'),
                              onToggleQueue: () {
                                if (breakpoint ==
                                    LwBreakpoint.wide) {
                                  setState(() =>
                                      _rightPanelOpen =
                                          !_rightPanelOpen);
                                } else {
                                  showQueueSheet(context);
                                }
                              },
                            ),
                        ],
                      ),
                    ),
                    if (showRightPanel)
                      const SizedBox(
                        width: 340,
                        child: QueuePanel(),
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

class _TitleBar extends StatelessWidget {
  final VoidCallback onToggleSidebar;
  final VoidCallback onPalette;
  const _TitleBar({
    required this.onToggleSidebar,
    required this.onPalette,
  });

  @override
  Widget build(BuildContext context) {
    return DragToMoveArea(
      child: Container(
        height: 44,
        decoration: const BoxDecoration(
          color: LwColors.surface,
          border: Border(
              bottom:
                  BorderSide(color: LwColors.outlineSoft)),
        ),
        child: Row(
          children: [
            IconButton(
              onPressed: onToggleSidebar,
              icon: const Icon(LwIcons.panelLeft, size: 16),
              color: LwColors.textSecondary,
              tooltip: 'Toggle sidebar',
            ),
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Theme.of(context).colorScheme.primary,
                    Theme.of(context)
                        .colorScheme
                        .primary
                        .withValues(alpha: 0.6),
                  ],
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(LwIcons.disc3,
                  size: 15, color: Colors.white),
            ),
            const SizedBox(width: 8),
            const Text('LastWave', style: LwType.title),
            const SizedBox(width: 16),
            // Command palette trigger.
            InkWell(
              onTap: onPalette,
              borderRadius:
                  BorderRadius.circular(LwRadius.sm),
              child: Container(
                width: 280,
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: LwColors.surfaceRaised,
                  borderRadius:
                      BorderRadius.circular(LwRadius.sm),
                  border:
                      Border.all(color: LwColors.outlineSoft),
                ),
                child: const Row(
                  children: [
                    Icon(LwIcons.search,
                        size: 13,
                        color: LwColors.textTertiary),
                    SizedBox(width: 8),
                    Text('Search or command…',
                        style: LwType.caption),
                    Spacer(),
                    Text('Ctrl K', style: LwType.micro),
                  ],
                ),
              ),
            ),
            const Spacer(),
            _WindowButtons(),
          ],
        ),
      ),
    );
  }
}

class _WindowButtons extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    Future<void> guard(Future<void> Function() fn) async {
      try {
        await fn();
      } catch (_) {}
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _WinBtn(
            icon: LwIcons.minus,
            tooltip: 'Minimize',
            onTap: () =>
                guard(() => windowManager.minimize())),
        _WinBtn(
            icon: LwIcons.square,
            tooltip: 'Maximize',
            size: 12,
            onTap: () async {
              try {
                if (await windowManager.isMaximized()) {
                  await windowManager.unmaximize();
                } else {
                  await windowManager.maximize();
                }
              } catch (_) {}
            }),
        _WinBtn(
          icon: LwIcons.x,
          tooltip: 'Close',
          danger: true,
          onTap: () => guard(() => windowManager.close()),
        ),
      ],
    );
  }
}

class _WinBtn extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool danger;
  final double size;
  const _WinBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.danger = false,
    this.size = 15,
  });
  @override
  State<_WinBtn> createState() => _WinBtnState();
}

class _WinBtnState extends State<_WinBtn> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Tooltip(
          message: widget.tooltip,
          child: Container(
            width: 46,
            height: 44,
            color: _hover
                ? (widget.danger
                    ? LwColors.danger
                    : Colors.white.withValues(alpha: 0.07))
                : Colors.transparent,
            child: Icon(widget.icon,
                size: widget.size,
                color: _hover && widget.danger
                    ? Colors.white
                    : LwColors.textSecondary),
          ),
        ),
      ),
    );
  }
}

class _Sidebar extends ConsumerWidget {
  final bool collapsed;
  final String active;
  final void Function(String) onGo;
  const _Sidebar({
    required this.collapsed,
    required this.active,
    required this.onGo,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(playlistRepositoryProvider);
    final accent = Theme.of(context).colorScheme.primary;
    final width = collapsed ? 60.0 : 212.0;

    Widget item(_NavItem nav) {
      final selected = active == nav.path;
      final content = collapsed
          ? Tooltip(
              message: nav.label,
              child: Icon(nav.icon,
                  size: 17,
                  color: selected
                      ? Colors.white
                      : LwColors.textSecondary),
            )
          : Row(
              children: [
                Icon(nav.icon,
                    size: 16,
                    color: selected
                        ? Colors.white
                        : LwColors.textSecondary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    nav.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: LwType.body.copyWith(
                      fontSize: 13,
                      fontWeight: selected
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: selected
                          ? Colors.white
                          : LwColors.textSecondary,
                    ),
                  ),
                ),
              ],
            );
      return Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: 8, vertical: 1),
        child: Material(
          color: selected
              ? accent.withValues(alpha: 0.9)
              : Colors.transparent,
          borderRadius:
              BorderRadius.circular(LwRadius.sm),
          child: InkWell(
            onTap: () => onGo(nav.path),
            borderRadius:
                BorderRadius.circular(LwRadius.sm),
            hoverColor: selected
                ? null
                : Colors.white.withValues(alpha: 0.05),
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: collapsed ? 0 : 10,
                vertical: 8,
              ),
              alignment: collapsed
                  ? Alignment.center
                  : Alignment.centerLeft,
              child: content,
            ),
          ),
        ),
      );
    }

    return AnimatedContainer(
      duration: LwMotion.normal,
      curve: LwMotion.standard,
      width: width,
      decoration: const BoxDecoration(
        color: LwColors.surface,
        border: Border(
            right: BorderSide(color: LwColors.outlineSoft)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          ..._primaryNav.map(item),
          if (!collapsed) ...[
            const SizedBox(height: 8),
            const Padding(
              padding: EdgeInsets.symmetric(
                  horizontal: LwSpacing.md),
              child: Text('PLAYLISTS', style: LwType.micro),
            ),
            const SizedBox(height: 4),
          ] else
            const Divider(
                height: 16, color: LwColors.outlineSoft),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                for (final p in playlists)
                  _PlaylistRow(
                    playlist: p,
                    collapsed: collapsed,
                    selected: active == '/playlists/${p.id}',
                    onTap: () => onGo('/playlists/${p.id}'),
                  ),
                if (playlists.isEmpty && !collapsed)
                  const Padding(
                    padding: EdgeInsets.symmetric(
                        horizontal: LwSpacing.md,
                        vertical: LwSpacing.xs),
                    child: Text(
                      'Like songs or create a playlist to see it here.',
                      style: LwType.caption,
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1, color: LwColors.outlineSoft),
          const SizedBox(height: 6),
          ..._bottomNav.map(item),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _PlaylistRow extends StatelessWidget {
  final SavedPlaylist playlist;
  final bool collapsed;
  final bool selected;
  final VoidCallback onTap;
  const _PlaylistRow({
    required this.playlist,
    required this.collapsed,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final child = collapsed
        ? Tooltip(
            message: playlist.title,
            child: Icon(
              playlist.isLikedSongs
                  ? LwIcons.heart
                  : LwIcons.listMusic,
              size: 16,
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : LwColors.textSecondary,
            ),
          )
        : Row(
            children: [
              Icon(
                playlist.isLikedSongs
                    ? LwIcons.heart
                    : LwIcons.listMusic,
                size: 14,
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : LwColors.textTertiary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      playlist.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: LwType.body.copyWith(fontSize: 12.5),
                    ),
                    Text(
                      '${playlist.tracks.length} tracks',
                      style: LwType.caption.copyWith(
                          color: LwColors.textTertiary,
                          fontSize: 10.5),
                    ),
                  ],
                ),
              ),
            ],
          );
    return Padding(
      padding:
          const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: selected
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(LwRadius.sm),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(LwRadius.sm),
          hoverColor:
              Colors.white.withValues(alpha: 0.05),
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: collapsed ? 0 : 10,
              vertical: 7,
            ),
            alignment: collapsed
                ? Alignment.center
                : Alignment.centerLeft,
            child: child,
          ),
        ),
      ),
    );
  }
}
