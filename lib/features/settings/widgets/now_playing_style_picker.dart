import 'package:fluent_ui/fluent_ui.dart' hide Colors;
import 'package:flutter/material.dart' show Colors;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../ui/now_playing/now_playing_style.dart';
import '../../../ui/theme/tokens.dart';
import '../../../ui/theme/wave_icons.dart';

/// Settings miniature preview picker for Now Playing styles.
/// Renders 3 clean, cover-art-free schematic previews in order:
/// Full Bleed (default), Minimal, and Old.
class NowPlayingStylePicker extends ConsumerWidget {
  const NowPlayingStylePicker({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentStyle = ref.watch(nowPlayingStyleProvider);
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
  final Color accent;
  final Color divider;
  final VoidCallback onTap;

  const _StylePreviewCard({
    required this.style,
    required this.selected,
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
                      switch (widget.style) {
                        NowPlayingStyle.fullBleed => _FullBleedMiniature(
                            accent: accent,
                          ),
                        NowPlayingStyle.minimal => _MinimalMiniature(
                            accent: accent,
                          ),
                        NowPlayingStyle.standard => _OldMiniature(
                            accent: accent,
                          ),
                      },

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
                            child: Center(
                              child: Icon(
                                FluentIcons.check_mark,
                                size: 10,
                                color: onAccentFor(accent),
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
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: waveTextTertiary(context),
                height: 1.25,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 1. Full Bleed schematic: continuous edge-to-edge ambient canvas glow on the
/// left smoothly melting (zero partition seam) into clean right-side lyrics.
class _FullBleedMiniature extends StatelessWidget {
  final Color accent;
  const _FullBleedMiniature({required this.accent});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          stops: const [0.0, 0.34, 0.58, 0.82, 1.0],
          colors: [
            Color.lerp(const Color(0xFF1A1D26), accent, 0.48)!,
            Color.lerp(const Color(0xFF181B24), accent, 0.34)!,
            Color.lerp(const Color(0xFF141720), accent, 0.16)!,
            const Color(0xFF12151E),
            const Color(0xFF10131B),
          ],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Soft abstract canvas aura on the left (no hard box or divider line)
          Positioned(
            top: -12,
            bottom: -12,
            left: -10,
            right: 76,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(-0.35, 0.0),
                  radius: 0.95,
                  colors: [
                    accent.withValues(alpha: 0.32),
                    accent.withValues(alpha: 0.10),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),

          // Subtle motion-play emblem on left canvas zone
          Align(
            alignment: const Alignment(-0.56, 0.0),
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.10),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.18),
                  width: 0.8,
                ),
              ),
              child: Icon(
                WaveIcons.music,
                size: 11,
                color: Colors.white.withValues(alpha: 0.72),
              ),
            ),
          ),

          // Top-right mini action dots (Fullscreen + circular '...')
          Positioned(
            top: 6,
            right: 6,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 3),
                Container(
                  width: 7.5,
                  height: 7.5,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.22),
                  ),
                ),
              ],
            ),
          ),

          // Right-side clean lyrics stack
          Positioned(
            top: 22,
            bottom: 18,
            left: 96,
            right: 12,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _LyricBar(widthFactor: 0.70, alpha: 0.22, height: 3),
                const SizedBox(height: 5),
                _LyricBar(widthFactor: 0.95, alpha: 0.92, height: 4),
                const SizedBox(height: 5),
                _LyricBar(widthFactor: 0.78, alpha: 0.34, height: 3),
                const SizedBox(height: 5),
                _LyricBar(widthFactor: 0.62, alpha: 0.20, height: 3),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 2. Minimal schematic: sharp square abstract cover + centered title/artist
/// on the left, alternating spatial duet lyrics on the right.
class _MinimalMiniature extends StatelessWidget {
  final Color accent;
  const _MinimalMiniature({required this.accent});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.lerp(const Color(0xFF1A1E28), accent, 0.16)!,
            const Color(0xFF12151E),
          ],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Top-left collapse chevron indicator
          Positioned(
            top: 6,
            left: 7,
            child: Container(
              width: 6,
              height: 2,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ),

          // Top-right 3 mini action dots (Ambient, Fullscreen, '...')
          Positioned(
            top: 6,
            right: 6,
            child: _TopThreeMiniDots(accent: accent),
          ),

          Padding(
            padding: const EdgeInsets.fromLTRB(12, 16, 12, 10),
            child: Row(
              children: [
                // Left column: sharp cover block + centered metadata
                Expanded(
                  flex: 42,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Expanded(
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: _AbstractCoverBlock(
                            accent: accent,
                            radius: 2,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        width: 44,
                        height: 3.5,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.85),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Container(
                        width: 28,
                        height: 2.5,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.35),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                // Right column: alternating duet lyrics
                Expanded(
                  flex: 58,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Align(
                        alignment: Alignment.centerRight,
                        child: _LyricBar(
                          widthFactor: 0.64,
                          alpha: 0.24,
                          height: 3,
                        ),
                      ),
                      const SizedBox(height: 5),
                      const Align(
                        alignment: Alignment.centerRight,
                        child: _LyricBar(
                          widthFactor: 0.78,
                          alpha: 0.92,
                          height: 4,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: _LyricBar(
                          widthFactor: 0.72,
                          alpha: 0.36,
                          height: 3,
                        ),
                      ),
                      const SizedBox(height: 5),
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: _LyricBar(
                          widthFactor: 0.56,
                          alpha: 0.22,
                          height: 3,
                        ),
                      ),
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

/// 3. Old (classic dual-pane) schematic: rounded cover card + left-aligned
/// title, audio badge & UP NEXT on the left, classic lyrics on the right.
class _OldMiniature extends StatelessWidget {
  final Color accent;
  const _OldMiniature({required this.accent});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.lerp(const Color(0xFF1B1E2A), accent, 0.14)!,
            const Color(0xFF11141C),
          ],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            top: 6,
            right: 6,
            child: _TopThreeMiniDots(accent: accent),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 14, 10, 8),
            child: Row(
              children: [
                // Left column: rounded cover + metadata + codec dot + up next
                Expanded(
                  flex: 42,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: _AbstractCoverBlock(
                            accent: accent,
                            radius: 6,
                          ),
                        ),
                      ),
                      const SizedBox(height: 5),
                      Container(
                        width: 48,
                        height: 3.5,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.85),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Container(
                        width: 32,
                        height: 2.5,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.42),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Container(
                            width: 4,
                            height: 4,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: accent,
                            ),
                          ),
                          const SizedBox(width: 3),
                          Container(
                            width: 24,
                            height: 2,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.30),
                              borderRadius: BorderRadius.circular(1),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Container(
                        width: 54,
                        height: 2.5,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(1.5),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                // Right column: classic left-aligned lyrics
                const Expanded(
                  flex: 58,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _LyricBar(widthFactor: 0.72, alpha: 0.24, height: 3),
                      SizedBox(height: 5),
                      _LyricBar(widthFactor: 0.96, alpha: 0.92, height: 4),
                      SizedBox(height: 5),
                      _LyricBar(widthFactor: 0.82, alpha: 0.34, height: 3),
                      SizedBox(height: 5),
                      _LyricBar(widthFactor: 0.64, alpha: 0.22, height: 3),
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

class _AbstractCoverBlock extends StatelessWidget {
  final Color accent;
  final double radius;

  const _AbstractCoverBlock({required this.accent, required this.radius});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.lerp(const Color(0xFF2A2F3D), accent, 0.42)!,
            Color.lerp(const Color(0xFF1E222E), accent, 0.16)!,
          ],
        ),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.12),
          width: 0.7,
        ),
      ),
      child: Center(
        child: Icon(
          WaveIcons.music,
          size: 15,
          color: Colors.white.withValues(alpha: 0.55),
        ),
      ),
    );
  }
}

class _TopThreeMiniDots extends StatelessWidget {
  final Color accent;
  const _TopThreeMiniDots({required this.accent});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.30),
            border: Border.all(color: accent.withValues(alpha: 0.6), width: 0.6),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 2.5),
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 3),
        Container(
          width: 7.5,
          height: 7.5,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: 0.22),
          ),
        ),
      ],
    );
  }
}

class _LyricBar extends StatelessWidget {
  final double widthFactor;
  final double alpha;
  final double height;

  const _LyricBar({
    required this.widthFactor,
    required this.alpha,
    required this.height,
  });

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      widthFactor: widthFactor,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: alpha),
          borderRadius: BorderRadius.circular(height / 2),
        ),
      ),
    );
  }
}
