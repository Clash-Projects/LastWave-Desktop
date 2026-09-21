import 'dart:ui';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/stream_models.dart';
import '../../features/lyrics/karaoke_lyrics_view.dart';
import '../../features/player/playback_service.dart';
import '../components/artwork.dart';
import '../components/buttons.dart' show LWTooltip;
import '../components/states.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

/// WinUI 3 Right-side Sliding Lyrics Panel.
///
/// Directly mirrored from `desktop-app`'s `SidePanelManager`:
/// - Slides smoothly from the right side of the main window over page content.
/// - Hosts the complete Apple Music Karaoke-Style Lyrics Engine with progressive
///   word/syllable wipe, soft blur on inactive lines, active line pop,
///   timing offset toolbar, and transliteration toggle.
/// - Dismissible via close button, backdrop tap, or Escape key.
class WaveLyricsSidePanel extends ConsumerStatefulWidget {
  final VoidCallback onClose;

  /// True while the panel is slid in. The shell keeps this mounted
  /// offscreen when closed — used to gate the frost blur (see below).
  final bool visible;

  const WaveLyricsSidePanel({
    super.key,
    required this.onClose,
    this.visible = true,
  });

  @override
  ConsumerState<WaveLyricsSidePanel> createState() =>
      _WaveLyricsSidePanelState();
}

class _WaveLyricsSidePanelState
    extends ConsumerState<WaveLyricsSidePanel> {
  // Frost blur is OFF during the slide-in and fades in after it
  // settles: a live fullscreen BackdropFilter forces a full-window
  // re-blur on every slide frame (~8 jank frames), while a settled
  // blur layer is cached and free. Sigma 20 reads the same as 48
  // over the dark frost tint.
  // Frost opacity, NOT subtree-swapped: the previous build toggled
  // between `content` and `BackdropFilter(child: content)`, which
  // remounted the karaoke view mid-fade (the visible blink). One
  // stable tree from first build — opacity 0 skips the backdrop
  // sample entirely, so the slide stays free.
  double _frostOpacity = 0.0;

  @override
  void initState() {
    super.initState();
    if (widget.visible) _armBlur();
  }

  @override
  void didUpdateWidget(WaveLyricsSidePanel old) {
    super.didUpdateWidget(old);
    if (widget.visible && !old.visible) {
      setState(() => _frostOpacity = 0.0);
      _armBlur();
    } else if (!widget.visible && old.visible) {
      setState(() => _frostOpacity = 0.0);
    }
  }

  void _armBlur() {
    Future.delayed(
      WaveMotion.normal + const Duration(milliseconds: 60),
      () {
        if (mounted && widget.visible && _frostOpacity < 1.0) {
          setState(() => _frostOpacity = 1.0);
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final current = ref.watch(
      playbackServiceProvider.select((s) => s.current),
    );
    final frost = dark
        ? const Color(0x66111111)
        : const Color(0x99F4F3F0);

    // Two stacked layers so the slide stays visible while the blur
    // stays free: the body slides in fully readable with a static
    // edge, and ONLY the frost+blur overlay fades in after settle.
    // (Fading the whole tree hid the slide itself — opacity 0 during
    // entrance reads as fade-in, not slide-in.) One stable tree from
    // first build, so no remount blink; opacity 0 skips the backdrop
    // sample entirely.
    return ClipRect(
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: (dark ? Colors.white : Colors.black)
                        .withValues(alpha: 0.06),
                  ),
                ),
              ),
            ),
          ),
          // Frost + blur sit BEHIND the body: the filter samples the
          // page beneath, the tint evens it out, text stays crisp.
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _frostOpacity,
                duration:
                    const Duration(milliseconds: 250),
                curve: Curves.easeOutCubic,
                child: BackdropFilter(
                  filter: ImageFilter.blur(
                      sigmaX: 20, sigmaY: 20),
                  child: Container(color: frost),
                ),
              ),
            ),
          ),
          _PanelBody(
            current: current,
            dark: dark,
            onClose: widget.onClose,
          ),
        ],
      ),
    );
  }
}

class _PanelBody extends ConsumerWidget {
  final PlayableTrack? current;
  final bool dark;
  final VoidCallback onClose;
  const _PanelBody({
    required this.current,
    required this.dark,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Local for flow promotion (fields don't promote).
    final track = current;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: Colors.transparent,
            border: Border(
              bottom: BorderSide(
                color: (dark ? Colors.white : Colors.black)
                    .withValues(alpha: 0.06),
              ),
            ),
          ),
          child: Row(
            children: [
              if (track != null) ...[
                WaveArtwork(
                  url: track.artworkUrl,
                  videoId: track.videoId,
                  size: 32,
                  radius: 6,
                  label: track.title,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: WaveType.trackTitle.copyWith(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        track.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: WaveType.meta.copyWith(
                          fontSize: 11,
                          color: waveTextSecondary(context),
                        ),
                      ),
                    ],
                  ),
                ),
              ] else
                Expanded(
                  child: Text(
                    'Lyrics',
                    style: WaveType.sectionTitle.copyWith(fontSize: 15),
                  ),
                ),
              const SizedBox(width: 8),
              LWTooltip(
                message: 'Close lyrics (Esc)',
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: onClose,
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Center(
                        child: Icon(
                          WaveIcons.close,
                          size: 14,
                          color: waveTextSecondary(context),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: track == null
              ? const WaveEmpty(
                  icon: WaveIcons.music,
                  title: 'Nothing playing',
                  subtitle: 'Play a track to view live lyrics.',
                )
              : WaveKaraokeLyricsView(
                  track: track,
                  compact: false,
                  fontSize: 34,
                  showHeaderControls: true,
                  onClose: null,
                ),
        ),
      ],
    );
  }
}
