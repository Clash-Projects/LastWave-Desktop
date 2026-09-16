import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/lyrics/karaoke_lyrics_view.dart';
import '../../features/player/playback_service.dart';
import '../components/artwork.dart';
import '../components/buttons.dart' show LWTooltip;
import '../components/states.dart';
import '../theme/haze.dart';
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
class WaveLyricsSidePanel extends ConsumerWidget {
  final VoidCallback onClose;

  const WaveLyricsSidePanel({
    super.key,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = waveIsDark(context);
    final current = ref.watch(
      playbackServiceProvider.select((s) => s.current),
    );

    return WaveHaze(
      level: LwHazeLevel.l2,
      base: (dark ? WaveColors.surfaceRaised : WaveColors.lightSurfaceRaised)
          .withValues(alpha: 0.94),
      border: Border(
        left: BorderSide(color: waveDivider(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header: Identity + Close
          Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: waveDivider(context)),
              ),
            ),
            child: Row(
              children: [
                if (current != null) ...[
                  WaveArtwork(
                    url: current.artworkUrl,
                    videoId: current.videoId,
                    size: 32,
                    radius: 6,
                    label: current.title,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          current.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: WaveType.trackTitle.copyWith(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          current.artist,
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
          // Content: Full Apple Music Karaoke Lyrics Engine
          Expanded(
            child: current == null
                ? const WaveEmpty(
                    icon: WaveIcons.music,
                    title: 'Nothing playing',
                    subtitle: 'Play a track to view live lyrics.',
                  )
                : WaveKaraokeLyricsView(
                    track: current,
                    compact: true,
                    showHeaderControls: true,
                    onClose: null, // Header already has close button
                  ),
          ),
        ],
      ),
    );
  }
}
