import 'dart:async';
import 'dart:io' show Platform;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import '../../app/track_actions.dart' show playGenerated;
import '../../features/feed/feed_repository.dart' show GeneratedTrack;
import '../../features/lastfm/auth_repository.dart';
import '../../features/lastfm/home_repository.dart';
import '../../features/search/search_repository.dart';
import '../components/artwork.dart';
import '../../app/accessibility.dart';
import '../components/buttons.dart' show LWTooltip, WaveA11yButton;
import '../components/inputs.dart';
import '../components/menus.dart'
    show
        WaveMenuAction,
        WaveMenuButton,
        WaveMenuSeparator;
import '../navigation/wave_nav.dart';
import '../search/search_page.dart';
import '../theme/haze.dart';
import '../theme/tokens.dart';
import '../theme/brand_icons.dart';
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
  final ValueChanged<String> onGo;
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
    required this.onGo,
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
      enableBlur: false,
      base: dark
          ? waveBackground(context).withValues(alpha: 0.85)
          : waveBackground(context).withValues(alpha: 0.9),
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
                // macOS keeps the native traffic lights over the
                // chromeless window; clear their corner (the lights
                // end around x=74) instead of letting the nav buttons
                // sit underneath them.
                SizedBox(width: Platform.isMacOS ? 84 : 6),
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
                    onGo: onGo,
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
                // Community shortcuts — tiny, before the profile.
                const _CommunityBtns(),
                const SizedBox(width: 6),
                // Profile / account — tiny, no giant buttons.
                WaveA11yButton(
                  label: auth.status == AuthStatus.signedIn
                      ? 'Profile, ${auth.username}'
                      : 'Connect Last.fm',
                  onTap: () {
                    ref.read(viewingProfileProvider.notifier).clear();
                    context.go(
                      auth.status == AuthStatus.signedIn
                          ? '/profile'
                          : '/welcome',
                    );
                  },
                  child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                  onTap: () {
                    // Your avatar always means your profile: drop any
                    // stale friend view, otherwise /profile would show
                    // whoever you last checked out.
                    ref.read(viewingProfileProvider.notifier).clear();
                    context.go(
                      auth.status == AuthStatus.signedIn
                          ? '/profile'
                          : '/welcome',
                    );
                  },
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
                            ? waveSurfaceRaised(context)
                            : waveSurfaceOverlay(context),
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
                ))),
                const SizedBox(width: 6),
                _AppMenu(),
                const SizedBox(width: 6),
                // macOS draws its own traffic lights: the window is
                // `TitleBarStyle.hidden`, which hides the bar but keeps the
                // lights, so our trio would be a second, non-native set.
                if (!Platform.isMacOS) const _WindowButtons(),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// One row of the search dropdown under the title-bar input.
class _Hit {
  final String label;
  final String sub;
  final IconData icon;
  final String art;
  final bool circleArt;
  final VoidCallback onSelect;
  const _Hit({
    required this.label,
    required this.sub,
    required this.icon,
    required this.onSelect,
    this.art = '',
    this.circleArt = false,
  });
}

/// Most results the dropdown ever shows; "See all results" is extra.
const _maxHits = 4;

class _WaveSearchBox extends ConsumerStatefulWidget {
  final TextEditingController controller;
  final FocusNode focus;
  final ValueChanged<String> onSubmit;
  final ValueChanged<String> onGo;
  final VoidCallback onPalette;
  const _WaveSearchBox({
    required this.controller,
    required this.focus,
    required this.onSubmit,
    required this.onGo,
    required this.onPalette,
  });
  @override
  ConsumerState<_WaveSearchBox> createState() => _WaveSearchBoxState();
}

class _WaveSearchBoxState extends ConsumerState<_WaveSearchBox> {
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  final _panelKey = GlobalKey();
  Timer? _debounce;
  String _liveQ = '';
  int _selected = -1;
  // Rows for the current frame; built in build() (the only place providers
  // may be watched) and read by the overlay and key handlers.
  List<_Hit> _shown = const [];

  @override
  void initState() {
    super.initState();
    widget.focus.addListener(_onFocus);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    widget.focus.removeListener(_onFocus);
    super.dispose();
  }

  void _onFocus() {
    if (!mounted) return;
    if (widget.focus.hasFocus) {
      _selected = -1;
      _portal.show();
    } else {
      _portal.hide();
    }
    setState(() {});
  }

  void _onChanged(String v) {
    setState(() => _selected = -1);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => _liveQ = v.trim());
    });
  }

  /// Dropdown rows: recent searches while the field is empty, otherwise
  /// at most [_maxHits] live results (songs first, one album, one artist)
  /// followed by "See all results".
  List<_Hit> _hits() {
    final typed = widget.controller.text.trim();
    if (typed.isEmpty) {
      return [
        for (final h
            in ref.read(searchRepositoryProvider).history().take(_maxHits))
          _Hit(
            label: h,
            sub: 'Recent',
            icon: WaveIcons.history,
            onSelect: () {
              widget.controller.text = h;
              widget.onSubmit(h);
            },
          ),
      ];
    }
    final hits = <_Hit>[];
    if (_liveQ.isNotEmpty) {
      final songs = ref.watch(waveSearchSongsProvider(_liveQ)).valueOrNull ??
          const <SearchResultItem>[];
      final albums =
          ref.watch(waveSearchAlbumsProvider(_liveQ)).valueOrNull ??
              const <SearchResultItem>[];
      final artists =
          ref.watch(waveSearchArtistsProvider(_liveQ)).valueOrNull ??
              const <SearchResultItem>[];
      _Hit song(SearchResultItem s) => _Hit(
            label: s.name,
            sub: s.artist.isNotEmpty ? 'Song • ${s.artist}' : 'Song',
            icon: WaveIcons.music,
            art: s.artworkUrl,
            onSelect: () => playGenerated(
              ref,
              context,
              GeneratedTrack(
                name: s.name,
                artist: s.artist,
                album: s.subtitle,
                artworkUrl: s.artworkUrl,
                videoId: s.videoId,
              ),
              sourceLabel: 'Search',
            ),
          );
      final picked = <_Hit>[
        for (final s in songs.take(2)) song(s),
        for (final a in albums.take(1))
          _Hit(
            label: a.name,
            sub: a.artist.isNotEmpty ? 'Album • ${a.artist}' : 'Album',
            icon: WaveIcons.albums,
            art: a.artworkUrl,
            onSelect: () {
              if (a.entityId.isEmpty) return;
              widget.onGo(waveAlbumLocation(
                browseId: a.entityId,
                title: a.name,
                artist: a.artist,
                artworkUrl: a.artworkUrl,
              ));
            },
          ),
        for (final a in artists.take(1))
          _Hit(
            label: a.name,
            sub: 'Artist',
            icon: FluentIcons.contact,
            art: a.artworkUrl,
            circleArt: true,
            onSelect: () =>
                widget.onGo('/artist/${Uri.encodeComponent(a.name)}'),
          ),
      ];
      // Top up with more songs when albums/artists came back short.
      for (final s in songs.skip(2)) {
        if (picked.length >= _maxHits) break;
        picked.add(song(s));
      }
      hits.addAll(picked.take(_maxHits));
    }
    hits.add(_Hit(
      label: 'See all results for “$typed”',
      sub: 'Open the full Search page',
      icon: WaveIcons.search,
      onSelect: () => widget.onSubmit(typed),
    ));
    return hits;
  }

  String _announcedFor = '';

  /// Tells a screen-reader user that suggestions arrived and how to reach
  /// them: the dropdown is an overlay, so nothing else would announce it.
  /// Spoken once per settled query, after the live results have loaded.
  void _announceSuggestions() {
    if (!widget.focus.hasFocus || _liveQ.isEmpty) return;
    if (_liveQ != widget.controller.text.trim()) return;
    final count = _shown.length - 1; // last row is "See all results"
    final key = '$_liveQ|$count';
    if (key == _announcedFor || count <= 0) return;
    _announcedFor = key;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      AppAccessibility.announce(
        context,
        '$count suggestion${count == 1 ? '' : 's'}. '
        'Use up and down arrows to browse, Enter to open.',
      );
    });
  }

  void _activate(_Hit hit) {
    _portal.hide();
    widget.focus.unfocus();
    hit.onSelect();
  }

  KeyEventResult _onKey(KeyEvent event) {
    if (event is! KeyDownEvent || !widget.focus.hasFocus) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      if (_selected >= 0 || _portal.isShowing) {
        setState(() => _selected = -1);
        _portal.hide();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key != LogicalKeyboardKey.arrowDown &&
        key != LogicalKeyboardKey.arrowUp) {
      return KeyEventResult.ignored;
    }
    final hits = _shown;
    if (hits.isEmpty) return KeyEventResult.handled;
    if (!_portal.isShowing) _portal.show();
    setState(() {
      _selected = key == LogicalKeyboardKey.arrowDown
          ? (_selected + 1).clamp(0, hits.length - 1)
          : (_selected - 1).clamp(-1, hits.length - 1);
    });
    // The highlighted row lives in an overlay while keyboard focus stays in
    // the text field, so a screen reader would never hear it move. Speak it.
    if (_selected >= 0) {
      final hit = hits[_selected];
      AppAccessibility.announce(
        context,
        '${hit.label}, ${hit.sub}, ${_selected + 1} of ${hits.length}',
      );
    } else {
      AppAccessibility.announce(context, 'Search field');
    }
    return KeyEventResult.handled;
  }

  void _submit(String v) {
    final hits = _shown;
    if (_selected >= 0 && _selected < hits.length) {
      _activate(hits[_selected]);
      return;
    }
    _portal.hide();
    widget.focus.unfocus();
    widget.onSubmit(v);
  }

  bool _insidePanel(Offset globalPosition) {
    final box = _panelKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached) return false;
    return (box.localToGlobal(Offset.zero) & box.size)
        .contains(globalPosition);
  }

  Widget _panel(BuildContext overlayContext) {
    final dark = waveIsDark(overlayContext);
    final hits = _shown;
    if (hits.isEmpty) return const SizedBox.shrink();
    final box = context.findRenderObject();
    final width = box is RenderBox ? box.size.width : 320.0;
    return CompositedTransformFollower(
      link: _link,
      targetAnchor: Alignment.bottomLeft,
      followerAnchor: Alignment.topLeft,
      offset: const Offset(0, 6),
      showWhenUnlinked: false,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width < 320 ? 320 : width,
          child: _PanelIn(child: Container(
            key: _panelKey,
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: dark
                  ? waveSurfaceRaised(overlayContext)
                  : waveSurfaceOverlay(overlayContext),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: waveDivider(overlayContext)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.28),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < hits.length; i++)
                  ListTile.selectable(
                    shape: RoundedRectangleBorder(
                      borderRadius: WaveRadius.controlsRadius,
                    ),
                    selected: i == _selected,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    selectionMode: ListTileSelectionMode.single,
                    leading: SizedBox(
                      width: 28,
                      height: 28,
                      child: hits[i].art.isNotEmpty
                          ? (hits[i].circleArt
                              ? WaveArtwork.circle(
                                  url: hits[i].art,
                                  size: 28,
                                  label: hits[i].label,
                                )
                              : WaveArtwork(
                                  url: hits[i].art,
                                  size: 28,
                                  radius: WaveRadius.artwork,
                                  label: hits[i].label,
                                ))
                          : Icon(hits[i].icon, size: 15),
                    ),
                    title: Text(
                      hits[i].label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      hits[i].sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onPressed: () => _activate(hits[i]),
                  ),
              ],
            ),
          ),)
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final tertiary =
        dark ? WaveColors.textTertiary : WaveColors.lightTextTertiary;
    _shown = _hits();
    _announceSuggestions();
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: _panel,
        child: LWTooltip(
          message: 'Search (Ctrl+F)',
          child: SizedBox(
            width: double.infinity,
            height: 30,
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onKeyEvent: (_, e) => _onKey(e),
              child: Semantics(
                label: 'Search songs, albums and artists',
                hint: 'Type to see suggestions, Enter to search',
                textField: true,
                child: TextBox(
                decoration: waveInputDecoration(radius: 8),
                controller: widget.controller,
                focusNode: widget.focus,
                placeholder: 'Search',
                style: WaveType.body.copyWith(fontSize: 13),
                cursorHeight: 14,
                onTapOutside: (e) {
                  if (_insidePanel(e.position)) return;
                  if (widget.focus.hasFocus) widget.focus.unfocus();
                },
                prefix: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(WaveIcons.search, size: 15, color: tertiary),
                ),
                suffix: widget.controller.text.isNotEmpty
                    ? Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: IconButton(
                            icon: const Icon(FluentIcons.chrome_close,
                                size: 10, semanticLabel: 'Clear search'),
                            onPressed: () {
                              widget.controller.clear();
                              _onChanged('');
                              widget.focus.requestFocus();
                            },
                          ),
                        ),
                      )
                    : widget.focus.hasFocus
                        ? null
                        : Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: IgnorePointer(
                              child: Text(
                                'Ctrl F',
                                semanticsLabel: 'Shortcut Control F',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w500,
                                  letterSpacing: 0.2,
                                  color: tertiary.withValues(alpha: 0.7),
                                ),
                              ),
                            ),
                          ),
                onChanged: _onChanged,
                onSubmitted: _submit,
              ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Short fade + rise so the dropdown settles in instead of popping.
class _PanelIn extends StatelessWidget {
  final Widget child;
  const _PanelIn({required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, (1 - t) * -4), child: child),
      ),
      child: child,
    );
  }
}

class _BarBtn extends StatefulWidget {
  final String tooltip;
  final IconData? icon;
  final Widget? iconWidget;
  final VoidCallback? onTap;
  const _BarBtn(
      {required this.tooltip, this.icon, this.iconWidget, this.onTap})
      : assert(icon != null || iconWidget != null,
            'Provide icon or iconWidget');
  @override
  State<_BarBtn> createState() => _BarBtnState();
}

class _BarBtnState extends State<_BarBtn> {
  bool _hover = false;
  bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    return WaveA11yButton(
      label: widget.tooltip,
      onTap: widget.onTap,
      child: LWTooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
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
            duration: waveMotion(context, WaveMotion.fast),
            width: WaveDensity.hitArea,
            height: WaveDensity.hitArea,
            decoration: BoxDecoration(
              color: _pressed
                  ? wavePressedWash(context)
                  : _hover
                      ? waveHoverWash(context)
                      : Colors.transparent,
              borderRadius:
                  BorderRadius.circular(WaveRadius.controls),
            ),
            child: Builder(
              builder: (context) {
                final fg = widget.onTap == null
                    ? (dark
                            ? WaveColors.textTertiary
                            : WaveColors.lightTextTertiary)
                        .withValues(alpha: 0.4)
                    : (dark
                        ? WaveColors.textSecondary
                        : WaveColors.lightTextSecondary);
                if (widget.iconWidget != null) {
                  return IconTheme(
                    data: IconThemeData(color: fg, size: 15),
                    child: Center(child: widget.iconWidget!),
                  );
                }
                return Icon(
                  widget.icon,
                  size: 15,
                  color: fg,
                );
              },
            ),
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
    return WaveMenuButton(
      placement: FlyoutPlacementMode.bottomRight,
      entries: [
        WaveMenuAction(
          leading: const Icon(WaveIcons.search, size: 15),
          label: 'Search',
          hint: 'Ctrl+K',
          onPressed: () => context.go('/search'),
        ),
        const WaveMenuSeparator(),
        WaveMenuAction(
          leading: const Icon(WaveIcons.history, size: 15),
          label: 'History',
          onPressed: () => context.go('/history'),
        ),
        WaveMenuAction(
          leading: const Icon(WaveIcons.mixes, size: 15),
          label: 'Mix Lab',
          onPressed: () => context.go('/mixes'),
        ),
        const WaveMenuSeparator(),
        WaveMenuAction(
          leading: const Icon(WaveIcons.settings, size: 15),
          label: 'Settings',
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

/// Telegram + Discord shortcuts in the title bar (external links,
/// silent fail — never disturb the shell on error).
class _CommunityBtns extends StatelessWidget {
  const _CommunityBtns();

  static const _telegramUrl = 'https://t.me/clashprojects';
  static const _discordUrl = 'https://discord.com/invite/TMCEPSUNk2';

  Future<void> _open(String url) async {
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _BarBtn(
          tooltip: 'Telegram community',
          iconWidget: const TelegramIcon(size: 15),
          onTap: () => _open(_telegramUrl),
        ),
        const SizedBox(width: 2),
        _BarBtn(
          tooltip: 'Discord server',
          iconWidget: const DiscordIcon(size: 15),
          onTap: () => _open(_discordUrl),
        ),
      ],
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
    return WaveA11yButton(
      label: widget.tooltip,
      onTap: widget.onTap,
      child: LWTooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: waveMotion(context, WaveMotion.fast),
            width: 44,
            height: WaveDensity.titleBar,
            color: _hover
                ? (widget.danger
                    ? WaveColors.danger
                    : waveHoverWash(context))
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
    ),
    );
  }
}
