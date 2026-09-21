import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:window_manager/window_manager.dart';

import '../../features/lastfm/auth_repository.dart';
import '../../features/search/search_repository.dart';
import '../components/buttons.dart' show LWTooltip;
import '../components/menus.dart' show fastFlyoutTransition;
import '../theme/haze.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

/// Compact 44px title / nav / search bar.
///
/// Left: back · forward
/// Centre-left: compact search (not a giant toolbar)
/// Right: profile · app menu · window controls
class WaveTitleBar extends ConsumerWidget {
  final TextEditingController searchController;
  final FocusNode searchFocus;
  final ValueChanged<String> onSearchSubmit;
  final VoidCallback onPalette;
  final VoidCallback onToggleRail;
  final bool canGoBack;
  final bool canGoForward;
  final VoidCallback? onBack;
  final VoidCallback? onForward;
  const WaveTitleBar({
    super.key,
    required this.searchController,
    required this.searchFocus,
    required this.onSearchSubmit,
    required this.onPalette,
    required this.onToggleRail,
    required this.canGoBack,
    this.canGoForward = false,
    this.onBack,
    this.onForward,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = waveIsDark(context);
    final auth = ref.watch(authRepositoryProvider);
    return WaveHaze(
      level: LwHazeLevel.l1,
      base: dark
          ? WaveColors.background.withValues(alpha: 0.85)
          : WaveColors.lightBackground.withValues(alpha: 0.9),
      border: Border(
        bottom: BorderSide(color: waveDivider(context)),
      ),
      child: SizedBox(
        height: WaveDensity.titleBar,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final maxW = constraints.maxWidth;
            final compact = maxW < 700;
            final searchMax =
                (maxW * 0.28).clamp(140.0, 300.0).toDouble();
            return Row(
              children: [
                const SizedBox(width: 6),
                _BarBtn(
                  tooltip: 'Toggle navigation',
                  icon: WaveIcons.panelLeft,
                  onTap: onToggleRail,
                ),
                _BarBtn(
                  tooltip: 'Back',
                  icon: WaveIcons.back,
                  onTap: canGoBack ? onBack : null,
                ),
                _BarBtn(
                  tooltip: 'Forward',
                  icon: WaveIcons.forward,
                  onTap: canGoForward ? onForward : null,
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: searchMax,
                  child: _WaveSearchBox(
                    controller: searchController,
                    focus: searchFocus,
                    onSubmit: onSearchSubmit,
                    onPalette: onPalette,
                  ),
                ),
                const SizedBox(width: 4),
                if (!compact)
                  _BarBtn(
                    tooltip: 'Commands (Ctrl+K)',
                    icon: WaveIcons.command,
                    onTap: onPalette,
                  ),
                Expanded(
                  child: DragToMoveArea(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      // WinUI: double-click title bar toggles maximize.
                      onDoubleTap: () async {
                        try {
                          if (await windowManager.isMaximized()) {
                            await windowManager.unmaximize();
                          } else {
                            await windowManager.maximize();
                          }
                        } catch (_) {}
                      },
                      child: const SizedBox(
                        width: double.infinity,
                        height: double.infinity,
                      ),
                    ),
                  ),
                ),
                // Profile / account — tiny, no giant buttons.
                GestureDetector(
                  onTap: () => context.go(
                    auth.status == AuthStatus.signedIn
                        ? '/profile'
                        : '/welcome',
                  ),
                  child: LWTooltip(
                    message: auth.status == AuthStatus.signedIn
                        ? auth.username
                        : 'Connect Last.fm',
                    child: Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: dark
                            ? WaveColors.surfaceRaised
                            : WaveColors.lightOverlay,
                        border:
                            Border.all(color: waveDivider(context)),
                      ),
                      child: Center(
                        child: Text(
                          auth.status == AuthStatus.signedIn &&
                                  auth.username.isNotEmpty
                              ? auth.username[0].toUpperCase()
                              : '?',
                          style: WaveType.label
                              .copyWith(fontSize: 11),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                _AppMenu(),
                const SizedBox(width: 6),
                const _WindowButtons(),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _WaveSearchBox extends ConsumerStatefulWidget {
  final TextEditingController controller;
  final FocusNode focus;
  final ValueChanged<String> onSubmit;
  final VoidCallback onPalette;
  const _WaveSearchBox({
    required this.controller,
    required this.focus,
    required this.onSubmit,
    required this.onPalette,
  });
  @override
  ConsumerState<_WaveSearchBox> createState() => _WaveSearchBoxState();
}

class _WaveSearchBoxState extends ConsumerState<_WaveSearchBox> {
  final _flyout = FlyoutController();
  bool _isOpen = false;
  bool _suppressFocusFlyout = false;

  @override
  void initState() {
    super.initState();
    widget.focus.addListener(_onFocus);
  }

  @override
  void dispose() {
    widget.focus.removeListener(_onFocus);
    _flyout.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (widget.focus.hasFocus) {
      if (_suppressFocusFlyout) {
        _suppressFocusFlyout = false;
        return;
      }
      _showRecents();
    } else {
      _suppressFocusFlyout = false;
      _closeFlyout();
    }
  }

  void _closeFlyout() {
    if (_isOpen && _flyout.isOpen) {
      try {
        _flyout.close();
      } catch (_) {}
    }
    _isOpen = false;
  }

  Future<void> _showRecents() async {
    final history =
        ref.read(searchRepositoryProvider).history().take(5).toList();
    if (history.isEmpty) return;
    if (_isOpen || _flyout.isOpen) return;
    _isOpen = true;

    try {
      await _flyout.showFlyout(
        barrierColor: Colors.transparent,
        barrierDismissible: true,
        dismissWithEsc: true,
        placementMode: FlyoutPlacementMode.bottomCenter,
        builder: (context) => MenuFlyout(
          items: [
            for (final h in history)
              MenuFlyoutItem(
                leading:
                    const Icon(WaveIcons.history, size: 15),
                text: Text(h),
                onPressed: () {
                  widget.controller.text = h;
                  _closeFlyout();
                  widget.focus.unfocus();
                  widget.onSubmit(h);
                },
              ),
            const MenuFlyoutSeparator(),
            MenuFlyoutItem(
              leading: const Icon(WaveIcons.command, size: 15),
              text: const Text('All commands  (Ctrl+K)'),
              onPressed: () {
                _closeFlyout();
                widget.focus.unfocus();
                widget.onPalette();
              },
            ),
          ],
        ),
      );
    } finally {
      _isOpen = false;
    }

    if (mounted) {
      _suppressFocusFlyout = true;
      if (widget.focus.hasFocus) {
        widget.focus.unfocus();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    return FlyoutTarget(
      controller: _flyout,
      child: LWTooltip(
        message: 'Search (Ctrl+F)',
        child: AnimatedContainer(
          duration: WaveMotion.fast,
          // Fill the Flexible budget from the parent; focus state only
          // changes decoration, never width (no layout push).
          width: double.infinity,
          height: 30,
          child: TextBox(
            controller: widget.controller,
            focusNode: widget.focus,
            placeholder: 'Search',
            onTap: () {
              _suppressFocusFlyout = false;
              if (!_isOpen) {
                _showRecents();
              }
            },
            onTapOutside: (_) {
              _closeFlyout();
              if (widget.focus.hasFocus) {
                widget.focus.unfocus();
              }
            },
            prefix: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Icon(
                WaveIcons.search,
                size: 15,
                color: dark
                    ? WaveColors.textTertiary
                    : WaveColors.lightTextTertiary,
              ),
            ),
            suffix: widget.controller.text.isNotEmpty
                ? Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: IconButton(
                      icon: const Icon(FluentIcons.chrome_close, size: 10),
                      onPressed: () {
                        widget.controller.clear();
                        setState(() {});
                      },
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onTap: widget.onPalette,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(
                          color: dark
                              ? WaveColors.surfaceRaised
                              : WaveColors.lightOverlay,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: waveDivider(context).withValues(alpha: 0.5),
                          ),
                        ),
                        child: Text(
                          'Ctrl K',
                          style: TextStyle(
                            fontSize: 9.5,
                            fontWeight: FontWeight.w500,
                            color: dark
                                ? WaveColors.textTertiary
                                : WaveColors.lightTextTertiary,
                          ),
                        ),
                      ),
                    ),
                  ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (v) {
              _suppressFocusFlyout = true;
              _closeFlyout();
              widget.focus.unfocus();
              widget.onSubmit(v);
            },
          ),
        ),
      ),
    );
  }
}

class _BarBtn extends StatefulWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback? onTap;
  const _BarBtn({required this.tooltip, required this.icon, this.onTap});
  @override
  State<_BarBtn> createState() => _BarBtnState();
}

class _BarBtnState extends State<_BarBtn> {
  bool _hover = false;
  bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    return LWTooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() {
          _hover = false;
          _pressed = false;
        }),
        child: GestureDetector(
          onTap: widget.onTap,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          child: AnimatedContainer(
            duration: WaveMotion.fast,
            width: WaveDensity.hitArea,
            height: WaveDensity.hitArea,
            decoration: BoxDecoration(
              color: _pressed
                  ? (dark ? Colors.white : Colors.black)
                      .withValues(alpha: WaveState.pressedAlpha)
                  : _hover
                      ? (dark ? Colors.white : Colors.black)
                          .withValues(alpha: WaveState.hoverAlpha)
                      : Colors.transparent,
              borderRadius:
                  BorderRadius.circular(WaveRadius.controls),
            ),
            child: Icon(
              widget.icon,
              size: 15,
              color: widget.onTap == null
                  ? (dark
                          ? WaveColors.textTertiary
                          : WaveColors.lightTextTertiary)
                      .withValues(alpha: 0.4)
                  : (dark
                      ? WaveColors.textSecondary
                      : WaveColors.lightTextSecondary),
            ),
          ),
        ),
      ),
    );
  }
}

class _AppMenu extends StatelessWidget {
  const _AppMenu();
  @override
  Widget build(BuildContext context) {
    return DropDownButton(
      placement: FlyoutPlacementMode.bottomRight,
      transitionBuilder: fastFlyoutTransition,
      items: [
        MenuFlyoutItem(
          leading: const Icon(WaveIcons.search, size: 15),
          text: const Text('Search  (Ctrl+K)'),
          onPressed: () => context.go('/search'),
        ),
        MenuFlyoutItem(
          leading: const Icon(WaveIcons.lyrics, size: 15),
          text: const Text('Lyrics  (Ctrl+L)'),
          onPressed: () => context.go('/lyrics'),
        ),
        const MenuFlyoutSeparator(),
        MenuFlyoutItem(
          leading: const Icon(WaveIcons.history, size: 15),
          text: const Text('History'),
          onPressed: () => context.go('/history'),
        ),
        MenuFlyoutItem(
          leading: const Icon(WaveIcons.mixes, size: 15),
          text: const Text('Mix Lab'),
          onPressed: () => context.go('/mixes'),
        ),
        const MenuFlyoutSeparator(),
        MenuFlyoutItem(
          leading: const Icon(WaveIcons.settings, size: 15),
          text: const Text('Settings'),
          onPressed: () => context.go('/settings'),
        ),
      ],
      buttonBuilder: (context, onOpen) => _BarBtn(
        tooltip: 'Menu',
        icon: WaveIcons.more,
        onTap: onOpen,
      ),
    );
  }
}

class _WindowButtons extends StatelessWidget {
  const _WindowButtons();
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
          tooltip: 'Minimize',
          icon: FluentIcons.chrome_minimize,
          onTap: () => guard(() => windowManager.minimize()),
        ),
        _WinBtn(
          tooltip: 'Maximize',
          icon: FluentIcons.checkbox,
          onTap: () async {
            try {
              if (await windowManager.isMaximized()) {
                await windowManager.unmaximize();
              } else {
                await windowManager.maximize();
              }
            } catch (_) {}
          },
        ),
        _WinBtn(
          tooltip: 'Close',
          icon: FluentIcons.chrome_close,
          danger: true,
          onTap: () => guard(() => windowManager.close()),
        ),
      ],
    );
  }
}

class _WinBtn extends StatefulWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;
  final bool danger;
  const _WinBtn({
    required this.tooltip,
    required this.icon,
    required this.onTap,
    this.danger = false,
  });
  @override
  State<_WinBtn> createState() => _WinBtnState();
}

class _WinBtnState extends State<_WinBtn> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    return LWTooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: WaveMotion.fast,
            width: 44,
            height: WaveDensity.titleBar,
            color: _hover
                ? (widget.danger
                    ? WaveColors.danger
                    : (dark
                        ? Colors.white.withValues(
                            alpha: WaveState.hoverAlpha)
                        : Colors.black.withValues(
                            alpha: WaveState.hoverAlpha)))
                : Colors.transparent,
            child: Icon(
              widget.icon,
              size: 12,
              color: _hover && widget.danger
                  ? Colors.white
                  : (dark
                      ? WaveColors.textSecondary
                      : WaveColors.lightTextSecondary),
            ),
          ),
        ),
      ),
    );
  }
}
