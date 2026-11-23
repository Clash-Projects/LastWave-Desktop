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
    show lyricsExcludedProvidersProvider, waveLyricsProvider;
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';
import 'immersive.dart';
import 'now_playing_style.dart';

/// Shared overflow menu button and frosted popover used by Full Bleed and Minimal Now Playing.
class NowPlayingOverflowMenuButton extends ConsumerStatefulWidget {
  final PlayableTrack track;
  final VoidCallback? onToggleQueue;
  final bool isQueueOpen;
  final Widget? icon;

  const NowPlayingOverflowMenuButton({
    super.key,
    required this.track,
    this.onToggleQueue,
    this.isQueueOpen = false,
    this.icon,
  });

  @override
  ConsumerState<NowPlayingOverflowMenuButton> createState() =>
      _NowPlayingOverflowMenuButtonState();
}

class _NowPlayingOverflowMenuButtonState
    extends ConsumerState<NowPlayingOverflowMenuButton> {
  final _controller = FlyoutController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _open() {
    _controller.showFlyout(
      barrierColor: Colors.transparent,
      placementMode: FlyoutPlacementMode.bottomRight,
      autoModeConfiguration: FlyoutAutoConfiguration(
        preferredMode: FlyoutPlacementMode.bottomRight,
      ),
      transitionDuration: const Duration(milliseconds: 90),
      transitionBuilder: fastFlyoutTransition,
      builder: (context) => WaveFlyoutPanel.child(
        maxWidth: 300,
        child: _NowPlayingOverflowMenuContent(
          track: widget.track,
          onToggleQueue: widget.onToggleQueue,
          isQueueOpen: widget.isQueueOpen,
        ),
      ),
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

class _NowPlayingOverflowMenuContent extends ConsumerWidget {
  final PlayableTrack track;
  final VoidCallback? onToggleQueue;
  final bool isQueueOpen;

  const _NowPlayingOverflowMenuContent({
    required this.track,
    this.onToggleQueue,
    this.isQueueOpen = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);
    final offsetMs = ref.watch(lyricsOffsetProvider(track.queueKey));
    final offsetNotifier = ref.read(
      lyricsOffsetProvider(track.queueKey).notifier,
    );
    final offsetDisplay = formatOffsetDisplay(offsetMs);

    final showTransliteration = ref.watch(lyricsTransliterationProvider);
    final transliterationNotifier = ref.read(
      lyricsTransliterationProvider.notifier,
    );

    final prefs = ref.watch(prefsProvider);
    final visualizerEnabled = ref.watch(visualizerEnabledProvider);
    final isImmersive = ref.watch(nowPlayingImmersiveProvider);
    final currentStyle = ref.watch(nowPlayingStyleProvider);

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. Timing Offset Row (stays open while tapping)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
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

          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Container(height: 1, color: waveDivider(context)),
          ),

          // 2. Lyrics Actions
          _MenuActionTile(
            icon: FluentIcons.reading_mode,
            title: 'Romanization',
            hint: showTransliteration ? 'On' : 'Off',
            active: showTransliteration,
            onTap: transliterationNotifier.toggle,
          ),
          _MenuActionTile(
            icon: FluentIcons.locale_language,
            title: 'Translation',
            hint:
                Prefs.lyricsTranslationOptions[prefs.lyricsTranslationLang] ??
                'Off',
            active:
                prefs.lyricsTranslationLang.isNotEmpty &&
                prefs.lyricsTranslationLang != 'none',
            onTap: () {
              final keys = Prefs.lyricsTranslationOptions.keys.toList();
              final idx = keys.indexOf(prefs.lyricsTranslationLang);
              final next = keys[(idx + 1) % keys.length];
              ref.read(prefsProvider).setLyricsTranslationLang(next);
            },
          ),
          _MenuActionTile(
            icon: FluentIcons.refresh,
            title: 'Try another lyrics source',
            onTap: () {
              final queueKey = track.queueKey;
              ref
                  .read(lyricsExcludedProvidersProvider(queueKey).notifier)
                  .state = retryLyricsExcludingCurrent(
                currentId: null,
                excludes: ref.read(lyricsExcludedProvidersProvider(queueKey)),
              );
              ref.invalidate(waveLyricsProvider(track));
            },
          ),

          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Container(height: 1, color: waveDivider(context)),
          ),

          // 3. View & Mode Toggles
          _MenuActionTile(
            icon: WaveIcons.visualizer,
            title: 'Audio visualizer / Wave',
            hint: visualizerEnabled ? 'On' : 'Off',
            active: visualizerEnabled,
            onTap: () => ref.read(visualizerEnabledProvider.notifier).toggle(),
          ),
          _MenuActionTile(
            icon: isImmersive ? FluentIcons.mini_contract : WaveIcons.expand,
            title: 'Fullscreen',
            hint: 'F11',
            active: isImmersive,
            onTap: () {
              ref.read(nowPlayingImmersiveProvider.notifier).state =
                  !isImmersive;
            },
          ),
          if (onToggleQueue != null)
            _MenuActionTile(
              icon: WaveIcons.queue,
              title: 'Up Next queue',
              hint: isQueueOpen ? 'Visible' : 'Hidden',
              active: isQueueOpen,
              onTap: onToggleQueue!,
            ),

          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Container(height: 1, color: waveDivider(context)),
          ),

          // 4. Inline Layout Switcher (bottom section of the menu)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
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
        ],
      ),
    );
  }
}

class _MenuActionTile extends StatefulWidget {
  final IconData icon;
  final String title;
  final String? hint;
  final bool active;
  final VoidCallback onTap;

  const _MenuActionTile({
    required this.icon,
    required this.title,
    this.hint,
    this.active = false,
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
      onEnter: (_) => setState(() => _hover = true),
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
                    fontWeight:
                        widget.active ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
              if (widget.hint != null)
                Text(
                  widget.hint!,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: widget.active ? accent : waveTextTertiary(context),
                    fontWeight:
                        widget.active ? FontWeight.w600 : FontWeight.w400,
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
              color: Colors.white.withValues(alpha: _hover ? 0.20 : 0.10),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Center(
              child: Icon(
                widget.icon,
                size: 16,
                color: Colors.white.withValues(alpha: _hover ? 1.0 : 0.88),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
