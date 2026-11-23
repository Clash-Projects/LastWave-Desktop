import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'lyric_clock_controller.dart';
import 'lyric_texture_cache.dart';

/// Shader-accelerated zero-rebuild karaoke sweep layer.
///
/// Draws the active singing line in ONE GPU draw call via `shaders/karaoke_sweep.frag`.
/// Wrapped in its own RepaintBoundary to isolate repaints completely from inactive lines.
class ActiveLyricSweepWidget extends StatefulWidget {
  final BakedLyricLine baked;
  final ValueListenable<SweepState> sweepStateListenable;
  final ui.FragmentShader? shader;
  final double dpr;
  final Alignment alignment;
  final bool isRtl;
  final double fadeBandHeight;
  final double viewportHeight;

  const ActiveLyricSweepWidget({
    super.key,
    required this.baked,
    required this.sweepStateListenable,
    this.shader,
    required this.dpr,
    this.alignment = Alignment.centerLeft,
    this.isRtl = false,
    this.fadeBandHeight = 80.0,
    this.viewportHeight = 600.0,
  });

  @override
  State<ActiveLyricSweepWidget> createState() => _ActiveLyricSweepWidgetState();
}

class _ActiveLyricSweepWidgetState extends State<ActiveLyricSweepWidget> {
  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        size: widget.baked.logicalSize,
        painter: _ActiveLyricSweepPainter(
          baked: widget.baked,
          sweepStateListenable: widget.sweepStateListenable,
          shader: widget.shader,
          dpr: widget.dpr,
          isRtl: widget.isRtl,
          fadeBandHeight: widget.fadeBandHeight,
          viewportHeight: widget.viewportHeight,
          getContext: () => context,
        ),
      ),
    );
  }
}

class _ActiveLyricSweepPainter extends CustomPainter {
  final BakedLyricLine baked;
  final ValueListenable<SweepState> sweepStateListenable;
  final ui.FragmentShader? shader;
  final double dpr;
  final bool isRtl;
  final double fadeBandHeight;
  final double viewportHeight;
  final BuildContext Function() getContext;

  _ActiveLyricSweepPainter({
    required this.baked,
    required this.sweepStateListenable,
    required this.shader,
    required this.dpr,
    required this.isRtl,
    required this.fadeBandHeight,
    required this.viewportHeight,
    required this.getContext,
  }) : super(repaint: sweepStateListenable);

  @override
  void paint(Canvas canvas, Size size) {
    final sweepState = sweepStateListenable.value;
    final sweepX = sweepState.sweepXLogical;
    final activeRow = sweepState.activeRowIndex;
    final liftY = sweepState.liftY;

    final s = shader;
    if (s != null) {
      Offset globalOffset = Offset.zero;
      try {
        final box = getContext().findRenderObject() as RenderBox?;
        if (box != null && box.hasSize) {
          globalOffset = box.localToGlobal(Offset.zero);
        }
      } catch (_) {}

      final originX = globalOffset.dx;
      final originY = globalOffset.dy + liftY;

      // Compute edge fade (0.0..1.0) in Dart
      final double distTop = originY.clamp(0.0, fadeBandHeight);
      final double distBottom =
          (viewportHeight - (originY + baked.logicalSize.height)).clamp(
            0.0,
            fadeBandHeight,
          );
      final double edgeFade = (math.min(distTop, distBottom) / fadeBandHeight)
          .clamp(0.0, 1.0);

      // Uniform float mapping (all spatial values multiplied by dpr):
      // 0, 1 : uOrigin
      // 2, 3 : uSize
      // 4    : uSweepX
      // 5    : uActiveRow
      // 6    : uRowHeight
      // 7    : uFeather (24.0 * dpr)
      // 8    : uDimAlpha (0.35)
      // 9    : uEdgeFade
      s
        ..setFloat(0, originX * dpr)
        ..setFloat(1, originY * dpr)
        ..setFloat(2, baked.logicalSize.width * dpr)
        ..setFloat(3, baked.logicalSize.height * dpr)
        ..setFloat(4, (isRtl ? (baked.logicalSize.width - sweepX) : sweepX) * dpr)
        ..setFloat(5, activeRow.toDouble())
        ..setFloat(6, baked.rowHeight * dpr)
        ..setFloat(7, 24.0 * dpr)
        ..setFloat(8, 0.35)
        ..setFloat(9, edgeFade)
        ..setImageSampler(0, baked.activeSharpImage);

      final paint = Paint()..shader = s;
      final drawRect = Rect.fromLTWH(
        0,
        liftY,
        baked.logicalSize.width,
        baked.logicalSize.height,
      );
      canvas.drawRect(drawRect, paint);
    } else {
      // Fallback: draw pre-baked activeSharpImage with canvas clip
      // 1. Draw base inactive blurred image
      final pad = baked.blurPad;
      canvas.drawImage(
        baked.inactiveBlurredImage,
        Offset(-pad, -pad),
        Paint(),
      );

      if (sweepX > 0.0) {
        canvas.save();
        if (isRtl) {
          canvas.clipRect(
            Rect.fromLTWH(
              baked.logicalSize.width - sweepX,
              -10 + liftY,
              sweepX,
              baked.logicalSize.height + 20,
            ),
          );
        } else {
          canvas.clipRect(
            Rect.fromLTWH(
              0,
              -10 + liftY,
              sweepX,
              baked.logicalSize.height + 20,
            ),
          );
        }
        canvas.drawImage(
          baked.activeSharpImage,
          Offset(0, liftY),
          Paint(),
        );
        canvas.restore();
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ActiveLyricSweepPainter oldDelegate) =>
      oldDelegate.baked != baked ||
      oldDelegate.shader != shader ||
      oldDelegate.dpr != dpr;
}
