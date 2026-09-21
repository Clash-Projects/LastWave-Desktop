import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/artwork/animated_artwork_session.dart';

/// Looping muted motion-art player — Now Playing cover only.
///
/// Uses the app-scoped [AnimatedArtworkSession] so the clip survives
/// leaving Now Playing and skipping tracks on the same album. Kept fully
/// visible (transparent fill); the still sleeve fades off on top of it
/// once the first frame is ready, so Windows can still composite.
class AnimatedArtworkVideo extends ConsumerStatefulWidget {
  final String url;
  final double size;

  const AnimatedArtworkVideo({
    super.key,
    required this.url,
    required this.size,
  });

  @override
  ConsumerState<AnimatedArtworkVideo> createState() =>
      _AnimatedArtworkVideoState();
}

class _AnimatedArtworkVideoState extends ConsumerState<AnimatedArtworkVideo> {
  AnimatedArtworkSession? _session;

  @override
  void initState() {
    super.initState();
    _session = ref.read(animatedArtworkSessionProvider);
    _session!.attach(widget.url);
  }

  @override
  void didUpdateWidget(covariant AnimatedArtworkVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _session?.open(widget.url);
    }
  }

  @override
  void dispose() {
    _session?.hideSurface();
    _session?.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(
      animatedArtworkSessionProvider.select((s) => s.controller),
    );
    if (controller == null) return const SizedBox.expand();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _session?.showSurface();
    });
    return IgnorePointer(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: Video(
          controller: controller,
          controls: NoVideoControls,
          fill: const Color(0x00000000),
          fit: BoxFit.cover,
          wakelock: false,
          pauseUponEnteringBackgroundMode: false,
          resumeUponEnteringForegroundMode: false,
        ),
      ),
    );
  }
}
