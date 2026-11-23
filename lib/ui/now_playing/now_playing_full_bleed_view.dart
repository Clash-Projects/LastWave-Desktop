import 'package:cached_network_image/cached_network_image.dart';
import 'package:fluent_ui/fluent_ui.dart' hide Colors;
import 'package:flutter/material.dart' show Colors;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/artwork/artwork_cache.dart';
import '../../core/audio/stream_models.dart';
import '../../features/lyrics/karaoke_lyrics_view.dart';
import '../queue/queue_panel.dart';
import '../theme/wave_icons.dart';
import 'immersive.dart';
import 'now_playing_overflow_menu.dart';

/// Full Bleed Now Playing layout: Edge-to-edge faded left artwork and clean right lyrics/queue.
class NowPlayingFullBleedView extends ConsumerStatefulWidget {
  final PlayableTrack track;

  const NowPlayingFullBleedView({
    super.key,
    required this.track,
  });

  @override
  ConsumerState<NowPlayingFullBleedView> createState() =>
      _NowPlayingFullBleedViewState();
}

class _NowPlayingFullBleedViewState
    extends ConsumerState<NowPlayingFullBleedView> {
  String _activeTab = 'lyrics'; // 'lyrics' | 'upNext'

  @override
  Widget build(BuildContext context) {
    final track = widget.track;
    final isImmersive = ref.watch(nowPlayingImmersiveProvider);

    return ColoredBox(
      color: const Color(0xFF0D0E10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;
          final artWidth = w * 0.55;

          return Stack(
            fit: StackFit.expand,
            children: [
              // 1. Left Full-Bleed Artwork with Horizontal Gradient Fade
              Positioned(
                top: 0,
                bottom: 0,
                left: 0,
                width: artWidth,
                child: RepaintBoundary(
                  child: ShaderMask(
                    shaderCallback: (bounds) => const LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      stops: [0.0, 0.52, 0.88, 1.0],
                      colors: [
                        Colors.white,
                        Colors.white,
                        Colors.transparent,
                        Colors.transparent,
                      ],
                    ).createShader(bounds),
                    blendMode: BlendMode.dstIn,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (track.artworkUrl.isNotEmpty)
                          CachedNetworkImage(
                            imageUrl: track.artworkUrl,
                            cacheManager: ArtworkCache.instance,
                            fit: BoxFit.cover,
                            width: artWidth,
                            height: h,
                            errorWidget: (_, _, _) =>
                                const ColoredBox(color: Color(0xFF14171A)),
                          )
                        else
                          const ColoredBox(color: Color(0xFF14171A)),
                        // Scrim to guarantee top-left track info legibility
                        const DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              stops: [0.0, 0.25, 0.80, 1.0],
                              colors: [
                                Color(0x35000000),
                                Colors.transparent,
                                Colors.transparent,
                                Color(0x25000000),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // 2. Right Pane: Lyrics or Up Next Queue
              Positioned(
                top: 0,
                bottom: 0,
                left: w * 0.48,
                right: 0,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 72, 48, 32),
                  child: _activeTab == 'lyrics'
                      ? WaveKaraokeLyricsView(
                          track: track,
                          compact: false,
                          showHeaderControls: false,
                          fontSize: 34.0,
                          isActive: true,
                        )
                      : const WaveQueuePanel(
                          onClose: null,
                          embedded: true,
                        ),
                ),
              ),

              // 3. Top-Left Floating Track Pill (+ Back button in immersive fullscreen)
              Positioned(
                top: 20,
                left: 20,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isImmersive) ...[
                      _FullBleedIconButton(
                        icon: FluentIcons.chevron_left,
                        tooltip: 'Exit fullscreen (F11)',
                        onTap: () {
                          ref.read(nowPlayingImmersiveProvider.notifier).state =
                              false;
                        },
                      ),
                      const SizedBox(width: 8),
                    ],
                    Container(
                      constraints: const BoxConstraints(maxWidth: 260),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.48),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.10),
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            track.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w400,
                              color: Colors.white.withValues(alpha: 0.72),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // 4. Top-Right Control Bar: Segmented Toggle (Lyrics | Up next), Fullscreen, Overflow (...)
              Positioned(
                top: 20,
                right: 20,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Segmented Toggle
                    Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _SegmentTab(
                            label: 'Lyrics',
                            active: _activeTab == 'lyrics',
                            onTap: () => setState(() => _activeTab = 'lyrics'),
                          ),
                          _SegmentTab(
                            label: 'Up next',
                            active: _activeTab == 'upNext',
                            onTap: () => setState(() => _activeTab = 'upNext'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),

                    // Fullscreen Button
                    _FullBleedIconButton(
                      icon: isImmersive
                          ? FluentIcons.mini_contract
                          : WaveIcons.expand,
                      tooltip: isImmersive
                          ? 'Exit fullscreen (F11)'
                          : 'Fullscreen (F11)',
                      onTap: () {
                        ref.read(nowPlayingImmersiveProvider.notifier).state =
                            !isImmersive;
                      },
                    ),
                    const SizedBox(width: 8),

                    // Overflow Menu Button
                    NowPlayingOverflowMenuButton(
                      track: track,
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SegmentTab extends StatefulWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _SegmentTab({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  State<_SegmentTab> createState() => _SegmentTabState();
}

class _SegmentTabState extends State<_SegmentTab> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.active;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: active
                ? Colors.white.withValues(alpha: 0.92)
                : (_hover
                    ? Colors.white.withValues(alpha: 0.16)
                    : Colors.transparent),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: active
                  ? const Color(0xFF111214)
                  : Colors.white.withValues(alpha: 0.80),
            ),
          ),
        ),
      ),
    );
  }
}

class _FullBleedIconButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _FullBleedIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  State<_FullBleedIconButton> createState() => _FullBleedIconButtonState();
}

class _FullBleedIconButtonState extends State<_FullBleedIconButton> {
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
                size: 15,
                color: Colors.white.withValues(alpha: _hover ? 1.0 : 0.85),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
