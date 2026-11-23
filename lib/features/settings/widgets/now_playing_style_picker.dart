import 'package:fluent_ui/fluent_ui.dart' hide Colors;
import 'package:flutter/material.dart' show Colors;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/player/playback_service.dart';
import '../../../ui/now_playing/now_playing_style.dart';
import '../../../ui/theme/tokens.dart';

/// Settings miniature sandbox preview picker for Now Playing styles.
/// Renders 3 zero-cost miniature previews with static primitives.
class NowPlayingStylePicker extends ConsumerWidget {
  const NowPlayingStylePicker({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentStyle = ref.watch(nowPlayingStyleProvider);
    final currentTrack = ref.watch(
      playbackServiceProvider.select((s) => s.current),
    );
    final coverUrl = currentTrack?.artworkUrl ?? '';
    final accent = waveAccent(context);
    final divider = waveDivider(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 540;

        final cards = [
          for (final style in NowPlayingStyle.values)
            _StylePreviewCard(
              style: style,
              selected: currentStyle == style,
              coverUrl: coverUrl,
              accent: accent,
              divider: divider,
              onTap: () {
                ref.read(nowPlayingStyleProvider.notifier).set(style);
              },
            ),
        ];

        if (isNarrow) {
          return Column(
            children: [
              for (var i = 0; i < cards.length; i++) ...[
                if (i > 0) const SizedBox(height: 12),
                cards[i],
              ],
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < cards.length; i++) ...[
              if (i > 0) const SizedBox(width: 14),
              Expanded(child: cards[i]),
            ],
          ],
        );
      },
    );
  }
}

class _StylePreviewCard extends StatefulWidget {
  final NowPlayingStyle style;
  final bool selected;
  final String coverUrl;
  final Color accent;
  final Color divider;
  final VoidCallback onTap;

  const _StylePreviewCard({
    required this.style,
    required this.selected,
    required this.coverUrl,
    required this.accent,
    required this.divider,
    required this.onTap,
  });

  @override
  State<_StylePreviewCard> createState() => _StylePreviewCardState();
}

class _StylePreviewCardState extends State<_StylePreviewCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final accent = widget.accent;
    final divider = widget.divider;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 1. Miniature Preview Canvas: 16:10 AspectRatio
            AspectRatio(
              aspectRatio: 16 / 10,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: selected
                        ? accent
                        : (_hover
                            ? accent.withValues(alpha: 0.5)
                            : divider),
                    width: selected ? 1.5 : 1.0,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8.5),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // Miniature Canvas Rendering based on style
                      switch (widget.style) {
                        NowPlayingStyle.standard => _DefaultMiniature(
                            coverUrl: widget.coverUrl,
                            accent: accent,
                          ),
                        NowPlayingStyle.fullBleed => _FullBleedMiniature(
                            coverUrl: widget.coverUrl,
                          ),
                        NowPlayingStyle.minimal => _MinimalMiniature(
                            coverUrl: widget.coverUrl,
                            accent: accent,
                          ),
                      },

                      // Selected indicator: 18x18 accent circle with white checkmark
                      if (selected)
                        Positioned(
                          bottom: 6,
                          right: 6,
                          child: Container(
                            width: 18,
                            height: 18,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: accent,
                            ),
                            child: const Center(
                              child: Icon(
                                FluentIcons.check_mark,
                                size: 10,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),

            // 2. Card Label Below Preview
            Text(
              widget.style.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: waveTextPrimary(context),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              widget.style.subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                color: waveTextTertiary(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Miniature Helper: Crisp Pill Bar
// ---------------------------------------------------------------------------

Widget _bar(
  double widthFactor, {
  double height = 3.5,
  double opacity = 0.25,
  bool alignRight = false,
  bool centered = false,
}) {
  return Align(
    alignment: centered
        ? Alignment.center
        : (alignRight ? Alignment.centerRight : Alignment.centerLeft),
    child: FractionallySizedBox(
      widthFactor: widthFactor.clamp(0.0, 1.0),
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: opacity),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    ),
  );
}

Widget _cachedOrPlaceholderCover(
  String coverUrl,
  Color accent, {
  BorderRadius? radius,
}) {
  if (coverUrl.isNotEmpty) {
    return ClipRRect(
      borderRadius: radius ?? BorderRadius.circular(5),
      child: Image.network(
        coverUrl,
        cacheWidth: 120,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1B1E24),
            borderRadius: radius ?? BorderRadius.circular(5),
          ),
        ),
      ),
    );
  }
  return Container(
    decoration: BoxDecoration(
      borderRadius: radius ?? BorderRadius.circular(5),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          accent.withValues(alpha: 0.28),
          const Color(0xFF1B1E24),
        ],
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Miniature 1: Default
// ---------------------------------------------------------------------------

class _DefaultMiniature extends StatelessWidget {
  final String coverUrl;
  final Color accent;

  const _DefaultMiniature({
    required this.coverUrl,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Color.lerp(const Color(0xFF14171A), accent, 0.08) ??
          const Color(0xFF14171A),
      padding: const EdgeInsets.all(10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Left Column (flex: 42)
          Expanded(
            flex: 42,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: _cachedOrPlaceholderCover(
                      coverUrl,
                      accent,
                      radius: BorderRadius.circular(5),
                    ),
                  ),
                ),
                const SizedBox(height: 5),
                _bar(0.55, height: 4, opacity: 0.85),
                const SizedBox(height: 2.5),
                _bar(0.38, height: 3, opacity: 0.45),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Container(
                      width: 3.5,
                      height: 3.5,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: accent,
                      ),
                    ),
                    const SizedBox(width: 3),
                    Expanded(child: _bar(0.50, height: 2.5, opacity: 0.55)),
                  ],
                ),
                const SizedBox(height: 4),
                _bar(0.85, height: 4, opacity: 0.18),
              ],
            ),
          ),
          const SizedBox(width: 8),

          // Right Column (flex: 58)
          Expanded(
            flex: 58,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Top floating pill bar
                Container(
                  height: 8,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    color: Colors.white.withValues(alpha: 0.10),
                  ),
                ),
                const Spacer(),
                _bar(0.70, opacity: 0.22),
                const SizedBox(height: 4),
                _bar(0.88, height: 5, opacity: 0.92),
                const SizedBox(height: 4),
                _bar(0.75, opacity: 0.28),
                const SizedBox(height: 4),
                _bar(0.62, opacity: 0.22),
                const SizedBox(height: 4),
                _bar(0.80, opacity: 0.14),
                const Spacer(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Miniature 2: Full Bleed
// ---------------------------------------------------------------------------

class _FullBleedMiniature extends StatelessWidget {
  final String coverUrl;

  const _FullBleedMiniature({
    required this.coverUrl,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0D0E10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final cardWidth = constraints.maxWidth;

          return Stack(
            fit: StackFit.expand,
            children: [
              // Left 56% edge-to-edge artwork fading into dark right half
              Positioned(
                top: 0,
                bottom: 0,
                left: 0,
                width: cardWidth * 0.56,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _cachedOrPlaceholderCover(
                      coverUrl,
                      const Color(0xFF0D0E10),
                      radius: BorderRadius.zero,
                    ),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          stops: [0.35, 1.0],
                          colors: [
                            Colors.transparent,
                            Color(0xFF0D0E10),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // Top-left micro title pill
              Positioned(
                top: 7,
                left: 7,
                child: Container(
                  width: 34,
                  height: 12,
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(3),
                    color: Colors.black.withValues(alpha: 0.55),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _bar(0.80, height: 2, opacity: 0.90),
                      const SizedBox(height: 1.5),
                      _bar(0.50, height: 1.5, opacity: 0.60),
                    ],
                  ),
                ),
              ),

              // Top-right micro pills (Lyrics | Up next + dot)
              Positioned(
                top: 7,
                right: 7,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 14,
                      height: 6,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.90),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 2),
                    Container(
                      width: 14,
                      height: 6,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: 0.40),
                      ),
                    ),
                  ],
                ),
              ),

              // Right 50% lyrics
              Positioned(
                top: 22,
                bottom: 10,
                right: 10,
                left: cardWidth * 0.48,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _bar(0.72, height: 3.2, opacity: 0.24),
                    const SizedBox(height: 3),
                    _bar(0.92, height: 4.5, opacity: 0.95),
                    const SizedBox(height: 3),
                    _bar(0.80, height: 3.2, opacity: 0.24),
                    const SizedBox(height: 3),
                    _bar(0.65, height: 3.2, opacity: 0.24),
                    const SizedBox(height: 3),
                    _bar(0.85, height: 3.2, opacity: 0.24),
                    const SizedBox(height: 3),
                    _bar(0.60, height: 3.2, opacity: 0.20),
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

// ---------------------------------------------------------------------------
// Miniature 3: Minimal
// ---------------------------------------------------------------------------

class _MinimalMiniature extends StatelessWidget {
  final String coverUrl;
  final Color accent;

  const _MinimalMiniature({
    required this.coverUrl,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Color.lerp(const Color(0xFF1A1C20), accent, 0.14) ??
          const Color(0xFF1A1C20),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Top-left micro chevron dot
          Positioned(
            top: 7,
            left: 8,
            child: Container(
              width: 6,
              height: 3,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ),

          // Top-right micro '...' circle
          Positioned(
            top: 6,
            right: 8,
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.14),
              ),
            ),
          ),

          // Two-column body
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 16, 12, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Left (flex: 42 — centered)
                Expanded(
                  flex: 42,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Expanded(
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: _cachedOrPlaceholderCover(
                            coverUrl,
                            accent,
                            radius: BorderRadius.zero,
                          ),
                        ),
                      ),
                      const SizedBox(height: 5),
                      _bar(0.60, height: 4, opacity: 0.90, centered: true),
                      const SizedBox(height: 2.5),
                      _bar(0.42, height: 2.8, opacity: 0.45, centered: true),
                    ],
                  ),
                ),
                const SizedBox(width: 10),

                // Right (flex: 58 — duet layout)
                Expanded(
                  flex: 58,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _bar(0.70, opacity: 0.15, alignRight: true),
                      const SizedBox(height: 3),
                      _bar(0.58, opacity: 0.25, alignRight: true),
                      const SizedBox(height: 3),
                      _bar(
                        0.44,
                        height: 4.5,
                        opacity: 0.95,
                        alignRight: true,
                      ),
                      const SizedBox(height: 3),
                      _bar(0.78, opacity: 0.30),
                      const SizedBox(height: 3),
                      _bar(0.64, opacity: 0.22),
                      const SizedBox(height: 3),
                      _bar(0.72, opacity: 0.12, alignRight: true),
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
