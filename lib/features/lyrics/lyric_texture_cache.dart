import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';

import 'lyrics_models.dart';

class BakedWordBox {
  final int startMs;
  final int endMs;
  final double x0; // Logical px from line left
  final double x1; // Logical px from line left
  final int rowIndex; // 0, 1, 2... for wrapped lines

  const BakedWordBox({
    required this.startMs,
    required this.endMs,
    required this.x0,
    required this.x1,
    required this.rowIndex,
  });
}

class BakedLyricLine {
  final int lineIndex;
  final Size logicalSize;
  final double rowHeight;
  final double dpr;
  final double blurPad;
  final ui.Image activeSharpImage; // Pure sharp active text (for shader)
  final ui.Image inactiveBlurredImage; // Dimmed + pre-blurred text (0 live blur!)
  final List<BakedWordBox> words;

  const BakedLyricLine({
    required this.lineIndex,
    required this.logicalSize,
    required this.rowHeight,
    required this.dpr,
    this.blurPad = 0.0,
    required this.activeSharpImage,
    required this.inactiveBlurredImage,
    required this.words,
  });

  void disposeDeferred() {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      try {
        activeSharpImage.dispose();
      } catch (_) {}
      try {
        inactiveBlurredImage.dispose();
      } catch (_) {}
    });
  }
}

class LyricTextureCache {
  final Map<int, BakedLyricLine> _cache = {};
  final Set<int> _inFlight = {};
  double _lastWidth = 0.0;
  double _lastDpr = 1.0;
  String _lastFont = '';
  double _lastBlurSigma = 0.0;

  int get length => _cache.length;

  BakedLyricLine? operator [](int lineIndex) => _cache[lineIndex];
  BakedLyricLine? get(int lineIndex) => _cache[lineIndex];

  bool needsInvalidation({
    required double width,
    required double dpr,
    required String font,
    required double blurSigma,
  }) {
    if ((_lastWidth - width).abs() > 1.0) return true;
    if ((_lastDpr - dpr).abs() > 0.01) return true;
    if (_lastFont != font) return true;
    if ((_lastBlurSigma - blurSigma).abs() > 0.1) return true;
    return false;
  }

  void invalidate() {
    for (final entry in _cache.values) {
      entry.disposeDeferred();
    }
    _cache.clear();
    _inFlight.clear();
  }

  void dispose() {
    invalidate();
  }

  /// Evicts entries outside [activeIndex - 6 .. activeIndex + 8].
  void evictOutside(int activeIndex) {
    final minKeep = activeIndex - 6;
    final maxKeep = activeIndex + 8;
    final toRemove = <int>[];

    for (final key in _cache.keys) {
      if (key < minKeep || key > maxKeep) {
        toRemove.add(key);
      }
    }

    for (final key in toRemove) {
      final entry = _cache.remove(key);
      entry?.disposeDeferred();
    }
  }

  /// Synchronously or asynchronously bakes a line and stores it in cache.
  Future<BakedLyricLine?> bakeLine({
    required int lineIndex,
    required LyricLine line,
    required double maxWidth,
    required double dpr,
    required TextStyle activeStyle,
    required TextStyle inactiveStyle,
    double blurSigma = 0.0,
  }) async {
    if (_cache.containsKey(lineIndex)) {
      return _cache[lineIndex];
    }
    if (_inFlight.contains(lineIndex)) {
      return null;
    }
    _inFlight.add(lineIndex);

    try {
      final effectiveDpr = dpr.clamp(1.0, 2.0);
      final isRtl = line.isRtl;

      final pStyle = activeStyle.getParagraphStyle(
        textAlign: isRtl ? TextAlign.right : TextAlign.left,
        textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
      );
      final idlePStyle = inactiveStyle.getParagraphStyle(
        textAlign: isRtl ? TextAlign.right : TextAlign.left,
        textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
      );

      // 1. Build and layout active paragraph
      final activeBuilder = ui.ParagraphBuilder(pStyle)
        ..pushStyle(activeStyle.getTextStyle())
        ..addText(line.text);
      final activePara = activeBuilder.build()
        ..layout(ui.ParagraphConstraints(width: maxWidth));

      // 2. Build and layout inactive paragraph
      final idleBuilder = ui.ParagraphBuilder(idlePStyle)
        ..pushStyle(inactiveStyle.getTextStyle())
        ..addText(line.text);
      final idlePara = idleBuilder.build()
        ..layout(ui.ParagraphConstraints(width: maxWidth));

      final logicalW = math.max(10.0, math.max(activePara.maxIntrinsicWidth, idlePara.maxIntrinsicWidth));
      final logicalH = math.max(10.0, math.max(activePara.height, idlePara.height));
      final logicalSize = Size(logicalW, logicalH);

      final rowHeight = math.max(
        12.0,
        activeStyle.fontSize != null
            ? activeStyle.fontSize! * (activeStyle.height ?? 1.35)
            : 36.0 * 1.35,
      );

      // 3. Extract syllable / word boxes
      final wordBoxes = <BakedWordBox>[];
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
              final box = boxes.first;
              final rIdx = (box.top / math.max(1.0, rowHeight)).floor();
              wordBoxes.add(BakedWordBox(
                startMs: syl.timeMs,
                endMs: syl.timeMs + syl.durationMs,
                x0: box.left,
                x1: box.right,
                rowIndex: rIdx,
              ));
              continue;
            }
          }
          final lastX = wordBoxes.isNotEmpty ? wordBoxes.last.x1 : 0.0;
          wordBoxes.add(BakedWordBox(
            startMs: syl.timeMs,
            endMs: syl.timeMs + syl.durationMs,
            x0: lastX,
            x1: lastX + 30.0,
            rowIndex: 0,
          ));
        }
      } else {
        wordBoxes.add(BakedWordBox(
          startMs: line.timeMs,
          endMs: line.timeMs + math.max(1, line.durationMs),
          x0: 0.0,
          x1: logicalW,
          rowIndex: 0,
        ));
      }

      // 4. Bake activeSharpImage
      final physW = (logicalW * effectiveDpr).ceil().clamp(1, 4096);
      final physH = (logicalH * effectiveDpr).ceil().clamp(1, 2048);

      final sharpRecorder = ui.PictureRecorder();
      final sharpCanvas = Canvas(sharpRecorder);
      sharpCanvas.scale(effectiveDpr);
      sharpCanvas.drawParagraph(activePara, Offset.zero);
      final activeSharpImg = await sharpRecorder.endRecording().toImage(physW, physH);

      // 5. Bake inactiveBlurredImage with padding
      final double blurPad = blurSigma > 0.05 ? (blurSigma * 3.0).ceilToDouble() : 0.0;
      final blurPhysW = ((logicalW + blurPad * 2) * effectiveDpr).ceil().clamp(1, 4096);
      final blurPhysH = ((logicalH + blurPad * 2) * effectiveDpr).ceil().clamp(1, 2048);

      final blurRecorder = ui.PictureRecorder();
      final blurCanvas = Canvas(blurRecorder);
      blurCanvas.scale(effectiveDpr);
      if (blurSigma > 0.05) {
        blurCanvas.saveLayer(
          null,
          Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        );
        blurCanvas.drawParagraph(idlePara, Offset(blurPad, blurPad));
        blurCanvas.restore();
      } else {
        blurCanvas.drawParagraph(idlePara, Offset.zero);
      }
      final inactiveBlurredImg = await blurRecorder.endRecording().toImage(blurPhysW, blurPhysH);

      final baked = BakedLyricLine(
        lineIndex: lineIndex,
        logicalSize: logicalSize,
        rowHeight: rowHeight,
        dpr: effectiveDpr,
        blurPad: blurPad,
        activeSharpImage: activeSharpImg,
        inactiveBlurredImage: inactiveBlurredImg,
        words: wordBoxes,
      );

      _cache[lineIndex] = baked;
      return baked;
    } finally {
      _inFlight.remove(lineIndex);
    }
  }

  /// Updates cache around activeIndex: evicts far entries and lazily bakes upcoming entries.
  Future<void> syncWindow({
    required int activeIndex,
    required List<LyricLine> lines,
    required double maxWidth,
    required double dpr,
    required TextStyle activeStyle,
    required TextStyle inactiveStyle,
    required String font,
    double blurSigma = 0.0,
  }) async {
    if (needsInvalidation(width: maxWidth, dpr: dpr, font: font, blurSigma: blurSigma)) {
      invalidate();
      _lastWidth = maxWidth;
      _lastDpr = dpr;
      _lastFont = font;
      _lastBlurSigma = blurSigma;
    }

    evictOutside(activeIndex);

    // Ensure active line and immediate neighbor are baked
    final bakeTargets = <int>[];
    for (var i = math.max(0, activeIndex - 2); i <= math.min(lines.length - 1, activeIndex + 4); i++) {
      if (!_cache.containsKey(i) && !_inFlight.contains(i)) {
        bakeTargets.add(i);
      }
    }
    // Also include forward lookahead
    final lookahead = activeIndex + 8;
    if (lookahead < lines.length && !_cache.containsKey(lookahead) && !_inFlight.contains(lookahead)) {
      bakeTargets.add(lookahead);
    }

    for (final idx in bakeTargets) {
      await bakeLine(
        lineIndex: idx,
        line: lines[idx],
        maxWidth: maxWidth,
        dpr: dpr,
        activeStyle: activeStyle,
        inactiveStyle: inactiveStyle,
        blurSigma: blurSigma,
      );
    }
  }
}
