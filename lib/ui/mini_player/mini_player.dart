import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../features/player/playback_service.dart';
import '../components/artwork.dart';
import '../components/buttons.dart' show LWTooltip;
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

/// Small floating mini player — 320×72 card.
///
/// `artwork + title/artist + play/pause + next + expand + close` with a
/// 2px progress hairline. Position ticks are scoped to [_MiniProgress]
/// only. Best-effort always-on-top via `windowManager.setAlwaysOnTop`
/// while mounted (restored on dispose) — harmless if the backend is
/// missing.
class WaveMiniPlayer extends ConsumerStatefulWidget {
  final VoidCallback onClose;
  final VoidCallback onExpand;
  const WaveMiniPlayer(
      {super.key, required this.onClose, required this.onExpand});

  @override
  ConsumerState<WaveMiniPlayer> createState() => _WaveMiniPlayerState();
}

class _WaveMiniPlayerState extends ConsumerState<WaveMiniPlayer> {
  @override
  void initState() {
    super.initState();
    _setTop(true);
  }

  @override
  void dispose() {
    _setTop(false);
    super.dispose();
  }

  Future<void> _setTop(bool value) async {
    try {
      await windowManager.setAlwaysOnTop(value);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    // NOTE: position/duration excluded — _MiniProgress subscribes alone.
    final snap = ref.watch(playbackServiceProvider.select((s) => (
          current: s.current,
          isPlaying: s.isPlaying,
          isBuffering: s.isBuffering,
        )));
    final notifier = ref.read(playbackServiceProvider.notifier);
    final current = snap.current;
    if (current == null) return const SizedBox.shrink();

    return Container(
      constraints: const BoxConstraints(
        minWidth: 280,
        maxWidth: 360,
        minHeight: 64,
      ),
      width: 320,
      height: 72,
      decoration: BoxDecoration(
        color: dark ? WaveColors.surfaceRaised : WaveColors.lightSurface,
        borderRadius: BorderRadius.circular(WaveRadius.menu),
        border: Border.all(color: waveDivider(context)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.5 : 0.18),
            blurRadius: dark ? 28 : 16,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(WaveRadius.menu),
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: widget.onExpand,
                      child: WaveArtwork(
                        url: current.artworkUrl,
                        videoId: current.videoId,
                        size: 48,
                        radius: WaveRadius.artwork,
                        label: current.title,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: GestureDetector(
                        onTap: widget.onExpand,
                        child: Column(
                          mainAxisAlignment:
                              MainAxisAlignment.center,
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            Text(current.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: WaveType.trackTitle
                                    .copyWith(fontSize: 12.5)),
                            Text(current.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: WaveType.meta
                                    .copyWith(fontSize: 11.5)),
                          ],
                        ),
                      ),
                    ),
                    _MiniPlay(
                      playing: snap.isPlaying,
                      buffering: snap.isBuffering,
                      onTap: notifier.toggle,
                    ),
                    _MiniGlyph(
                        tooltip: 'Next',
                        icon: WaveIcons.next,
                        onTap: notifier.next),
                    _MiniGlyph(
                        tooltip: 'Expand',
                        icon: WaveIcons.expand,
                        onTap: widget.onExpand),
                    _MiniGlyph(
                        tooltip: 'Close mini player',
                        icon: FluentIcons.chrome_close,
                        onTap: widget.onClose),
                  ],
                ),
              ),
            ),
            const _MiniProgress(),
          ],
        ),
      ),
    );
  }
}

/// 32px off-white disc + black glyph (dock parity, scaled down).
class _MiniPlay extends StatelessWidget {
  final bool playing;
  final bool buffering;
  final VoidCallback onTap;
  const _MiniPlay(
      {required this.playing,
      required this.buffering,
      required this.onTap});
  @override
  Widget build(BuildContext context) {
    return LWTooltip(
      message: playing ? 'Pause' : 'Play',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 32,
            height: 32,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: WaveColors.defaultAccent,
            ),
            child: Center(
              child: buffering
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: ProgressRing(
                        strokeWidth: 2.5,
                        activeColor: Colors.black,
                        backgroundColor: Color(0x40000000),
                      ),
                    )
                  : Icon(
                      playing
                          ? WaveIcons.pause
                          : WaveIcons.play,
                      size: 14,
                      color: Colors.black,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Sole position subscriber in the mini player.
class _MiniProgress extends ConsumerWidget {
  const _MiniProgress();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = waveIsDark(context);
    final clock = ref.watch(playbackServiceProvider.select((s) => (
          position: s.position,
          duration: s.duration,
        )));
    final progress = clock.duration.inMilliseconds > 0
        ? (clock.position.inMilliseconds /
                clock.duration.inMilliseconds)
            .clamp(0.0, 1.0)
        : 0.0;
    return Container(
      height: 2,
      alignment: Alignment.centerLeft,
      color:
          (dark ? Colors.white : Colors.black).withValues(alpha: 0.1),
      child: FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: progress,
        child: Container(
          color: dark ? Colors.white : Colors.black,
        ),
      ),
    );
  }
}

class _MiniGlyph extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;
  const _MiniGlyph(
      {required this.tooltip, required this.icon, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return LWTooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 34,
            height: 36,
            color: Colors.transparent,
            child: Icon(icon,
                size: 15, color: waveTextSecondary(context)),
          ),
        ),
      ),
    );
  }
}




