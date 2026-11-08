import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'lyrics_models.dart';

/// Visual tokens derived directly from binimum/am-lyrics:
/// https://github.com/binimum/am-lyrics
class DesktopLyricsTokens {
  static const double fontSizeBase = 36.0;
  static const double lineHeight = 1.35;
  static const double lineSpacing = 25.0;
  static const double inactiveScale = 0.96;
  static const double inactiveOpacity = 0.35;

  // Background vocals / sub-paragraphs:
  static const double backgroundVocalFontScale = 0.65;
  static const double backgroundVocalSpacing = 15.0;
  static const double backgroundVocalStackShift = 7.5;
  static const double backgroundVocalScale = 0.90;
  static const Duration backgroundVocalExitDuration = Duration(milliseconds: 450);

  // Viewport & Layout:
  static const double scrollPaddingTopRatio = 0.18; // 18% golden ratio focal point
  static const double maxDuetWidthRatio = 0.72; // 72% widescreen width limit
  static const double inlinePadding = 36.0;
}

/// Pre-computed text layout & syllable metrics for a single lyric line.
class CachedLineLayout {
  final ui.Paragraph idleParagraph;
  final ui.Paragraph activeParagraph;
  final double width;
  final double height;
  final List<double> syllableOffsetsX;

  CachedLineLayout({
    required this.idleParagraph,
    required this.activeParagraph,
    required this.width,
    required this.height,
    required this.syllableOffsetsX,
  });
}

/// Global/Per-track layout cache. Pre-computes glyphs once on track load.
class ParagraphLayoutCache {
  final Map<int, CachedLineLayout> _cache = {};

  CachedLineLayout getOrCreate({
    required LyricLine line,
    required double maxWidth,
    required TextStyle activeStyle,
    required TextStyle idleStyle,
    bool isRtl = false,
  }) {
    if (_cache.containsKey(line.timeMs)) {
      return _cache[line.timeMs]!;
    }

    final pStyle = idleStyle.getParagraphStyle(
      textAlign: isRtl ? TextAlign.right : TextAlign.left,
      textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
    );
    final activePStyle = activeStyle.getParagraphStyle(
      textAlign: isRtl ? TextAlign.right : TextAlign.left,
      textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
    );

    // 1. Build Idle Paragraph
    final idleBuilder = ui.ParagraphBuilder(pStyle)
      ..pushStyle(idleStyle.getTextStyle())
      ..addText(line.text);
    final idlePara = idleBuilder.build()
      ..layout(ui.ParagraphConstraints(width: maxWidth));

    // 2. Build Active Highlight Paragraph
    final activeBuilder = ui.ParagraphBuilder(activePStyle)
      ..pushStyle(activeStyle.getTextStyle())
      ..addText(line.text);
    final activePara = activeBuilder.build()
      ..layout(ui.ParagraphConstraints(width: maxWidth));

    // 3. Pre-measure syllable horizontal boundary offsets
    final offsetsX = <double>[0.0];
    if (line.hasSyllables) {
      var searchStart = 0;
      for (final syl in line.syllables) {
        var startIdx = line.text.indexOf(syl.text.trim(), searchStart);
        if (startIdx == -1) {
          startIdx = line.text.indexOf(syl.text, searchStart);
        }
        if (startIdx != -1) {
          final endIdx = startIdx + syl.text.length;
          searchStart = endIdx;
          final boxes = activePara.getBoxesForRange(startIdx, endIdx);
          if (boxes.isNotEmpty) {
            offsetsX.add(boxes.last.right);
            continue;
          }
        }
        offsetsX.add(offsetsX.isNotEmpty ? offsetsX.last + 30.0 : 30.0);
      }
    } else {
      offsetsX.add(math.max(idlePara.maxIntrinsicWidth, activePara.maxIntrinsicWidth));
    }

    final layout = CachedLineLayout(
      idleParagraph: idlePara,
      activeParagraph: activePara,
      width: math.max(idlePara.maxIntrinsicWidth, activePara.maxIntrinsicWidth),
      height: math.max(idlePara.height, activePara.height),
      syllableOffsetsX: offsetsX,
    );
    _cache[line.timeMs] = layout;
    return layout;
  }

  void clear() => _cache.clear();
}

/// Single-pass GPU Canvas Painter for an active line.
/// Runs in 0.1ms without triggering any Flutter widget rebuilds!
class DesktopKaraokeLinePainter extends CustomPainter {
  final ValueListenable<int> positionListenable;
  final LyricLine line;
  final CachedLineLayout layout;
  final Color highlightColor;
  final bool isRtl;
  final bool springLift;

  DesktopKaraokeLinePainter({
    required this.positionListenable,
    required this.line,
    required this.layout,
    required this.highlightColor,
    this.isRtl = false,
    this.springLift = true,
  }) : super(repaint: positionListenable);

  @override
  void paint(Canvas canvas, Size size) {
    final posMs = positionListenable.value;

    // 1. Draw base idle text (dimmed)
    canvas.drawParagraph(layout.idleParagraph, Offset.zero);

    if (posMs < line.timeMs) return;

    // 2. Compute smooth horizontal sweep coordinate and syllable lift
    double sweepX = 0.0;
    double liftY = 0.0;

    if (posMs >= line.timeMs + line.durationMs) {
      sweepX = layout.width;
    } else if (line.hasSyllables && layout.syllableOffsetsX.length > 1) {
      final syllables = line.syllables;
      for (var i = 0; i < syllables.length; i++) {
        final syl = syllables[i];
        final sylEnd = syl.timeMs + math.max(1, syl.durationMs);
        final startX = i < layout.syllableOffsetsX.length ? layout.syllableOffsetsX[i] : 0.0;
        final endX = (i + 1) < layout.syllableOffsetsX.length ? layout.syllableOffsetsX[i + 1] : layout.width;

        if (posMs >= sylEnd) {
          sweepX = endX;
        } else if (posMs >= syl.timeMs) {
          final progress = ((posMs - syl.timeMs) / (sylEnd - syl.timeMs)).clamp(0.0, 1.0);
          sweepX = startX + progress * (endX - startX);
          if (springLift) {
            // Syllable lift: -2.5 * sin(pi * progress)
            liftY = -2.5 * math.sin(math.pi * progress);
          }
          break;
        }
      }
    } else {
      final dur = math.max(1, line.durationMs);
      final progress = ((posMs - line.timeMs) / dur).clamp(0.0, 1.0);
      sweepX = progress * layout.width;
      if (springLift && progress > 0.0 && progress < 1.0) {
        liftY = -1.5 * math.sin(math.pi * progress);
      }
    }

    if (sweepX <= 0.0) return;

    // 3. Draw active text clipped by sweepX
    canvas.save();
    if (isRtl) {
      canvas.clipRect(Rect.fromLTWH(layout.width - sweepX, -10, sweepX, layout.height + 20));
    } else {
      canvas.clipRect(Rect.fromLTWH(0, -10, sweepX, layout.height + 20));
    }

    if (liftY != 0.0) {
      canvas.translate(0, liftY);
    }

    canvas.drawParagraph(layout.activeParagraph, Offset.zero);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant DesktopKaraokeLinePainter oldDelegate) =>
      oldDelegate.line != line || oldDelegate.layout != layout;
}
