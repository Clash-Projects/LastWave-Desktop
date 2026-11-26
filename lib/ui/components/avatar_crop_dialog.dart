import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../theme/tokens.dart';
import 'buttons.dart';

/// Opens an interactive circular avatar cropper for [imageBytes].
///
/// Users can drag to reposition and zoom (scroll wheel / pinch / slider),
/// then save a 560x560 PNG into `<appSupport>/profile_avatar_<ts>.png`.
/// Returns the saved file path, or `null` if cancelled or unreadable.
Future<String?> showAvatarCropDialog(
  BuildContext context,
  Uint8List imageBytes,
) async {
  return showDialog<String>(
    context: context,
    builder: (_) => _AvatarCropDialog(imageBytes: imageBytes),
  );
}

class _AvatarCropDialog extends StatefulWidget {
  final Uint8List imageBytes;
  const _AvatarCropDialog({required this.imageBytes});

  @override
  State<_AvatarCropDialog> createState() => _AvatarCropDialogState();
}

class _AvatarCropDialogState extends State<_AvatarCropDialog> {
  static const double _viewportSize = 280.0;
  final GlobalKey _cropKey = GlobalKey();
  final TransformationController _transform = TransformationController();
  double _zoom = 1.0;
  bool _saving = false;

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _setZoom(double nextZoom) {
    final clamped = nextZoom.clamp(1.0, 5.0);
    final prevScale = _transform.value.getMaxScaleOnAxis();
    if (prevScale <= 0) return;
    final ratio = clamped / prevScale;
    final center = const Offset(_viewportSize / 2, _viewportSize / 2);
    final next = Matrix4.identity()
      ..translateByDouble(center.dx, center.dy, 0, 1)
      ..scaleByDouble(ratio, ratio, 1, 1)
      ..translateByDouble(-center.dx, -center.dy, 0, 1)
      ..multiply(_transform.value);
    _transform.value = next;
    setState(() => _zoom = clamped);
  }

  void _reset() {
    _transform.value = Matrix4.identity();
    setState(() => _zoom = 1.0);
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final boundary =
          _cropKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) {
        if (mounted) Navigator.of(context).pop();
        return;
      }
      final image = await boundary.toImage(pixelRatio: 2.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (byteData == null) {
        if (mounted) Navigator.of(context).pop();
        return;
      }

      final support = await getApplicationSupportDirectory();
      try {
        for (final entity in support.listSync()) {
          if (entity is File &&
              p.basename(entity.path).startsWith('profile_avatar_') &&
              entity.path.endsWith('.png')) {
            try {
              entity.deleteSync();
            } catch (_) {}
          }
        }
      } catch (_) {}

      final outFile = File(
        p.join(
          support.path,
          'profile_avatar_${DateTime.now().millisecondsSinceEpoch}.png',
        ),
      );
      await outFile.writeAsBytes(
        byteData.buffer.asUint8List(),
        flush: true,
      );
      if (mounted) Navigator.of(context).pop(outFile.path);
    } catch (_) {
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    return ContentDialog(
      constraints: const BoxConstraints(maxWidth: 360),
      title: const Text('Crop profile picture'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipOval(
            child: SizedBox(
              width: _viewportSize,
              height: _viewportSize,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  RepaintBoundary(
                    key: _cropKey,
                    child: Container(
                      color: dark ? const Color(0xFF141418) : const Color(0xFFEAEAEF),
                      child: InteractiveViewer(
                        transformationController: _transform,
                        minScale: 1.0,
                        maxScale: 5.0,
                        boundaryMargin: const EdgeInsets.all(_viewportSize * 0.6),
                        onInteractionUpdate: (_) {
                          final s = _transform.value
                              .getMaxScaleOnAxis()
                              .clamp(1.0, 5.0);
                          if ((s - _zoom).abs() > 0.02) {
                            setState(() => _zoom = s);
                          }
                        },
                        child: Image.memory(
                          widget.imageBytes,
                          width: _viewportSize,
                          height: _viewportSize,
                          fit: BoxFit.contain,
                          errorBuilder: (_, _, _) => Center(
                            child: Text(
                              'Could not load image',
                              style: WaveType.meta,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.45),
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              const Icon(FluentIcons.remove, size: 13),
              Expanded(
                child: Slider(
                  min: 1.0,
                  max: 5.0,
                  value: _zoom,
                  onChanged: _setZoom,
                ),
              ),
              const Icon(FluentIcons.add, size: 13),
              const SizedBox(width: 8),
              WaveButton(
                onPressed: _saving ? null : _reset,
                child: const Text('Reset'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Drag to position · scroll or slide to zoom',
            style: WaveType.meta.copyWith(color: waveTextSecondary(context)),
          ),
        ],
      ),
      actions: [
        WaveButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        WaveFilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Saving…' : 'Save'),
        ),
      ],
    );
  }
}
