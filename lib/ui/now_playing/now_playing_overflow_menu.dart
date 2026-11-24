import 'dart:async';
import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart' hide Colors;
import 'package:flutter/material.dart' show Colors;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/stream_models.dart';
import '../../core/storage/prefs.dart';
import '../../features/lyrics/karaoke_lyrics_view.dart';
import '../../features/lyrics/lyrics_providers.dart';
import '../components/ambient.dart';
import '../components/menus.dart';
import '../lyrics/lyrics_panel.dart'
    show
        lyricsExcludedProvidersProvider,
        lyricsProviderOverrideProvider,
        waveLyricsProvider;
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';
import 'immersive.dart';
import 'now_playing_style.dart';

/// Unified top-right action bar shared across all Now Playing styles:
/// Ambient (Standard & Minimal), Fullscreen, and Overflow (`...`).
class NowPlayingTopActions extends ConsumerWidget {
  final PlayableTrack track;
  final bool showAmbientToggle;
  final VoidCallback? onToggleLyrics;
  final bool lyricsVisible;
  final VoidCallback? onToggleFocus;
  final bool focusMode;
  final VoidCallback? onInteraction;

  const NowPlayingTopActions({
    super.key,
    required this.track,
    this.showAmbientToggle = true,
    this.onToggleLyrics,
    this.lyricsVisible = true,
    this.onToggleFocus,
    this.focusMode = false,
    this.onInteraction,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ambientEnabled = ref.watch(visualizerEnabledProvider);
    final isImmersive = ref.watch(nowPlayingImmersiveProvider);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showAmbientToggle) ...[
          _QuickActionButton(
            icon: WaveIcons.visualizer,
            tooltip: ambientEnabled ? 'Disable ambient' : 'Enable ambient',
            active: ambientEnabled,
            onTap: () {
              onInteraction?.call();
              ref.read(visualizerEnabledProvider.notifier).toggle();
            },
          ),
          const SizedBox(width: 6),
        ],
        _QuickActionButton(
          icon: isImmersive ? FluentIcons.mini_contract : WaveIcons.expand,
          tooltip: isImmersive ? 'Exit fullscreen (F11)' : 'Fullscreen (F11)',
          active: isImmersive,
          onTap: () {
            onInteraction?.call();
            ref.read(nowPlayingImmersiveProvider.notifier).state = !isImmersive;
          },
        ),
        const SizedBox(width: 8),
        NowPlayingOverflowMenuButton(
          track: track,
          showAmbientToggle: showAmbientToggle,
          onToggleLyrics: onToggleLyrics,
          lyricsVisible: lyricsVisible,
          onToggleFocus: onToggleFocus,
          focusMode: focusMode,
          onInteraction: onInteraction,
        ),
      ],
    );
  }
}

/// Shared overflow menu button and frosted popover used by all Now Playing styles.
class NowPlayingOverflowMenuButton extends ConsumerStatefulWidget {
  final PlayableTrack track;
  final bool showAmbientToggle;
  final VoidCallback? onToggleLyrics;
  final bool lyricsVisible;
  final VoidCallback? onToggleFocus;
  final bool focusMode;
  final VoidCallback? onInteraction;
  final Widget? icon;

  const NowPlayingOverflowMenuButton({
    super.key,
    required this.track,
    this.showAmbientToggle = true,
    this.onToggleLyrics,
    this.lyricsVisible = true,
    this.onToggleFocus,
    this.focusMode = false,
    this.onInteraction,
    this.icon,
  });

  @override
  ConsumerState<NowPlayingOverflowMenuButton> createState() =>
      _NowPlayingOverflowMenuButtonState();
}

class _NowPlayingOverflowMenuButtonState
    extends ConsumerState<NowPlayingOverflowMenuButton> {
  final _controller = FlyoutController();
  bool _menuOpen = false;
  StateController<bool>? _menuOpenCtrl;
  StateController<int>? _activityCtrl;

  @override
  void dispose() {
    if (_menuOpen) {
      _menuOpen = false;
      final menuOpen = _menuOpenCtrl;
      final activity = _activityCtrl;
      Future.microtask(() {
        if (menuOpen != null && menuOpen.mounted) menuOpen.state = false;
        if (activity != null && activity.mounted) activity.state++;
      });
    }
    _controller.dispose();
    super.dispose();
  }

  void _open() {
    widget.onInteraction?.call();
    final menuOpen = ref.read(nowPlayingMenuOpenProvider.notifier);
    final activity = ref.read(nowPlayingActivityProvider.notifier);
    _menuOpenCtrl = menuOpen;
    _activityCtrl = activity;
    _menuOpen = true;
    menuOpen.state = true;
    unawaited(
      _controller
          .showFlyout(
            barrierColor: Colors.transparent,
            placementMode: FlyoutPlacementMode.bottomRight,
            autoModeConfiguration: FlyoutAutoConfiguration(
              preferredMode: FlyoutPlacementMode.bottomRight,
            ),
            transitionDuration: const Duration(milliseconds: 90),
            transitionBuilder: fastFlyoutTransition,
            builder: (context) => WaveFlyoutPanel.child(
              maxWidth: 300,
              maxHeight: 540,
              child: _NowPlayingOverflowMenuContent(
                track: widget.track,
                showAmbientToggle: widget.showAmbientToggle,
                onToggleLyrics: widget.onToggleLyrics,
                lyricsVisible: widget.lyricsVisible,
                onToggleFocus: widget.onToggleFocus,
                focusMode: widget.focusMode,
              ),
            ),
          )
          .whenComplete(() {
            _menuOpen = false;
            if (menuOpen.mounted) menuOpen.state = false;
            if (activity.mounted) activity.state++;
          }),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.icon != null) {
      return FlyoutTarget(
        controller: _controller,
        child: GestureDetector(
          onTap: _open,
          behavior: HitTestBehavior.opaque,
          child: widget.icon!,
        ),
      );
    }

    return FlyoutTarget(
      controller: _controller,
      child: _CircularIconButton(
        icon: FluentIcons.more,
        onTap: _open,
        tooltip: 'More options',
      ),
    );
  }
}

class _NowPlayingOverflowMenuContent extends ConsumerStatefulWidget {
  final PlayableTrack track;
  final bool showAmbientToggle;
  final VoidCallback? onToggleLyrics;
  final bool lyricsVisible;
  final VoidCallback? onToggleFocus;
  final bool focusMode;

  const _NowPlayingOverflowMenuContent({
    required this.track,
    this.showAmbientToggle = true,
    this.onToggleLyrics,
    this.lyricsVisible = true,
    this.onToggleFocus,
    this.focusMode = false,
  });

  @override
  ConsumerState<_NowPlayingOverflowMenuContent> createState() =>
      _NowPlayingOverflowMenuContentState();
}

class _NowPlayingOverflowMenuContentState
    extends ConsumerState<_NowPlayingOverflowMenuContent> {
  _CascadingSubmenuRowState? _openSubmenu;
  Timer? _submenuCloseTimer;
  late bool _lyricsVisible;
  late bool _focusMode;

  @override
  void initState() {
    super.initState();
    _lyricsVisible = widget.lyricsVisible;
    _focusMode = widget.focusMode;
  }

  @override
  void dispose() {
    _submenuCloseTimer?.cancel();
    super.dispose();
  }

  void _onSubmenuOpened(_CascadingSubmenuRowState submenu) {
    _submenuCloseTimer?.cancel();
    _submenuCloseTimer = null;
    if (_openSubmenu != null && _openSubmenu != submenu) {
      _openSubmenu!.close();
    }
    _openSubmenu = submenu;
  }

  void _cancelCloseSubmenu() {
    _submenuCloseTimer?.cancel();
    _submenuCloseTimer = null;
  }

  void _scheduleCloseSubmenu() {
    if (_openSubmenu == null) return;
    _submenuCloseTimer?.cancel();
    // Forgiving grace window so diagonal pointer movement toward the open
    // submenu never closes it when grazing another row.
    _submenuCloseTimer = Timer(const Duration(milliseconds: 340), () {
      _submenuCloseTimer = null;
      if (!mounted) return;
      _openSubmenu?.close();
      _openSubmenu = null;
    });
  }

  bool _hasOtherSubmenuOpen(_CascadingSubmenuRowState row) =>
      _openSubmenu != null && _openSubmenu != row;

  void _bumpLyricsPrefs() {
    ref.read(lyricsPrefsRevisionProvider.notifier).state++;
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(lyricsPrefsRevisionProvider);
    final dark = waveIsDark(context);
    final accent = waveAccent(context);
    final track = widget.track;
    final queueKey = track.queueKey;

    final offsetMs = ref.watch(lyricsOffsetProvider(queueKey));
    final offsetNotifier = ref.read(lyricsOffsetProvider(queueKey).notifier);
    final offsetDisplay = formatOffsetDisplay(offsetMs);

    final showTransliteration = ref.watch(lyricsTransliterationProvider);
    final transliterationNotifier = ref.read(
      lyricsTransliterationProvider.notifier,
    );

    final prefs = ref.watch(prefsProvider);
    final translationLang = prefs.lyricsTranslationLang;
    final translationActive = translationLang != 'off';
    final translationLabel =
        Prefs.lyricsTranslationOptions[translationLang] ?? 'Off';

    final textScale = prefs.lyricsTextScale;
    final textScaleLabel =
        Prefs.lyricsTextScales
            .where((e) => e.$1 == textScale)
            .map((e) => e.$2)
            .firstOrNull ??
        'Medium';

    final animationKey = prefs.lyricsAnimation;
    final animationLabel =
        Prefs.lyricsAnimationOptions[animationKey] ?? 'Apple Fluid';

    // Lyrics provider state (matches _SourceMenu in KaraokeLyricsView)
    final override = ref.watch(lyricsProviderOverrideProvider(queueKey));
    final defaultId = prefs.lyricsProviderId;
    final effectiveProviderId = override ?? defaultId;
    final lyricsAsync = ref.watch(waveLyricsProvider(track));
    final resolvedSource = lyricsAsync.valueOrNull?.source ?? '';
    final currentResolvedId = lyricsSourceToProviderId(resolvedSource);
    final providerHint = resolvedSource.isNotEmpty
        ? resolvedSource
        : LyricsProviderId.fromId(effectiveProviderId).title;

    void selectProvider(String? pickedId) {
      if (pickedId == null) {
        ref.read(lyricsExcludedProvidersProvider(queueKey).notifier).state =
            retryLyricsExcludingCurrent(
              currentId: currentResolvedId,
              excludes: ref.read(lyricsExcludedProvidersProvider(queueKey)),
            );
      } else {
        final next = nextLyricsSelection(
          pickedId: pickedId,
          currentId: currentResolvedId,
          currentExcludes: ref.read(lyricsExcludedProvidersProvider(queueKey)),
        );
        ref.read(lyricsProviderOverrideProvider(queueKey).notifier).state =
            next.override;
        ref.read(lyricsExcludedProvidersProvider(queueKey).notifier).state =
            next.excludes;
      }
      ref.invalidate(waveLyricsProvider(track));
    }

    final ambientEnabled = ref.watch(visualizerEnabledProvider);
    final isImmersive = ref.watch(nowPlayingImmersiveProvider);
    final currentStyle = ref.watch(nowPlayingStyleProvider);

    Widget menuMark(bool on) => on
        ? Icon(FluentIcons.check_mark, size: 12, color: accent)
        : const SizedBox(width: 12);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. Timing Offset Row (stays open while tapping)
        MouseRegion(
          opaque: false,
          onEnter: (_) => _scheduleCloseSubmenu(),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Lyrics offset',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: waveTextPrimary(context),
                        ),
                      ),
                      if (offsetMs != 0)
                        Text(
                          offsetDisplay,
                          style: TextStyle(
                            fontSize: 11,
                            color: accent,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 2,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: (dark ? Colors.white : Colors.black).withValues(
                      alpha: 0.08,
                    ),
                    borderRadius: BorderRadius.circular(WaveRadius.controls),
                    border: Border.all(
                      color: (dark ? Colors.white : Colors.black).withValues(
                        alpha: 0.12,
                      ),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _StepperBtn(
                        icon: FluentIcons.remove,
                        tooltip: '-0.5s',
                        onTap: () => offsetNotifier.adjust(-500),
                      ),
                      Container(
                        constraints: const BoxConstraints(minWidth: 42),
                        alignment: Alignment.center,
                        child: Text(
                          offsetDisplay,
                          style: TextStyle(
                            fontSize: 12,
                            fontFeatures: const [FontFeature.tabularFigures()],
                            fontWeight: FontWeight.w600,
                            color: offsetMs != 0
                                ? accent
                                : waveTextPrimary(context),
                          ),
                        ),
                      ),
                      _StepperBtn(
                        icon: FluentIcons.add,
                        tooltip: '+0.5s',
                        onTap: () => offsetNotifier.adjust(500),
                      ),
                      if (offsetMs != 0) ...[
                        const SizedBox(width: 2),
                        _StepperBtn(
                          icon: FluentIcons.clear,
                          tooltip: 'Reset to 0.0s',
                          onTap: offsetNotifier.reset,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Container(height: 1, color: waveDivider(context)),
        ),

        // 2. Cascading Second-Panel Submenus (Lyrics source, Romanisation, Translation, Text size, Animation)
        _CascadingSubmenuRow(
          icon: WaveIcons.lyrics,
          title: 'Lyrics source',
          hint: providerHint,
          active: effectiveProviderId != 'auto',
          onOpened: _onSubmenuOpened,
          onSubmenuActivity: _cancelCloseSubmenu,
          hasOtherOpenSubmenu: _hasOtherSubmenuOpen,
          items: () => [
            for (final provider in LyricsProviderId.values)
              WaveMenuAction(
                leading: menuMark(effectiveProviderId == provider.id),
                label: provider.title,
                onPressed: () => selectProvider(provider.id),
              ),
            const WaveMenuSeparator(),
            WaveMenuAction(
              leading: const Icon(FluentIcons.refresh, size: 13),
              label: 'Try another source',
              onPressed: () => selectProvider(null),
            ),
          ],
        ),
        _CascadingSubmenuRow(
          icon: FluentIcons.reading_mode,
          title: 'Romanisation',
          hint: showTransliteration ? 'On' : 'Off',
          active: showTransliteration,
          onOpened: _onSubmenuOpened,
          onSubmenuActivity: _cancelCloseSubmenu,
          hasOtherOpenSubmenu: _hasOtherSubmenuOpen,
          items: () => [
            WaveMenuAction(
              leading: menuMark(!showTransliteration),
              label: 'Off',
              onPressed: () => transliterationNotifier.setEnabled(false),
            ),
            WaveMenuAction(
              leading: menuMark(showTransliteration),
              label: 'On',
              onPressed: () => transliterationNotifier.setEnabled(true),
            ),
          ],
        ),
        _CascadingSubmenuRow(
          icon: FluentIcons.locale_language,
          title: 'Translation',
          hint: translationLabel,
          active: translationActive,
          onOpened: _onSubmenuOpened,
          onSubmenuActivity: _cancelCloseSubmenu,
          hasOtherOpenSubmenu: _hasOtherSubmenuOpen,
          items: () => [
            for (final entry in Prefs.lyricsTranslationOptions.entries)
              WaveMenuAction(
                leading: menuMark(translationLang == entry.key),
                label: entry.value,
                onPressed: () async {
                  await ref
                      .read(prefsProvider)
                      .setLyricsTranslationLang(entry.key);
                  _bumpLyricsPrefs();
                },
              ),
          ],
        ),
        _CascadingSubmenuRow(
          icon: FluentIcons.font_size,
          title: 'Text size',
          hint: textScaleLabel,
          active: textScale != 1.0,
          onOpened: _onSubmenuOpened,
          onSubmenuActivity: _cancelCloseSubmenu,
          hasOtherOpenSubmenu: _hasOtherSubmenuOpen,
          items: () => [
            for (final entry in Prefs.lyricsTextScales)
              WaveMenuAction(
                leading: menuMark(textScale == entry.$1),
                label: entry.$2,
                onPressed: () async {
                  await ref.read(prefsProvider).setLyricsTextScale(entry.$1);
                  _bumpLyricsPrefs();
                },
              ),
          ],
        ),
        _CascadingSubmenuRow(
          icon: FluentIcons.brush,
          title: 'Animation style',
          hint: animationLabel,
          onOpened: _onSubmenuOpened,
          onSubmenuActivity: _cancelCloseSubmenu,
          hasOtherOpenSubmenu: _hasOtherSubmenuOpen,
          items: () => [
            for (final entry in Prefs.lyricsAnimationOptions.entries)
              WaveMenuAction(
                leading: menuMark(animationKey == entry.key),
                label: entry.value,
                onPressed: () async {
                  await ref.read(prefsProvider).setLyricsAnimation(entry.key);
                  _bumpLyricsPrefs();
                },
              ),
          ],
        ),

        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Container(height: 1, color: waveDivider(context)),
        ),

        // 3. View & Mode Toggles
        if (widget.onToggleLyrics != null)
          _MenuActionTile(
            icon: WaveIcons.lyrics,
            title: 'Lyrics',
            hint: _lyricsVisible ? 'Visible' : 'Hidden',
            active: _lyricsVisible,
            onHoverEnter: _scheduleCloseSubmenu,
            onTap: () {
              setState(() {
                _lyricsVisible = !_lyricsVisible;
                if (!_lyricsVisible) _focusMode = false;
              });
              widget.onToggleLyrics!();
            },
          ),
        if (widget.onToggleFocus != null)
          _MenuActionTile(
            icon: _focusMode ? FluentIcons.mini_contract : WaveIcons.expand,
            title: 'Focus on lyrics',
            hint: _focusMode ? 'On' : 'Off',
            active: _focusMode,
            onHoverEnter: _scheduleCloseSubmenu,
            onTap: () {
              setState(() {
                _focusMode = !_focusMode;
                if (_focusMode) _lyricsVisible = true;
              });
              widget.onToggleFocus!();
            },
          ),
        if (widget.showAmbientToggle)
          _MenuActionTile(
            icon: WaveIcons.visualizer,
            title: 'Ambient',
            hint: ambientEnabled ? 'On' : 'Off',
            active: ambientEnabled,
            onHoverEnter: _scheduleCloseSubmenu,
            onTap: () => ref.read(visualizerEnabledProvider.notifier).toggle(),
          ),
        _MenuActionTile(
          icon: isImmersive ? FluentIcons.mini_contract : WaveIcons.expand,
          title: 'Fullscreen',
          hint: 'F11',
          active: isImmersive,
          onHoverEnter: _scheduleCloseSubmenu,
          onTap: () {
            ref.read(nowPlayingImmersiveProvider.notifier).state = !isImmersive;
          },
        ),

        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Container(height: 1, color: waveDivider(context)),
        ),

        // 4. Inline Layout Switcher (bottom section of the menu)
        MouseRegion(
          opaque: false,
          onEnter: (_) => _scheduleCloseSubmenu(),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'NOW PLAYING STYLE',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: waveTextTertiary(context),
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: (dark ? Colors.white : Colors.black).withValues(
                      alpha: 0.08,
                    ),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: (dark ? Colors.white : Colors.black).withValues(
                        alpha: 0.08,
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      for (final style in NowPlayingStyle.values)
                        Expanded(
                          child: GestureDetector(
                            onTap: () {
                              ref
                                  .read(nowPlayingStyleProvider.notifier)
                                  .set(style);
                            },
                            behavior: HitTestBehavior.opaque,
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              decoration: BoxDecoration(
                                color: currentStyle == style
                                    ? (dark
                                        ? Colors.white.withValues(alpha: 0.16)
                                        : Colors.black.withValues(alpha: 0.12))
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(6),
                                border: currentStyle == style
                                    ? Border.all(
                                        color: accent.withValues(alpha: 0.5),
                                        width: 1,
                                      )
                                    : null,
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                style.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: currentStyle == style
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                  color: currentStyle == style
                                      ? waveTextPrimary(context)
                                      : waveTextSecondary(context),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Cascading submenu row that opens a second [WaveFlyoutPanel] to the side
/// (flipping left automatically when near the right window edge), matching
/// standard Fluent desktop menus without bloating the main popover.
class _CascadingSubmenuRow extends StatefulWidget {
  final IconData icon;
  final String title;
  final String? hint;
  final bool active;
  final List<WaveMenuEntry> Function() items;
  final ValueChanged<_CascadingSubmenuRowState> onOpened;
  final VoidCallback? onSubmenuActivity;
  final bool Function(_CascadingSubmenuRowState)? hasOtherOpenSubmenu;

  const _CascadingSubmenuRow({
    required this.icon,
    required this.title,
    this.hint,
    this.active = false,
    required this.items,
    required this.onOpened,
    this.onSubmenuActivity,
    this.hasOtherOpenSubmenu,
  });

  @override
  State<_CascadingSubmenuRow> createState() => _CascadingSubmenuRowState();
}

class _CascadingSubmenuRowState extends State<_CascadingSubmenuRow> {
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  Timer? _hoverTimer;
  bool _hover = false;
  bool _flipLeft = true;
  bool _openUp = false;
  double? _maxHeight;

  @override
  void dispose() {
    _hoverTimer?.cancel();
    super.dispose();
  }

  void close() {
    _hoverTimer?.cancel();
    if (_portal.isShowing) {
      _portal.hide();
      if (mounted) setState(() {});
    }
  }

  void openNow() {
    _hoverTimer?.cancel();
    if (_portal.isShowing) {
      widget.onSubmenuActivity?.call();
      return;
    }
    final box = context.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      final topLeft = box.localToGlobal(Offset.zero);
      final right = topLeft.dx + box.size.width;
      final screen = MediaQuery.sizeOf(context);
      _flipLeft = right + 260 > screen.width;
      const margin = 12.0;
      final cap = math.min(screen.height * 0.65, 380.0);
      final below = screen.height - topLeft.dy - margin;
      final above = topLeft.dy + box.size.height - margin;
      _openUp = below < math.min(cap, 200.0) && above > below;
      _maxHeight = math.max(120.0, math.min(cap, _openUp ? above : below));
    }
    _portal.show();
    widget.onOpened(this);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);

    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: (context) => Align(
          alignment: Alignment.topLeft,
          child: CompositedTransformFollower(
            link: _link,
            showWhenUnlinked: false,
            targetAnchor: _openUp
                ? (_flipLeft ? Alignment.bottomLeft : Alignment.bottomRight)
                : (_flipLeft ? Alignment.topLeft : Alignment.topRight),
            followerAnchor: _openUp
                ? (_flipLeft ? Alignment.bottomRight : Alignment.bottomLeft)
                : (_flipLeft ? Alignment.topRight : Alignment.topLeft),
            offset: Offset(
              0,
              _openUp ? WaveMenuRow.inset : -WaveMenuRow.inset,
            ),
            // Padded bridge inside MouseRegion removes the dead gap between
            // the main menu and the submenu panel so diagonal movement never
            // drops hover. `closeOnAction: false` keeps the submenu open while
            // previewing lyrics sources, animations, text sizes, etc.
            child: MouseRegion(
              onEnter: (_) => widget.onSubmenuActivity?.call(),
              child: Padding(
                padding: EdgeInsets.only(
                  right: _flipLeft ? 6 : 0,
                  left: _flipLeft ? 0 : 6,
                ),
                child: WaveFlyoutPanel.items(
                  entries: widget.items(),
                  maxHeight: _maxHeight,
                  closeOnAction: false,
                ),
              ),
            ),
          ),
        ),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) {
            setState(() => _hover = true);
            if (_portal.isShowing) {
              widget.onSubmenuActivity?.call();
              return;
            }
            _hoverTimer?.cancel();
            // Longer delay when switching away from an already-open submenu so
            // grazing a neighbor row on a diagonal path never hijacks it.
            final delayMs =
                (widget.hasOtherOpenSubmenu?.call(this) ?? false) ? 340 : 140;
            _hoverTimer = Timer(Duration(milliseconds: delayMs), openNow);
          },
          onExit: (_) {
            setState(() => _hover = false);
            _hoverTimer?.cancel();
          },
          child: GestureDetector(
            onTap: openNow,
            behavior: HitTestBehavior.opaque,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: (_hover || _portal.isShowing)
                    ? (dark ? Colors.white : Colors.black).withValues(
                        alpha: 0.08,
                      )
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(WaveRadius.controls),
              ),
              child: Row(
                children: [
                  Icon(
                    widget.icon,
                    size: 15,
                    color: widget.active ? accent : waveTextSecondary(context),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: waveTextPrimary(context),
                        fontWeight: widget.active
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                  if (widget.hint != null) ...[
                    Flexible(
                      flex: 0,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 92),
                        child: Text(
                          widget.hint!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: widget.active
                                ? accent
                                : waveTextTertiary(context),
                            fontWeight: widget.active
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Icon(
                    FluentIcons.chevron_right,
                    size: 10,
                    color: waveTextTertiary(context),
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

class _MenuActionTile extends StatefulWidget {
  final IconData icon;
  final String title;
  final String? hint;
  final bool active;
  final VoidCallback? onHoverEnter;
  final VoidCallback onTap;

  const _MenuActionTile({
    required this.icon,
    required this.title,
    this.hint,
    this.active = false,
    this.onHoverEnter,
    required this.onTap,
  });

  @override
  State<_MenuActionTile> createState() => _MenuActionTileState();
}

class _MenuActionTileState extends State<_MenuActionTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        widget.onHoverEnter?.call();
        setState(() => _hover = true);
      },
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: _hover
                ? (dark ? Colors.white : Colors.black).withValues(alpha: 0.08)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(WaveRadius.controls),
          ),
          child: Row(
            children: [
              Icon(
                widget.icon,
                size: 15,
                color: widget.active ? accent : waveTextSecondary(context),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: waveTextPrimary(context),
                    fontWeight: widget.active
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                ),
              ),
              if (widget.hint != null)
                Text(
                  widget.hint!,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: widget.active ? accent : waveTextTertiary(context),
                    fontWeight: widget.active
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StepperBtn extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _StepperBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  State<_StepperBtn> createState() => _StepperBtnState();
}

class _StepperBtnState extends State<_StepperBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: _hover
                  ? (dark ? Colors.white : Colors.black).withValues(alpha: 0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Center(
              child: Icon(
                widget.icon,
                size: 12,
                color: waveTextPrimary(context),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _QuickActionButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final bool active;
  final VoidCallback onTap;

  const _QuickActionButton({
    required this.icon,
    required this.tooltip,
    this.active = false,
    required this.onTap,
  });

  @override
  State<_QuickActionButton> createState() => _QuickActionButtonState();
}

class _QuickActionButtonState extends State<_QuickActionButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final ink = dark ? Colors.white : Colors.black;
    final accent = waveAccent(context);
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: widget.active
                  ? accent.withValues(alpha: dark ? 0.20 : 0.16)
                  : ink.withValues(alpha: _hover ? (dark ? 0.16 : 0.14) : (dark ? 0.08 : 0.08)),
              borderRadius: BorderRadius.circular(7),
              border: widget.active
                  ? Border.all(color: accent.withValues(alpha: dark ? 0.45 : 0.55))
                  : null,
            ),
            child: Center(
              child: Icon(
                widget.icon,
                size: 14,
                color: widget.active
                    ? accent
                    : ink.withValues(alpha: _hover ? 1.0 : 0.85),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CircularIconButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;

  const _CircularIconButton({
    required this.icon,
    required this.onTap,
    required this.tooltip,
  });

  @override
  State<_CircularIconButton> createState() => _CircularIconButtonState();
}

class _CircularIconButtonState extends State<_CircularIconButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final ink = dark ? Colors.white : Colors.black;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: ink.withValues(
                alpha: _hover ? (dark ? 0.20 : 0.15) : (dark ? 0.10 : 0.08),
              ),
            ),
            child: Center(
              child: Icon(
                widget.icon,
                size: 15,
                color: ink.withValues(alpha: _hover ? 1.0 : 0.85),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
