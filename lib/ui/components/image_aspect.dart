import 'dart:async';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';

/// Measures a remote cover once and reports whether it is wide (16:9) or
/// square (1:1), so podcast art keeps its own shape instead of being forced
/// into one box.
class ImageAspect {
  ImageAspect._();

  static final Map<String, double> _cache = {};

  /// 16:9 for landscape art, 1.0 for square/portrait art.
  static const double wide = 16 / 9;

  /// Cached answer, or null while unknown.
  static double? peek(String url) => _cache[url];

  static Future<double> resolve(String url) {
    final known = _cache[url];
    if (known != null) return Future.value(known);
    if (url.isEmpty) return Future.value(wide);
    final provider = CachedNetworkImageProvider(url, maxWidth: 160);
    final completer = Completer<double>();
    final stream = provider.resolve(const ImageConfiguration());
    late final ImageStreamListener listener;
    listener = ImageStreamListener((info, _) {
      final ui.Image img = info.image;
      final ratio = img.height == 0 ? 1.0 : img.width / img.height;
      final result = ratio > 1.4 ? wide : 1.0;
      _cache[url] = result;
      if (!completer.isCompleted) completer.complete(result);
      stream.removeListener(listener);
    }, onError: (Object _, StackTrace? stack) {
      if (!completer.isCompleted) completer.complete(wide);
      stream.removeListener(listener);
    });
    stream.addListener(listener);
    return completer.future.timeout(
      const Duration(seconds: 8),
      onTimeout: () => wide,
    );
  }
}

/// Builds [builder] with the cover's aspect (16:9 until measured).
class ImageAspectBuilder extends StatefulWidget {
  final String url;
  final Widget Function(BuildContext context, double aspect) builder;
  const ImageAspectBuilder({
    super.key,
    required this.url,
    required this.builder,
  });

  @override
  State<ImageAspectBuilder> createState() => _ImageAspectBuilderState();
}

class _ImageAspectBuilderState extends State<ImageAspectBuilder> {
  double _aspect = ImageAspect.wide;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  @override
  void didUpdateWidget(covariant ImageAspectBuilder old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) _measure();
  }

  void _measure() {
    final url = widget.url;
    final known = ImageAspect.peek(url);
    if (known != null) {
      _aspect = known;
      return;
    }
    _aspect = ImageAspect.wide;
    ImageAspect.resolve(url).then((a) {
      if (mounted && widget.url == url && a != _aspect) {
        setState(() => _aspect = a);
      }
    });
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _aspect);
}
