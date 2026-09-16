import 'package:audio_video_progress_bar/audio_video_progress_bar.dart' as avp;
import 'package:fluent_ui/fluent_ui.dart' hide RepeatMode;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/audio/stream_models.dart';
import '../../features/downloads/download_manager.dart';
import '../../features/library/playlists.dart';
import '../../features/player/playback_service.dart';
import '../../features/audio_output/output_controller.dart';
import '../../widgets/ambient.dart';
import '../components/artwork.dart';
import '../components/buttons.dart' show LWTooltip, LWVolumeSlider;
import '../components/menus.dart';
import '../theme/haze.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

/// Coherent desktop music player — ONE object, 80px, three zones.
///
/// LEFT (290px): 56px artwork r6 + title 13.5/600 + artist 12 secondary +
/// like + more (truncate). CENTER (max 560): shuffle/prev/play/next/repeat
/// 18px + 3px timeline + tabular 11px timestamps. RIGHT (300px): quality
/// overline badge + lyrics + queue + device + 84px volume + expand +
/// overflow (speed/sleep/download/Open Now Playing).
///
/// Always visible — placeholder when nothing is playing, never collapses.
/// Position ticks are scoped to [_DockProgress] only via
/// `select((s) => position/buffered/duration)`; the shell never rebuilds.
class WavePlayerDock extends ConsumerWidget {
  final VoidCallback onExpand;
  final VoidCallback onToggleQueue;
  final VoidCallback onToggleLyrics;
  final bool queueActive;
  final bool lyricsActive;
  final VoidCallback onToggleMini;
  const WavePlayerDock({
    super.key,
    required this.onExpand,
    required this.onToggleQueue,
    required this.onToggleLyrics,
    this.queueActive = false,
    this.lyricsActive = false,
    required this.onToggleMini,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = waveIsDark(context);
    // NOTE: position/duration/buffered/volume/speed deliberately excluded
    // here so 1s ticks and volume drags never rebuild the whole dock.
    // _DockProgress owns position; _VolumeSection owns volume; _DockOverflow
    // owns speed/sleep. See perf audit.
    final player = ref.watch(playbackServiceProvider.select((s) => (
          current: s.current,
          stream: s.stream,
          shuffleEnabled: s.shuffleEnabled,
          isPlaying: s.isPlaying,
          isBuffering: s.isBuffering,
          repeatMode: s.repeatMode,
        )));
    final notifier = ref.read(playbackServiceProvider.notifier);
    final current = player.current;
    final artworkUrl = player.current?.artworkUrl ?? '';
    final dockTint = ref.watch(artworkSeedProvider(artworkUrl)).valueOrNull;

    final targetBase = () {
      final baseColor = dark
          ? WaveColors.dockTranslucent
          : WaveColors.lightSurface.withValues(alpha: 0.97);
      if (dockTint != null && dark) {
        return Color.lerp(baseColor, dockTint, 0.05) ?? baseColor;
      }
      return baseColor;
    }();

    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(begin: targetBase, end: targetBase),
      duration: WaveMotion.normal,
      curve: Curves.easeOutCubic,
      builder: (context, animatedBase, child) {
        return WaveHaze(
          level: LwHazeLevel.l1,
          base: animatedBase ?? targetBase,
          border: Border(
            top: BorderSide(color: waveDivider(context)),
          ),
          child: child!,
        );
      },
      child: SizedBox(
        height: WaveDensity.dock,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Dock width is content width (already rail-aware) — never
              // MediaQuery window width which overestimates by ~200px.
              final dockW = constraints.maxWidth;
              final narrow = dockW < 680;
              return Row(
                children: [
                  // LEFT — identity (290px, placeholder when idle).
                  SizedBox(
                    width: narrow ? 200 : 290,
                    child: AnimatedSwitcher(
                      duration: WaveMotion.normal,
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      transitionBuilder: (child, anim) => FadeTransition(
                        opacity: anim,
                        child: child,
                      ),
                      child: current == null
                          ? _IdleIdentity(
                              key: const ValueKey('idle'),
                              onExpand: onExpand,
                            )
                          : KeyedSubtree(
                              key: ValueKey(current.queueKey),
                              child: Row(
                                children: [
                                  GestureDetector(
                                    onTap: onExpand,
                                    child: LWTooltip(
                                      message: 'Open Now Playing',
                                      child: WaveArtwork(
                                        url: current.artworkUrl,
                                        videoId: current.videoId,
                                        size: 56,
                                        radius: WaveRadius.artwork,
                                        label: current.title,
                                        title: current.title,
                                        artist: current.artist,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: GestureDetector(
                                      onTap: onExpand,
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            current.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style:
                                                WaveType.trackTitle.copyWith(
                                              fontSize: 13.5,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          Text(
                                            current.artist,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: WaveType.meta.copyWith(
                                              fontSize: 12,
                                              color: dark
                                                  ? WaveColors.textSecondary
                                                  : WaveColors
                                                      .lightTextSecondary,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  _LikeGlyph(track: current),
                                  if (!narrow)
                                    _Glyph(
                                      tooltip: 'More',
                                      icon: WaveIcons.more,
                                      onTap: null,
                                      menuItems: waveTrackMenuItems(
                                        ref: ref,
                                        title: current.title,
                                        artist: current.artist,
                                        artworkUrl: current.artworkUrl,
                                        videoId: current.videoId,
                                        playable: current,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                    ),
                  ),
                  // CENTER — transport + timeline. No minWidth: squeezes
                  // gracefully on tiny windows instead of overflowing.
                  Expanded(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: 560,
                          minWidth: 0,
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _Glyph(
                                  tooltip: 'Shuffle',
                                  icon: WaveIcons.shuffle,
                                  active: player.shuffleEnabled,
                                  onTap: notifier.toggleShuffle,
                                ),
                                _Glyph(
                                  tooltip: 'Previous',
                                  icon: WaveIcons.previous,
                                  large: true,
                                  onTap: current == null
                                      ? null
                                      : notifier.previous,
                                ),
                                _PlayGlyph(
                                  playing: player.isPlaying,
                                  buffering: player.isBuffering,
                                  enabled: current != null,
                                  onTap: notifier.toggle,
                                ),
                                _Glyph(
                                  tooltip: 'Next',
                                  icon: WaveIcons.next,
                                  large: true,
                                  onTap: current == null
                                      ? null
                                      : notifier.next,
                                ),
                                _Glyph(
                                  tooltip:
                                      'Repeat ${player.repeatMode.name}',
                                  icon: player.repeatMode ==
                                          RepeatMode.one
                                      ? WaveIcons.repeatOne
                                      : WaveIcons.repeat,
                                  active: player.repeatMode !=
                                      RepeatMode.off,
                                  onTap: notifier.cycleRepeat,
                                ),
                              ],
                            ),
                            const SizedBox(height: 1),
                            _DockProgress(compact: narrow),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // RIGHT — priority groups, never icon soup (spec §7–8).
                  // HIGH: queue + volume + lyrics · MEDIUM: device + quality ·
                  // LOW: expand + mini + extras → overflow. No control ever
                  // leaves the viewport; secondary actions collapse into More.
                  Builder(builder: (context) {
                    // Thresholds are dock-relative (content width), aligned
                    // to canonical 900 breakpoint family.
                    final showLyrics = dockW >= 560;
                    final showQuality =
                        dockW >= 900 && player.stream != null;
                    final showDevice = dockW >= 800;
                    final showVolumeSlider = dockW >= 800;
                    final showExpand = dockW >= 850;
                    final showMini = dockW >= 950;
                    return ConstrainedBox(
                      constraints: BoxConstraints(
                        minWidth: dockW < 560
                            ? 110.0
                            : dockW < 800
                                ? 170.0
                                : 260.0,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          if (showQuality) ...[
                            Padding(
                              padding:
                                  const EdgeInsets.only(right: 2),
                              child: _QualityFlyout(
                                stream: player.stream!,
                              ),
                            ),
                            const _StreamPathGlyph(),
                          ],
                          if (showLyrics)
                            _Glyph(
                              tooltip: 'Lyrics (Ctrl+L)',
                              icon: WaveIcons.lyrics,
                              active: lyricsActive,
                              onTap: onToggleLyrics,
                            ),
                          _Glyph(
                            tooltip: 'Queue',
                            icon: WaveIcons.queue,
                            active: queueActive,
                            onTap: onToggleQueue,
                          ),
                          if (showDevice) const _DeviceGlyph(),
                          if (showVolumeSlider)
                            const _VolumeSection()
                          else
                            const _VolumeFlyoutSection(),
                          if (showExpand)
                            _Glyph(
                              tooltip: 'Now Playing',
                              icon: WaveIcons.expand,
                              onTap: onExpand,
                            ),
                          if (showMini)
                            _Glyph(
                              tooltip: 'Mini player',
                              icon: WaveIcons.miniPlayer,
                              onTap: onToggleMini,
                            ),
                          _DockOverflow(
                            showLyricsItem: !showLyrics,
                            showQualityItem: !showQuality &&
                                player.stream != null,
                            showDeviceItem: !showDevice,
                            showExpandItem: !showExpand,
                            showMiniItem: !showMini,
                            onToggleLyrics: onToggleLyrics,
                            onExpand: onExpand,
                            onToggleMini: onToggleMini,
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Placeholder identity — dock never collapses to zero height.
class _IdleIdentity extends StatelessWidget {
  final VoidCallback onExpand;
  const _IdleIdentity({super.key, required this.onExpand});
  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    return Row(
      children: [
        const WaveArtwork(
          url: '',
          size: 56,
          radius: WaveRadius.artwork,
          label: 'Nothing playing',
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Nothing playing',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: WaveType.trackTitle.copyWith(fontSize: 13.5),
              ),
              Text(
                'Pick something to start',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: WaveType.meta.copyWith(
                  fontSize: 12,
                  color: dark
                      ? WaveColors.textTertiary
                      : WaveColors.lightTextTertiary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Compact quality status → Fluent MenuFlyout.
///
/// Badge stays tiny (LOSSLESS / HI-RES / AAC / OPUS). Click opens
/// format · sample rate · bit depth · codec · stream/download prefs.
class _QualityFlyout extends ConsumerStatefulWidget {
  final ResolvedStream stream;
  const _QualityFlyout({required this.stream});
  @override
  ConsumerState<_QualityFlyout> createState() => _QualityFlyoutState();
}

class _QualityFlyoutState extends ConsumerState<_QualityFlyout> {
  bool _hover = false;
  final _flyout = FlyoutController();
  @override
  void dispose() {
    _flyout.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final s = widget.stream;
    return FlyoutTarget(
      controller: _flyout,
      child: LWTooltip(
        message:
            '${s.audioCodec}${s.bitrateKbps > 0 ? ' · ${s.bitrateKbps} kbps' : ''} — details',
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            onTap: () {
              _flyout.showFlyout(
                barrierColor: Colors.transparent,
                placementMode: FlyoutPlacementMode.topCenter,
                builder: (context) => MenuFlyout(
                  items: [
                    MenuFlyoutItem(
                      leading: const Icon(WaveIcons.gauge, size: 15),
                      text: Text('${s.qualityBadge} · ${s.audioCodec}'),
                      onPressed: () {},
                    ),
                    const MenuFlyoutSeparator(),
                    MenuFlyoutItem(
                      leading: const Icon(WaveIcons.music, size: 15),
                      text: Text('Sample rate · ${s.samplingRateKhz} kHz'),
                      onPressed: () {},
                    ),
                    MenuFlyoutItem(
                      leading: const Icon(WaveIcons.mixes, size: 15),
                      text: Text('Bit depth · ${s.bitDepth}-bit'),
                      onPressed: () {},
                    ),
                    if (s.bitrateKbps > 0)
                      MenuFlyoutItem(
                        leading: const Icon(WaveIcons.clock, size: 15),
                        text: Text('Bitrate · ${s.bitrateKbps} kbps'),
                        onPressed: () {},
                      ),
                    const MenuFlyoutSeparator(),
                    MenuFlyoutItem(
                      leading: const Icon(WaveIcons.settings, size: 15),
                      text: const Text('Quality settings'),
                      onPressed: () => context.go('/settings'),
                    ),
                  ],
                ),
              );
            },
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: _hover
                    ? (dark ? Colors.white : Colors.black)
                        .withValues(alpha: WaveState.hoverAlpha)
                    : Colors.transparent,
                border: Border.all(
                  color: dark
                      ? WaveColors.outline
                      : WaveColors.lightOutline,
                ),
                borderRadius:
                    BorderRadius.circular(WaveRadius.controls),
              ),
              child: Text(
                s.qualityBadge,
                style: WaveType.overline.copyWith(
                  fontSize: 9,
                  color: dark
                      ? WaveColors.textSecondary
                      : WaveColors.lightTextSecondary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact WASAPI / bit-perfect path — WinUI 3 MenuFlyout, dock-sized.
class _StreamPathGlyph extends ConsumerWidget {
  const _StreamPathGlyph();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = ref.watch(audioOutputProvider.select((s) => s.path));
    final outputLabel = path.outputLabel;
    return _Glyph(
      tooltip: path.bitPerfect
          ? '$outputLabel · Bit-Perfect'
          : '$outputLabel · Stream path',
      icon: WaveIcons.streamPath,
      active: path.bitPerfect,
      menuItems: [
        MenuFlyoutItem(
          leading: const Icon(WaveIcons.music, size: 15),
          text: Text('Source · ${path.sourceLabel}'),
          onPressed: () {},
        ),
        MenuFlyoutItem(
          leading: const Icon(WaveIcons.device, size: 15),
          text: Text('DAC · ${path.outputLabel}'),
          onPressed: () {},
        ),
        MenuFlyoutItem(
          leading: const Icon(WaveIcons.speaker, size: 15),
          text: Text(
            path.exclusiveActive
                ? 'WASAPI · Exclusive'
                : 'WASAPI · Shared',
          ),
          onPressed: () {},
        ),
        MenuFlyoutItem(
          leading: const Icon(WaveIcons.volume, size: 15),
          text: Text(
            path.hardwareVolume
                ? 'Volume · DAC hardware'
                : (path.softwareVolume
                    ? 'Volume · Software'
                    : 'Volume · Unity'),
          ),
          onPressed: () {},
        ),
        const MenuFlyoutSeparator(),
        MenuFlyoutItem(
          leading: Icon(
            path.bitPerfect ? WaveIcons.likedFill : WaveIcons.streamPath,
            size: 15,
          ),
          text: Text(path.bitPerfect ? 'Bit-Perfect' : path.reason.label),
          onPressed: () {},
        ),
        MenuFlyoutItem(
          leading: const Icon(WaveIcons.settings, size: 15),
          text: const Text('Output settings'),
          onPressed: () => context.go('/settings'),
        ),
      ],
    );
  }
}

/// Plain glyph button — no coloured square wrapping.
class _Glyph extends StatefulWidget {
  final String tooltip;
  final IconData icon;
  final bool active;
  final bool large;
  final VoidCallback? onTap;
  final List<MenuFlyoutItemBase>? menuItems;
  const _Glyph({
    required this.tooltip,
    required this.icon,
    this.active = false,
    this.large = false,
    this.onTap,
    this.menuItems,
  });
  @override
  State<_Glyph> createState() => _GlyphState();
}

class _GlyphState extends State<_Glyph> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);
    final disabled = widget.onTap == null && widget.menuItems == null;
    final color = widget.active
        ? accent
        : disabled
            ? (dark ? WaveColors.textTertiary : WaveColors.lightTextTertiary)
                .withValues(alpha: 0.5)
            : _hover
                ? (dark
                    ? WaveColors.textPrimary
                    : WaveColors.lightTextPrimary)
                : (dark
                    ? WaveColors.textSecondary
                    : WaveColors.lightTextSecondary);
    Widget glyph = MouseRegion(
      cursor: disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _pressed = false;
      }),
      child: GestureDetector(
        onTapDown: disabled ? null : (_) => setState(() => _pressed = true),
        onTapUp: disabled ? null : (_) => setState(() => _pressed = false),
        onTapCancel: disabled ? null : () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? 0.90 : (_hover ? 1.10 : 1.0),
          duration: WaveMotion.fast,
          curve: Curves.easeOutCubic,
          child: Container(
            width: 34,
            height: 34,
            color: Colors.transparent,
            // Transport icons 18px, utility glyphs 15px (canonical).
            child: Icon(widget.icon,
                size: widget.large ? 18 : 15, color: color),
          ),
        ),
      ),
    );
    if (widget.menuItems != null) {
      glyph = DropDownButton(
        placement: FlyoutPlacementMode.topRight,
        items: widget.menuItems!,
        buttonBuilder: (context, onOpen) => MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() {
            _hover = false;
            _pressed = false;
          }),
          child: GestureDetector(
            onTapDown: (_) => setState(() => _pressed = true),
            onTapUp: (_) => setState(() => _pressed = false),
            onTapCancel: () => setState(() => _pressed = false),
            onTap: onOpen,
            child: AnimatedScale(
              scale: _pressed ? 0.90 : (_hover ? 1.10 : 1.0),
              duration: WaveMotion.fast,
              curve: Curves.easeOutCubic,
              child: Container(
                width: 34,
                height: 34,
                color: Colors.transparent,
                child: Icon(widget.icon, size: 15, color: color),
              ),
            ),
          ),
        ),
      );
    }
    return LWTooltip(message: widget.tooltip, child: glyph);
  }
}

/// Fluent media transport button — 36px accent disc, NOT a giant FAB.
///
/// Uses the active [waveAccent] (LastWave / System / Artwork accent) with
/// contrast glyph, 1px tonal ring + restrained shadow. Hover 92%,
/// pressed 85%, focus ring 2px, tooltip with shortcut. Both themes.
class _PlayGlyph extends StatefulWidget {
  final bool playing;
  final bool buffering;
  final bool enabled;
  final VoidCallback onTap;
  const _PlayGlyph({
    required this.playing,
    required this.buffering,
    this.enabled = true,
    required this.onTap,
  });
  @override
  State<_PlayGlyph> createState() => _PlayGlyphState();
}

class _PlayGlyphState extends State<_PlayGlyph> {
  bool _hover = false;
  bool _pressed = false;
  final FocusNode _focus = FocusNode();
  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);
    final onAccent =
        accent.computeLuminance() > 0.5 ? Colors.black : Colors.white;
    Color bg;
    if (!widget.enabled) {
      bg = accent.withValues(alpha: 0.35);
    } else if (_pressed) {
      bg = accent.withValues(alpha: 0.82);
    } else if (_hover) {
      bg = accent.withValues(alpha: 0.93);
    } else {
      bg = accent;
    }
    final fg = widget.enabled
        ? onAccent
        : onAccent.withValues(alpha: 0.5);
    return LWTooltip(
      message: widget.playing ? 'Pause (Space)' : 'Play (Space)',
      child: Focus(
        focusNode: _focus,
        onFocusChange: (_) => setState(() {}),
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.enter ||
                  event.logicalKey == LogicalKeyboardKey.space)) {
            if (widget.enabled) widget.onTap();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: MouseRegion(
          cursor: widget.enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) {
            setState(() {
              _hover = false;
              _pressed = false;
            });
          },
          child: GestureDetector(
            onTapDown: (_) =>
                setState(() => _pressed = true),
            onTapUp: (_) =>
                setState(() => _pressed = false),
            onTapCancel: () =>
                setState(() => _pressed = false),
            onTap: widget.enabled ? widget.onTap : null,
            child: AnimatedScale(
              scale: _pressed ? 0.92 : (_hover ? 1.06 : 1.0),
              duration: WaveMotion.fast,
              curve: Curves.easeOutCubic,
              child: AnimatedContainer(
                duration: WaveMotion.fast,
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: bg,
                  border: Border.all(
                    color: (_focus.hasFocus
                            ? accent
                            : (dark
                                ? Colors.white
                                : Colors.black))
                        .withValues(
                            alpha: _focus.hasFocus ? 0.9 : 0.14),
                    width: _focus.hasFocus ? 2 : 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(
                          alpha: dark ? 0.45 : 0.18),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Center(
                  child: widget.buffering
                      ? SizedBox(
                          width: 16,
                          height: 16,
                          child: ProgressRing(
                            strokeWidth: 2.5,
                            activeColor: fg,
                            backgroundColor:
                                fg.withValues(alpha: 0.25),
                          ),
                        )
                      : AnimatedSwitcher(
                          duration: const Duration(milliseconds: 180),
                          transitionBuilder: (child, animation) =>
                              ScaleTransition(
                            scale: CurvedAnimation(
                              parent: animation,
                              curve: Curves.easeOutBack,
                            ),
                            child: FadeTransition(
                              opacity: animation,
                              child: child,
                            ),
                          ),
                          child: Icon(
                            widget.playing
                                ? WaveIcons.pause
                                : WaveIcons.play,
                            key: ValueKey(widget.playing),
                            size: 15,
                            color: fg,
                          ),
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Position scope boundary: ONLY this widget subscribes to the 1s
/// position/buffered/duration stream. Thin 3px bar at rest with a small
/// thumb; hover enlarges the interaction region and shows a timestamp
/// via tooltip overlay (never clipped by the 80px dock); drag/click seeks;
/// ←/→ keys seek ±5s (Shift ±15s) when focused.
class _DockProgress extends ConsumerStatefulWidget {
  final bool compact;
  const _DockProgress({this.compact = false});
  @override
  ConsumerState<_DockProgress> createState() => _DockProgressState();
}

class _DockProgressState extends ConsumerState<_DockProgress> {
  final FocusNode _focus = FocusNode();
  final GlobalKey _barKey = GlobalKey();
  double? _hoverRatio;
  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  void _seekBy(Duration base, Duration total, int seconds) {
    final target = base + Duration(seconds: seconds);
    final clamped = target.isNegative
        ? Duration.zero
        : (target > total ? total : target);
    ref.read(playbackServiceProvider.notifier).seek(clamped);
  }

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);
    final clock = ref.watch(playbackServiceProvider.select((s) => (
          position: s.position,
          buffered: s.buffered,
          duration: s.duration,
        )));
    final notifier = ref.read(playbackServiceProvider.notifier);

    final timeStyle = WaveType.meta.copyWith(
      fontSize: 11,
      fontFeatures: const [FontFeature.tabularFigures()],
      color: dark ? WaveColors.textTertiary : WaveColors.lightTextTertiary,
    );
    final totalMs = clock.duration.inMilliseconds;
    final hoverLabel = _hoverRatio == null || totalMs <= 0
        ? null
        : _fmt(Duration(
            milliseconds: (_hoverRatio! * totalMs).round()));
    // Compact windows hide timestamps so the timeline never overflows;
    // the hover tooltip still announces the seek target.
    final showTimes = !widget.compact;
    return Row(
      children: [
        if (showTimes)
          SizedBox(
            width: 38,
            child: Text(_fmt(clock.position),
                textAlign: TextAlign.right, style: timeStyle),
          ),
        if (showTimes) const SizedBox(width: 8),
        Expanded(
          child: Focus(
            focusNode: _focus,
            onKeyEvent: (_, e) {
              if (e is! KeyDownEvent) return KeyEventResult.ignored;
              final shift = HardwareKeyboard.instance.logicalKeysPressed
                  .contains(LogicalKeyboardKey.shiftLeft) ||
                  HardwareKeyboard.instance.logicalKeysPressed
                      .contains(LogicalKeyboardKey.shiftRight);
              final step = shift ? 15 : 5;
              if (e.logicalKey == LogicalKeyboardKey.arrowRight) {
                _seekBy(clock.position, clock.duration, step);
                return KeyEventResult.handled;
              }
              if (e.logicalKey == LogicalKeyboardKey.arrowLeft) {
                _seekBy(clock.position, clock.duration, -step);
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: LWTooltip(
              message: hoverLabel ?? 'Seek (←/→ ±5s)',
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                onExit: (_) =>
                    setState(() => _hoverRatio = null),
                onHover: (e) {
                  final box = _barKey.currentContext
                      ?.findRenderObject() as RenderBox?;
                  if (box == null || !box.hasSize) return;
                  final ratio = (e.localPosition.dx / box.size.width)
                      .clamp(0.0, 1.0);
                  // Debounced: only rebuild on meaningful movement.
                  if ((ratio - (_hoverRatio ?? -1)).abs() > 0.01) {
                    setState(() => _hoverRatio = ratio);
                  }
                },
                child: GestureDetector(
                  onTapDown: (_) => _focus.requestFocus(),
                  behavior: HitTestBehavior.translucent,
                  child: Container(
                    key: _barKey,
                    // Larger interaction region without visibly bloating
                    // the bar: transparent padding.
                    padding:
                        const EdgeInsets.symmetric(vertical: 7),
                    color: Colors.transparent,
                    child: RepaintBoundary(
                      child: avp.ProgressBar(
                        progress: clock.position,
                        buffered: clock.buffered,
                        total: clock.duration,
                        onSeek: notifier.seek,
                        barHeight: 3,
                        thumbRadius: 5,
                        thumbColor:
                            dark ? Colors.white : Colors.black,
                        thumbGlowColor:
                            accent.withValues(alpha: 0.25),
                        progressBarColor:
                            dark ? Colors.white : Colors.black,
                        bufferedBarColor:
                            (dark ? Colors.white : Colors.black)
                                .withValues(alpha: 0.18),
                        baseBarColor:
                            (dark ? Colors.white : Colors.black)
                                .withValues(alpha: 0.12),
                        timeLabelLocation:
                            avp.TimeLabelLocation.none,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (showTimes) const SizedBox(width: 8),
        if (showTimes)
          SizedBox(
            width: 38,
            child: Text(_fmt(clock.duration), style: timeStyle),
          ),
      ],
    );
  }
}

class _LikeGlyph extends ConsumerStatefulWidget {
  final PlayableTrack track;
  const _LikeGlyph({required this.track});

  @override
  ConsumerState<_LikeGlyph> createState() => _LikeGlyphState();
}

class _LikeGlyphState extends ConsumerState<_LikeGlyph>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      lowerBound: 0.8,
      upperBound: 1.25,
      value: 1.0,
    );
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  void _onToggle() {
    _anim
        .forward(from: 0.8)
        .then((_) => _anim.animateTo(1.0, curve: Curves.easeOutBack));
    ref.read(playlistRepositoryProvider.notifier).toggleLiked(
          StoredTrack(
            name: widget.track.title,
            artist: widget.track.artist,
            artworkUrl: widget.track.artworkUrl,
            videoId: widget.track.videoId,
          ),
        );
  }

  @override
  Widget build(BuildContext context) {
    final liked = ref
        .watch(playlistRepositoryProvider.notifier)
        .likedKeys()
        .contains(widget.track.queueKey);
    return ScaleTransition(
      scale: _anim,
      child: _Glyph(
        tooltip: liked ? 'Unlike' : 'Like',
        icon: liked ? WaveIcons.likedFill : WaveIcons.liked,
        active: liked,
        onTap: _onToggle,
      ),
    );
  }
}

/// Output device — WASAPI endpoints from the isolated engine.
class _DeviceGlyph extends ConsumerWidget {
  const _DeviceGlyph();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final output = ref.watch(audioOutputProvider);
    final name = output.selected?.displayName ?? 'System default';
    return _Glyph(
      tooltip: 'Output: $name',
      icon: WaveIcons.device,
      menuItems: [
        MenuFlyoutItem(
          leading: const Icon(WaveIcons.device, size: 15),
          text: const Text('Default Windows device'),
          onPressed: () =>
              ref.read(audioOutputProvider.notifier).selectDevice(''),
        ),
        for (final d in output.devices.take(8))
          MenuFlyoutItem(
            leading: Icon(
              WaveIcons.device,
              size: 15,
              color: d.id == output.selectedId ? waveAccent(context) : null,
            ),
            text: Text(d.displayName, maxLines: 1),
            onPressed: () =>
                ref.read(audioOutputProvider.notifier).selectDevice(d.id),
          ),
        const MenuFlyoutSeparator(),
        MenuFlyoutItem(
          leading: const Icon(WaveIcons.settings, size: 15),
          text: const Text('Output settings'),
          onPressed: () => context.go('/settings'),
        ),
      ],
    );
  }
}

/// Isolated volume section — owns the volume select so drags never rebuild
/// the whole dock (perf audit).
class _VolumeSection extends ConsumerWidget {
  const _VolumeSection();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final volume =
        ref.watch(playbackServiceProvider.select((s) => s.volume));
    final output = ref.read(audioOutputProvider.notifier);
    return _VolumeGlyph(
      volume: volume,
      onMute: () => output.setVolume(volume == 0 ? 1 : 0),
      onVolume: output.setVolume,
    );
  }
}

/// Isolated collapsed-volume section with a real slider in the flyout.
class _VolumeFlyoutSection extends ConsumerWidget {
  const _VolumeFlyoutSection();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final volume =
        ref.watch(playbackServiceProvider.select((s) => s.volume));
    final output = ref.read(audioOutputProvider.notifier);
    return _VolumeFlyoutGlyph(
      volume: volume,
      onMute: () => output.setVolume(volume == 0 ? 1 : 0),
      onVolume: output.setVolume,
    );
  }
}

/// Fluent volume: mute glyph + 84px thin slider with percentage tooltip.
/// Keyboard arrows supported via [LWVolumeSlider] focus.
class _VolumeGlyph extends StatelessWidget {
  final double volume;
  final VoidCallback onMute;
  final ValueChanged<double> onVolume;
  const _VolumeGlyph({
    required this.volume,
    required this.onMute,
    required this.onVolume,
  });
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Glyph(
          tooltip: volume == 0
              ? 'Unmute (${(volume * 100).round()}%)'
              : 'Mute (${(volume * 100).round()}%)',
          icon: volume == 0
              ? WaveIcons.volumeMute
              : WaveIcons.volume,
          onTap: onMute,
        ),
        LWTooltip(
          message: '${(volume * 100).round()}%',
          child: LWVolumeSlider(
            value: volume.clamp(0.0, 1.0),
            onChanged: onVolume,
          ),
        ),
      ],
    );
  }
}

/// Collapsed volume: glyph opens a Fluent flyout WITH a real slider
/// (previously text-only, so volume could not be adjusted <1050px).
class _VolumeFlyoutGlyph extends ConsumerStatefulWidget {
  final double volume;
  final VoidCallback onMute;
  final ValueChanged<double> onVolume;
  const _VolumeFlyoutGlyph({
    required this.volume,
    required this.onMute,
    required this.onVolume,
  });
  @override
  ConsumerState<_VolumeFlyoutGlyph> createState() =>
      _VolumeFlyoutGlyphState();
}

class _VolumeFlyoutGlyphState extends ConsumerState<_VolumeFlyoutGlyph> {
  final _controller = FlyoutController();
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final volume = widget.volume;
    return FlyoutTarget(
      controller: _controller,
      child: LWTooltip(
        message: 'Volume (${(volume * 100).round()}%)',
        child: _Glyph(
          tooltip: 'Volume',
          icon: volume == 0
              ? WaveIcons.volumeMute
              : WaveIcons.volume,
          onTap: () {
            _controller.showFlyout(
              barrierColor: Colors.transparent,
              placementMode: FlyoutPlacementMode.topCenter,
              builder: (context) => FlyoutContent(
                padding: const EdgeInsets.all(12),
                constraints:
                    const BoxConstraints(maxWidth: 240),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Volume ${(volume * 100).round()}%',
                      style: WaveType.label,
                    ),
                    const SizedBox(height: 8),
                    LWVolumeSlider(
                      value: volume.clamp(0.0, 1.0),
                      onChanged: widget.onVolume,
                    ),
                    const SizedBox(height: 4),
                    HyperlinkButton(
                      onPressed: () {
                        widget.onMute();
                        _controller.close();
                      },
                      child: Text(volume == 0 ? 'Unmute' : 'Mute',
                          style: WaveType.label),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _DockOverflow extends ConsumerWidget {
  final bool showLyricsItem;
  final bool showQualityItem;
  final bool showDeviceItem;
  final bool showExpandItem;
  final bool showMiniItem;
  final VoidCallback onToggleLyrics;
  final VoidCallback onExpand;
  final VoidCallback onToggleMini;
  const _DockOverflow({
    this.showLyricsItem = false,
    this.showQualityItem = false,
    this.showDeviceItem = false,
    this.showExpandItem = false,
    this.showMiniItem = false,
    required this.onToggleLyrics,
    required this.onExpand,
    required this.onToggleMini,
  });
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(playbackServiceProvider.notifier);
    final sleep = ref.watch(
      playbackServiceProvider.select((s) => s.sleepRemaining),
    );
    final stream = ref.watch(
      playbackServiceProvider.select((s) => s.stream),
    );
    final speed =
        ref.watch(playbackServiceProvider.select((s) => s.speed));
    final speedLabel =
        speed == speed.roundToDouble() ? '${speed.toInt()}' : '$speed';
    final hasCollapsed =
        showLyricsItem ||
        showQualityItem ||
        showDeviceItem ||
        showExpandItem ||
        showMiniItem;
    return _Glyph(
      tooltip: 'More',
      icon: WaveIcons.more,
      menuItems: [
        // Collapsed priority controls reappear here — nothing is lost
        // at narrow widths, nothing overflows the window.
        if (showLyricsItem)
          MenuFlyoutItem(
            leading: const Icon(WaveIcons.lyrics, size: 15),
            text: const Text('Lyrics  (Ctrl+L)'),
            onPressed: onToggleLyrics,
          ),
        if (showQualityItem && stream != null)
          MenuFlyoutItem(
            leading: const Icon(WaveIcons.gauge, size: 15),
            text: Text(
                '${stream.qualityBadge} · ${stream.audioCodec}'),
            onPressed: () => context.go('/settings'),
          ),
        if (showQualityItem)
          MenuFlyoutItem(
            leading: const Icon(WaveIcons.streamPath, size: 15),
            text: Text(
              ref.watch(audioOutputProvider.select((s) => s.path.bitPerfect))
                  ? 'Stream path · Bit-Perfect'
                  : 'Stream path',
            ),
            onPressed: () => context.go('/settings'),
          ),
        if (showDeviceItem)
          MenuFlyoutItem(
            leading: const Icon(WaveIcons.device, size: 15),
            text: const Text('Output: System default'),
            onPressed: () {},
          ),
        if (showExpandItem)
          MenuFlyoutItem(
            leading: const Icon(WaveIcons.expand, size: 15),
            text: const Text('Open Now Playing'),
            onPressed: onExpand,
          ),
        if (showMiniItem)
          MenuFlyoutItem(
            leading:
                const Icon(WaveIcons.miniPlayer, size: 15),
            text: const Text('Mini player'),
            onPressed: onToggleMini,
          ),
        if (hasCollapsed) const MenuFlyoutSeparator(),
        MenuFlyoutItem(
          leading: const Icon(WaveIcons.gauge, size: 15),
          text: Text('Speed $speedLabel×'),
          onPressed: notifier.cycleSpeed,
        ),
        MenuFlyoutItem(
          leading: const Icon(WaveIcons.clock, size: 15),
          text: Text(sleep == null
              ? 'Sleep timer · 30 min'
              : 'Sleep ${sleep.inMinutes}m (tap to clear)'),
          onPressed: () {
            if (sleep != null) {
              notifier.setSleepTimer(null);
            } else {
              notifier.setSleepTimer(const Duration(minutes: 30));
            }
          },
        ),
        MenuFlyoutItem(
          leading: const Icon(WaveIcons.downloadAction, size: 15),
          text: const Text('Download this track'),
          onPressed: () {
            final current =
                ref.read(playbackServiceProvider).current;
            if (current == null) return;
            ref.read(downloadManagerProvider.notifier).downloadTrack(
                  title: current.title,
                  artist: current.artist,
                  album: current.album,
                  artworkUrl: current.artworkUrl,
                );
          },
        ),
      ],
    );
  }
}

