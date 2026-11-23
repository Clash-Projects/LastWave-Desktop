import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:window_manager/window_manager.dart';

/// Interactive edge and corner resize overlay for frameless desktop windows (Linux/X11/Wayland).
///
/// On Linux with `TitleBarStyle.hidden`, the OS removes the native window border / CSD.
/// This widget overlays 4 edges (8px) and 4 corners (16px) with proper system cursors
/// and initiates native window resizing via [windowManager.startResizing] immediately on
/// pointer down or pan.
class WaveWindowResizeArea extends StatelessWidget {
  final Widget child;
  final bool enabled;
  final double edgeSize;
  final double cornerSize;

  const WaveWindowResizeArea({
    super.key,
    required this.child,
    this.enabled = true,
    this.edgeSize = 8.0,
    this.cornerSize = 16.0,
  });

  Widget _buildHandle({
    required ResizeEdge edge,
    required MouseCursor cursor,
    double? width,
    double? height,
  }) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        if (event.buttons == kPrimaryMouseButton) {
          windowManager.startResizing(edge);
        }
      },
      child: MouseRegion(
        cursor: cursor,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onPanStart: (_) => windowManager.startResizing(edge),
          onDoubleTap: () {
            if (Platform.isWindows &&
                (edge == ResizeEdge.top || edge == ResizeEdge.bottom)) {
              windowManager.maximize(vertically: true);
            }
          },
          child: Container(
            width: width,
            height: height,
            color: const Color(0x00000000),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;

    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        // Corners: 16x16 px for easy targeting
        // Top Left
        Positioned(
          top: 0,
          left: 0,
          width: cornerSize,
          height: cornerSize,
          child: _buildHandle(
            edge: ResizeEdge.topLeft,
            cursor: SystemMouseCursors.resizeUpLeft,
          ),
        ),
        // Top Right
        Positioned(
          top: 0,
          right: 0,
          width: cornerSize,
          height: cornerSize,
          child: _buildHandle(
            edge: ResizeEdge.topRight,
            cursor: SystemMouseCursors.resizeUpRight,
          ),
        ),
        // Bottom Left
        Positioned(
          bottom: 0,
          left: 0,
          width: cornerSize,
          height: cornerSize,
          child: _buildHandle(
            edge: ResizeEdge.bottomLeft,
            cursor: SystemMouseCursors.resizeDownLeft,
          ),
        ),
        // Bottom Right
        Positioned(
          bottom: 0,
          right: 0,
          width: cornerSize,
          height: cornerSize,
          child: _buildHandle(
            edge: ResizeEdge.bottomRight,
            cursor: SystemMouseCursors.resizeDownRight,
          ),
        ),
        // Edges: 8px thickness, spanning between corners
        // Top
        Positioned(
          top: 0,
          left: cornerSize,
          right: cornerSize,
          height: edgeSize,
          child: _buildHandle(
            edge: ResizeEdge.top,
            cursor: SystemMouseCursors.resizeUp,
          ),
        ),
        // Bottom
        Positioned(
          bottom: 0,
          left: cornerSize,
          right: cornerSize,
          height: edgeSize,
          child: _buildHandle(
            edge: ResizeEdge.bottom,
            cursor: SystemMouseCursors.resizeDown,
          ),
        ),
        // Left
        Positioned(
          top: cornerSize,
          bottom: cornerSize,
          left: 0,
          width: edgeSize,
          child: _buildHandle(
            edge: ResizeEdge.left,
            cursor: SystemMouseCursors.resizeLeft,
          ),
        ),
        // Right
        Positioned(
          top: cornerSize,
          bottom: cornerSize,
          right: 0,
          width: edgeSize,
          child: _buildHandle(
            edge: ResizeEdge.right,
            cursor: SystemMouseCursors.resizeRight,
          ),
        ),
      ],
    );
  }
}
