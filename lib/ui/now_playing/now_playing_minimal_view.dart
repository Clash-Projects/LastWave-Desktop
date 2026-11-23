import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:fluent_ui/fluent_ui.dart' hide Colors;
import 'package:flutter/material.dart' show Colors, Icons;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/artwork/artwork_cache.dart';
import '../../core/audio/stream_models.dart';
import '../../features/lyrics/karaoke_lyrics_view.dart';
import '../components/ambient.dart';
import '../queue/queue_panel.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';
import 'immersive.dart';
import 'now_playing_overflow_menu.dart';

/// Minimal Now Playing layout: Sharp cover art, centered metadata, and distraction-free synced lyrics.
class NowPlayingMinimalView extends ConsumerStatefulWidget {
  final PlayableTrack track;
  final VoidCallback onClose;

  const NowPlayingMinimalView({
    super.key,
    required this.track,
    required this.onClose,
  });

  @override
  ConsumerState<NowPlayingMinimalView> createState() =>
      _NowPlayingMinimalViewState();
}

class _NowPlayingMinimalViewState extends ConsumerState<NowPlayingMinimalView> {
  bool _showQueue = false;
  bool _quickActionsVisible = false;
  Timer? _hideQuickActionsTimer;

  @override
  void dispose() {
    _hideQuickActionsTimer?.cancel();
    super.dispose();
  }

  void _onTopHoverEnter() {
    _hideQuickActionsTimer?.cancel();
    if (!_quickActionsVisible) {
      setState(() => _quickActionsVisible = true);
    }
  }

  void _onTopHoverExit() {
    _hideQuickActionsTimer?.cancel();
    _hideQuickActionsTimer = Timer(const Duration(seconds: 2), () {
      if (mounted && _quickActionsVisible) {
        setState(() => _quickActionsVisible = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final track = widget.track;
    final isImmersive = ref.watch(nowPlayingImmersiveProvider);
    final visualizerEnabled = ref.watch(visualizerEnabledProvider);

    return Stack(
      children: [
        // 1. Backdrop: Cached single-pass artwork-tinted ambient stage
        Positioned.fill(
          child: RepaintBoundary(
            child: WaveAmbientMesh(
              artworkUrl: track.artworkUrl,
              isFullBleed: true,
              cinematic: true,
              apple: ref.watch(ambientStyleProvider) == AmbientStyle.apple,
            ),
          ),
        ),

        // Subtle dark tint over ambient stage to match matte tone
        Positioned.fill(
          child: ColoredBox(
            color: Colors.black.withValues(alpha: 0.28),
          ),
        ),

        // 2. Main Two-Column Row (Album Cover + Centered Info on Left, Synced Lyrics on Right)
        Positioned.fill(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 56, vertical: 40),
            child: Row(
              children: [
                // Left Column: Sharp square cover + centered title & artist
                Expanded(
                  flex: 42,
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: 420,
                        maxHeight: 520,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          // Sharp square album cover
                          ConstrainedBox(
                            constraints: const BoxConstraints(
                              maxWidth: 420,
                              maxHeight: 420,
                            ),
                            child: AspectRatio(
                              aspectRatio: 1,
                              child: Container(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(2.0),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(
                                        alpha: 0.35,
                                      ),
                                      blurRadius: 32,
                                      offset: const Offset(0, 14),
                                    ),
                                  ],
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(2.0),
                                  child: track.artworkUrl.isNotEmpty
                                      ? CachedNetworkImage(
                                          imageUrl: track.artworkUrl,
                                          cacheManager: ArtworkCache.instance,
                                          fit: BoxFit.cover,
                                          errorWidget: (_, _, _) =>
                                              const ColoredBox(
                                            color: Color(0xFF1B1E24),
                                          ),
                                        )
                                      : const ColoredBox(
                                          color: Color(0xFF1B1E24),
                                        ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 18),

                          // Centered Track Title
                          Text(
                            track.title,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                              letterSpacing: -0.2,
                            ),
                          ),
                          const SizedBox(height: 4),

                          // Centered Artist Name
                          Text(
                            track.artist,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w400,
                              color: Colors.white.withValues(alpha: 0.65),
                            ),
                          ),
                          // Nothing else below Artist (zero codec badge, zero bitrate row, zero UP NEXT strip)
                        ],
                      ),
                    ),
                  ),
                ),

                const SizedBox(width: 48),

                // Right Column: Synced Lyrics at full height with spatial duet layout
                Expanded(
                  flex: 58,
                  child: ClipRect(
                    child: WaveKaraokeLyricsView(
                      track: track,
                      compact: false,
                      showHeaderControls: false,
                      fontSize: 34.0,
                      isActive: true,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        // 3. Top Strip Hover Detector for Quick Actions (Zero idle CPU)
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: 64,
          child: MouseRegion(
            onEnter: (_) => _onTopHoverEnter(),
            onExit: (_) => _onTopHoverExit(),
            child: const SizedBox.expand(),
          ),
        ),

        // 4. Top-Left Downward Collapse Chevron
        Positioned(
          top: 18,
          left: 20,
          child: _CollapseChevronButton(
            onTap: widget.onClose,
          ),
        ),

        // 5. Top-Right Quick Actions + Overflow Button
        Positioned(
          top: 18,
          right: 20,
          child: MouseRegion(
            onEnter: (_) => _onTopHoverEnter(),
            onExit: (_) => _onTopHoverExit(),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Quick Actions (Ambient toggle & Fullscreen) faded in on hover
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: _quickActionsVisible ? 1.0 : 0.0,
                  child: IgnorePointer(
                    ignoring: !_quickActionsVisible,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _MinimalActionButton(
                          icon: WaveIcons.visualizer,
                          tooltip: visualizerEnabled
                              ? 'Disable visualizer'
                              : 'Enable visualizer',
                          active: visualizerEnabled,
                          onTap: () => ref
                              .read(visualizerEnabledProvider.notifier)
                              .toggle(),
                        ),
                        const SizedBox(width: 6),
                        _MinimalActionButton(
                          icon: isImmersive
                              ? FluentIcons.mini_contract
                              : WaveIcons.expand,
                          tooltip: isImmersive
                              ? 'Exit fullscreen (F11)'
                              : 'Fullscreen (F11)',
                          active: isImmersive,
                          onTap: () {
                            ref
                                .read(nowPlayingImmersiveProvider.notifier)
                                .state = !isImmersive;
                          },
                        ),
                        const SizedBox(width: 8),
                      ],
                    ),
                  ),
                ),

                // Subtle circular '...' button
                NowPlayingOverflowMenuButton(
                  track: track,
                  onToggleQueue: () {
                    setState(() => _showQueue = !_showQueue);
                  },
                  isQueueOpen: _showQueue,
                  icon: const _MinimalCircularMoreButton(),
                ),
              ],
            ),
          ),
        ),

        // 6. Up Next Queue Drawer (toggled from overflow menu)
        if (_showQueue)
          Positioned(
            top: 0,
            bottom: 0,
            right: 0,
            width: 380,
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF14171A).withValues(alpha: 0.96),
                border: Border(
                  left: BorderSide(
                    color: Colors.white.withValues(alpha: 0.12),
                  ),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.50),
                    blurRadius: 32,
                    offset: const Offset(-8, 0),
                  ),
                ],
              ),
              child: WaveQueuePanel(
                onClose: () => setState(() => _showQueue = false),
                embedded: false,
              ),
            ),
          ),
      ],
    );
  }
}

class _CollapseChevronButton extends StatefulWidget {
  final VoidCallback onTap;

  const _CollapseChevronButton({required this.onTap});

  @override
  State<_CollapseChevronButton> createState() => _CollapseChevronButtonState();
}

class _CollapseChevronButtonState extends State<_CollapseChevronButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Collapse Now Playing',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hover
                  ? Colors.white.withValues(alpha: 0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(
              Icons.keyboard_arrow_down,
              size: 22,
              color: Colors.white.withValues(alpha: _hover ? 0.95 : 0.55),
            ),
          ),
        ),
      ),
    );
  }
}

class _MinimalActionButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final bool active;
  final VoidCallback onTap;

  const _MinimalActionButton({
    required this.icon,
    required this.tooltip,
    this.active = false,
    required this.onTap,
  });

  @override
  State<_MinimalActionButton> createState() => _MinimalActionButtonState();
}

class _MinimalActionButtonState extends State<_MinimalActionButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final accent = waveAccent(context);
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
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: widget.active
                  ? accent.withValues(alpha: 0.20)
                  : (_hover
                      ? Colors.white.withValues(alpha: 0.15)
                      : Colors.white.withValues(alpha: 0.08)),
              borderRadius: BorderRadius.circular(6),
              border: widget.active
                  ? Border.all(color: accent.withValues(alpha: 0.40))
                  : null,
            ),
            child: Center(
              child: Icon(
                widget.icon,
                size: 14,
                color: widget.active
                    ? accent
                    : Colors.white.withValues(alpha: _hover ? 1.0 : 0.80),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MinimalCircularMoreButton extends StatefulWidget {
  const _MinimalCircularMoreButton();

  @override
  State<_MinimalCircularMoreButton> createState() =>
      _MinimalCircularMoreButtonState();
}

class _MinimalCircularMoreButtonState
    extends State<_MinimalCircularMoreButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'More options',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: _hover ? 0.20 : 0.10),
          ),
          child: Center(
            child: Icon(
              FluentIcons.more,
              size: 15,
              color: Colors.white.withValues(alpha: _hover ? 1.0 : 0.85),
            ),
          ),
        ),
      ),
    );
  }
}
