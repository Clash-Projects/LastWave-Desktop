import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../features/video/music_video_settings.dart';
import '../../features/video/synced_video_controller.dart';
import '../theme/tokens.dart';

/// Full-bleed synced music video behind the Now Playing page.
///
/// The picture is stretched to cover the whole stage (no blur, so it stays
/// sharp); light scrims are layered only where text sits — the top bar,
/// the lyrics column and the title block — so lyrics stay readable over
/// any footage without dimming the whole video.
class MusicVideoBackdrop extends ConsumerWidget {
  final bool visible;
  final bool lyricsVisible;

  /// Called when a fade finishes, with whether the video is now fully
  /// showing. The page uses it to stop painting what the video hides.
  final ValueChanged<bool>? onFadeEnd;

  const MusicVideoBackdrop({
    super.key,
    required this.visible,
    required this.lyricsVisible,
    this.onFadeEnd,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(
      syncedVideoControllerProvider.select((c) => c.controller),
    );
    if (controller == null) return const SizedBox.shrink();
    final stretch = ref.watch(musicVideoStretchProvider);
    final duration = waveMotion(context, const Duration(milliseconds: 520));
    return IgnorePointer(
      child: AnimatedOpacity(
        duration: duration,
        curve: Curves.easeOutCubic,
        opacity: visible ? 1 : 0,
        onEnd: () => onFadeEnd?.call(visible),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Kept mounted (even at opacity 0) so the texture is live the
            // moment the video is ready and the fade-in has a frame.
            RepaintBoundary(
              child: Video(
                controller: controller,
                controls: NoVideoControls,
                fill: const Color(0xFF000000),
                fit: stretch ? BoxFit.fill : BoxFit.cover,
                wakelock: false,
                pauseUponEnteringBackgroundMode: false,
                resumeUponEnteringForegroundMode: false,
              ),
            ),
            _LegibilityScrim(lyricsVisible: lyricsVisible),
          ],
        ),
      ),
    );
  }
}

class _LegibilityScrim extends StatelessWidget {
  final bool lyricsVisible;
  const _LegibilityScrim({required this.lyricsVisible});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth > 860;
        return Stack(
          fit: StackFit.expand,
          children: [
            // Gentle overall tone so highlights never blow out white text.
            const ColoredBox(color: Color(0x2E000000)),
            // Top: action bar and lyrics header.
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x99000000), Color(0x00000000)],
                  stops: [0.0, 0.22],
                ),
              ),
            ),
            // Bottom: title, artist, quality line and Up Next.
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Color(0xB3000000), Color(0x00000000)],
                  stops: [0.0, 0.38],
                ),
              ),
            ),
            // Lyrics: the right-hand column on wide windows, the centre
            // when the narrow layout shows lyrics full width.
            AnimatedOpacity(
              duration: waveMotion(context, const Duration(milliseconds: 350)),
              opacity: lyricsVisible ? 1 : 0,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: wide
                      ? const LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [
                            Color(0x00000000),
                            Color(0x61000000),
                            Color(0x8C000000),
                            Color(0x61000000),
                          ],
                          stops: [0.36, 0.52, 0.72, 1.0],
                        )
                      : const RadialGradient(
                          radius: 0.9,
                          colors: [Color(0x80000000), Color(0x40000000)],
                        ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
