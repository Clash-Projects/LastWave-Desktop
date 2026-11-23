import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/artwork/animated_artwork_session.dart';

/// Forces alpha = 255 on every pixel without altering RGB.
///
/// On Windows/Linux software rendering (`MPV_RENDER_PARAM_SW_FORMAT = "rgb0"`),
/// mpv writes `0x00` into the 4th byte. Flutter/Skia composites pixel-buffer
/// textures as premultiplied RGBA, so `(R, G, B, 0)` blends *additively* over
/// the ambient backdrop (`dst + src`), causing abnormally bright highlights
/// and making dark video regions bleed transparently into the background.
const ColorFilter _opaqueAlphaFilter = ColorFilter.matrix(<double>[
  1, 0, 0, 0, 0,
  0, 1, 0, 0, 0,
  0, 0, 1, 0, 0,
  0, 0, 0, 0, 255,
]);

/// Looping muted motion-art player — Now Playing cover / Full Bleed canvas.
///
/// Uses the app-scoped [AnimatedArtworkSession] so the clip survives
/// leaving Now Playing and skipping tracks on the same album. Kept fully
/// visible (transparent fill); the still sleeve fades off on top of it
/// once the first frame is ready, so Windows can still composite.
class AnimatedArtworkVideo extends ConsumerStatefulWidget {
  final String url;
  final String fallbackUrl;
  final double? size;
  final double? width;
  final double? height;

  /// When true, uses [canvasPanelSessionProvider] (portrait 9:16 texture)
  /// instead of [animatedArtworkSessionProvider] (square 1:1 texture).
  final bool usePortraitSession;

  const AnimatedArtworkVideo({
    super.key,
    required this.url,
    this.fallbackUrl = '',
    this.size,
    this.width,
    this.height,
    this.usePortraitSession = false,
  });

  @override
  ConsumerState<AnimatedArtworkVideo> createState() =>
      _AnimatedArtworkVideoState();
}

class _AnimatedArtworkVideoState extends ConsumerState<AnimatedArtworkVideo> {
  AnimatedArtworkSession? _session;

  ChangeNotifierProvider<AnimatedArtworkSession> get _provider =>
      widget.usePortraitSession
          ? canvasPanelSessionProvider
          : animatedArtworkSessionProvider;

  @override
  void initState() {
    super.initState();
    _session = ref.read(_provider);
    _session!.attach(widget.url, fallbackUrl: widget.fallbackUrl);
  }

  @override
  void didUpdateWidget(covariant AnimatedArtworkVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.usePortraitSession != widget.usePortraitSession) {
      _session?.hideSurface();
      _session?.detach();
      _session = ref.read(_provider);
      _session!.attach(widget.url, fallbackUrl: widget.fallbackUrl);
      return;
    }
    if (oldWidget.url != widget.url ||
        oldWidget.fallbackUrl != widget.fallbackUrl) {
      _session?.open(widget.url, fallbackUrl: widget.fallbackUrl);
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
    final controller = ref.watch(_provider.select((s) => s.controller));
    if (controller == null) return const SizedBox.expand();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _session?.showSurface();
    });
    return IgnorePointer(
      child: SizedBox(
        width: widget.width ?? widget.size ?? double.infinity,
        height: widget.height ?? widget.size ?? double.infinity,
        child: ColorFiltered(
          colorFilter: _opaqueAlphaFilter,
          child: Video(
            controller: controller,
            controls: NoVideoControls,
            fill: const Color(0xFF000000),
            fit: BoxFit.cover,
            // Must stay FilterQuality.low (bilinear): FilterQuality.high
            // forces cubic/mipmap sampling which renders solid black on
            // Flutter Windows PixelBufferTexture (ANGLE/Skia).
            filterQuality: FilterQuality.low,
            wakelock: false,
            pauseUponEnteringBackgroundMode: false,
            resumeUponEnteringForegroundMode: false,
          ),
        ),
      ),
    );
  }
}
