import 'package:cached_network_image/cached_network_image.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/artwork/animated_artwork_session.dart';
import '../../features/player/playback_service.dart';
import '../../features/spotify/canvas_clip.dart';
import '../theme/tokens.dart';
import 'canvas_geometry.dart';

export 'canvas_geometry.dart';
import '../theme/wave_icons.dart';

const Color _white70 = Color(0xB3FFFFFF);
const Color _white54 = Color(0x8AFFFFFF);

/// Canvas side panel: the current track's looping video in an exact 9:16
/// frame, docked on the left of the page (the mirror of the queue on the
/// right). It pushes the page aside instead of covering it.
///
/// [open] is passed down because the shell keeps this widget mounted while
/// the panel is slid shut: the clip lookup and the player only run while
/// it is open.
class WaveCanvasPanel extends ConsumerStatefulWidget {
  final bool open;
  final VoidCallback onClose;
  const WaveCanvasPanel({super.key, required this.open, required this.onClose});

  @override
  ConsumerState<WaveCanvasPanel> createState() => _WaveCanvasPanelState();
}

class _WaveCanvasPanelState extends ConsumerState<WaveCanvasPanel> {
  AnimatedArtworkSession? _session;
  String _attached = '';

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  void _release() {
    if (_attached.isEmpty) return;
    _attached = '';
    _session?.hideSurface();
    _session?.detach();
  }

  /// Attach / retarget / release the player after the frame (the session
  /// notifies listeners, which must not happen inside build).
  void _sync(String url) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!widget.open || url.isEmpty) {
        _release();
        return;
      }
      final session = (_session ?? ref.read(canvasPanelSessionProvider))!;
      _session = session;
      if (_attached.isEmpty) {
        session.attach(url);
      } else if (_attached != url) {
        session.open(url);
      }
      _attached = url;
      session.showSurface();
    });
  }

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final track = ref.watch(playbackServiceProvider.select((s) => s.current));

    CanvasPanelClip? clip;
    var note = '';
    var loading = false;
    if (widget.open && track != null) {
      final async = ref.watch(canvasPanelClipProvider((
        title: track.title,
        artist: track.artist,
        album: track.album,
        durationMs: track.duration.inMilliseconds,
      )));
      clip = async.valueOrNull?.clip;
      note = async.valueOrNull?.note ?? '';
      loading = async.isLoading;
    }
    _sync(clip?.url ?? '');

    return ColoredBox(
      color: dark ? const Color(0xFF000000) : const Color(0xFF111111),
      child: LayoutBuilder(
        builder: (context, c) {
          // The largest exact 9:16 frame that fits the panel.
          var w = c.maxWidth;
          var h = w / kCanvasAspect;
          if (h > c.maxHeight) {
            h = c.maxHeight;
            w = h * kCanvasAspect;
          }
          return Center(
            child: SizedBox(
              width: w,
              height: h,
              child: _Frame(
                title: track?.title ?? '',
                artist: track?.artist ?? '',
                artworkUrl: track?.artworkUrl ?? '',
                clip: clip,
                loading: loading,
                note: note,
                open: widget.open,
                onClose: widget.onClose,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Frame extends ConsumerWidget {
  final String title;
  final String artist;
  final String artworkUrl;
  final CanvasPanelClip? clip;
  final bool loading;
  final String note;
  final bool open;
  final VoidCallback onClose;
  const _Frame({
    required this.title,
    required this.artist,
    required this.artworkUrl,
    required this.clip,
    required this.loading,
    required this.note,
    required this.open,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = clip?.url ?? '';
    final ready = url.isNotEmpty &&
        ref.watch(
          canvasPanelSessionProvider.select((s) => s.isReadyFor(url)),
        );
    final controller = open && url.isNotEmpty
        ? ref.watch(canvasPanelSessionProvider.select((s) => s.controller))
        : null;

    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Still cover: shows while the clip loads, and when the track has
          // no canvas at all. It fades OUT as the clip fades in and is not
          // painted at all while the clip plays: the video surface can carry
          // translucent pixels (and a fade can be caught mid-way), which let
          // the cover bleed through and mix with the canvas.
          if (artworkUrl.isNotEmpty)
            AnimatedOpacity(
              opacity: ready ? 0 : 1,
              duration: const Duration(milliseconds: 300),
              // At opacity 0 the cover is not painted at all.
              child: CachedNetworkImage(
                imageUrl: artworkUrl,
                fit: BoxFit.cover,
                fadeInDuration: Duration.zero,
                errorWidget: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          if (clip == null)
            ColoredBox(color: Colors.black.withValues(alpha: 0.55)),
          if (controller != null)
            AnimatedOpacity(
              opacity: ready ? 1 : 0,
              duration: const Duration(milliseconds: 300),
              child: IgnorePointer(
                child: Video(
                  controller: controller,
                  controls: NoVideoControls,
                  // Opaque backing: the canvas is the only picture while it
                  // plays, nothing underneath may show through it.
                  fill: const Color(0xFF000000),
                  fit: BoxFit.cover,
                  wakelock: false,
                  pauseUponEnteringBackgroundMode: false,
                  resumeUponEnteringForegroundMode: false,
                ),
              ),
            ),
          // Top: source + close.
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 6, 18),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.6),
                    Colors.transparent,
                  ],
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      clip != null
                          ? 'CANVAS · ${clip!.source.toUpperCase()}'
                          : 'CANVAS',
                      style: WaveType.overline.copyWith(color: Colors.white),
                    ),
                  ),
                  if (loading)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: ProgressRing(strokeWidth: 2),
                    ),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: const Icon(WaveIcons.close, size: 12),
                    style: ButtonStyle(
                      foregroundColor: WidgetStatePropertyAll(Colors.white),
                    ),
                    onPressed: onClose,
                  ),
                ],
              ),
            ),
          ),
          // Bottom: what is playing, or why there is no clip.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 28, 14, 14),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.75),
                  ],
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (title.isEmpty)
                    Text(
                      'Play a track to see its canvas',
                      style: WaveType.meta.copyWith(color: _white70),
                    )
                  else ...[
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: WaveType.trackTitle.copyWith(color: Colors.white),
                    ),
                    Text(
                      artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: WaveType.meta.copyWith(color: _white70),
                    ),
                    if (clip == null && !loading) ...[
                      const SizedBox(height: 6),
                      Text(
                        note.isEmpty ? 'No canvas for this track.' : note,
                        style: WaveType.meta.copyWith(
                          color: _white54,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
