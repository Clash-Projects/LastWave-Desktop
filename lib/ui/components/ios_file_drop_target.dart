import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Native iPadOS file-drop surface.
///
/// The transparent UIKit view only participates in UIDropInteraction. Normal
/// taps, scrolling, and Flutter gestures continue to be handled by [child].
class IosFileDropTarget extends StatefulWidget {
  const IosFileDropTarget({
    super.key,
    required this.child,
    required this.onFilesDropped,
    required this.onDragStateChanged,
  });

  final Widget child;
  final Future<void> Function(List<String> paths) onFilesDropped;
  final ValueChanged<bool> onDragStateChanged;

  @override
  State<IosFileDropTarget> createState() => _IosFileDropTargetState();
}

class _IosFileDropTargetState extends State<IosFileDropTarget> {
  MethodChannel? _channel;

  void _onPlatformViewCreated(int viewId) {
    final channel = MethodChannel('com.lastwave/file-drop/$viewId');
    _channel = channel;
    channel.setMethodCallHandler((call) async {
      if (!mounted) return;
      switch (call.method) {
        case 'dragEntered':
          widget.onDragStateChanged(true);
          return;
        case 'dragExited':
          widget.onDragStateChanged(false);
          return;
        case 'filesDropped':
          widget.onDragStateChanged(false);
          final raw = call.arguments;
          final paths = raw is List
              ? raw.whereType<String>().where((path) => path.isNotEmpty).toList()
              : <String>[];
          if (paths.isNotEmpty) {
            await widget.onFilesDropped(paths);
          }
          return;
        default:
          throw PlatformException(
            code: 'unimplemented_drop_event',
            message: 'Unknown LastWave iPadOS drop event: ${call.method}',
          );
      }
    });
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    _channel = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isIOS) return widget.child;

    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: UiKitView(
              viewType: 'com.lastwave/file-drop',
              onPlatformViewCreated: _onPlatformViewCreated,
              creationParams: const <String, Object>{},
              creationParamsCodec: const StandardMessageCodec(),
            ),
          ),
        ),
      ],
    );
  }
}
