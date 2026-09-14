import 'package:cached_network_image/cached_network_image.dart';
import 'package:fluent_ui/fluent_ui.dart';

import '../../core/artwork/artwork_resolver.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

/// Canonical artwork primitive — pure image, no dashboard borders.
///
/// All artwork flows through [ArtworkResolver]: URL normalization, per-
/// context resolution (rows ≈96px, grids ≈300px, Now Playing ≈640px),
/// memory + disk caching, in-flight dedup, single timed retry, and a
/// fallback chain (primary → [fallbackUrls] → generated tonal visual).
/// Rapid track switches carry a generation counter so stale requests can
/// never overwrite the current image. No stars, no generic error icons.
class WaveArtwork extends StatefulWidget {
  final String url;
  final String videoId;
  final List<String> fallbackUrls;
  final double size;
  final double radius;
  final bool isCircle;
  final String label;
  const WaveArtwork({
    super.key,
    required this.url,
    this.videoId = '',
    this.fallbackUrls = const [],
    required this.size,
    this.radius = WaveRadius.artwork,
    this.isCircle = false,
    this.label = '',
  });

  const WaveArtwork.circle({
    super.key,
    required this.url,
    this.videoId = '',
    this.fallbackUrls = const [],
    required this.size,
    this.label = '',
  })  : radius = 999,
        isCircle = true;

  @override
  State<WaveArtwork> createState() => _WaveArtworkState();
}

class _WaveArtworkState extends State<WaveArtwork> {
  int _gen = 0;
  int _attempt = 0;
  int _chainIndex = 0;
  List<String> _chain = const [];
  double _lastDpr = 1.0;
  String? _handledError;

  bool _fallbacksEqual(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  void initState() {
    super.initState();
    // DPR unavailable in initState — chain built in didChangeDependencies
    // with the live pixel ratio so hidpi picks the right rendition.
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    if (_chain.isEmpty || (dpr - _lastDpr).abs() > 0.01) {
      _lastDpr = dpr;
      _rebuildChain(dpr);
    }
  }

  @override
  void didUpdateWidget(WaveArtwork old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url ||
        old.videoId != widget.videoId ||
        !_fallbacksEqual(old.fallbackUrls, widget.fallbackUrls) ||
        old.size != widget.size ||
        old.label != widget.label) {
      _rebuildChain(_lastDpr);
    }
  }

  void _rebuildChain([double? dprOverride]) {
    _gen++;
    _attempt = 0;
    _chainIndex = 0;
    _handledError = null;
    final dpr =
        dprOverride ?? MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    _lastDpr = dpr;
    final target = (widget.size * dpr).clamp(64, 1024).toDouble();
    final req = ArtworkRequest(
      kind: ArtworkKind.track,
      candidates: [widget.url, ...widget.fallbackUrls],
      label: widget.label,
      targetPx: target,
      videoId: widget.videoId,
    );
    _chain = ArtworkResolver.resolve(req).urls;
  }

  String get _initials {
    final parts = widget.label
        .trim()
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '';
    if (parts.length == 1) {
      final w = parts.first;
      return w.substring(0, w.length >= 2 ? 2 : 1).toUpperCase();
    }
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }

  Widget _fallback(BuildContext context, bool dark) {
    final initials = _initials;
    // Intentional tonal visual: label-hashed low-saturation duo-tone +
    // small LastWave mark — never a star or error icon.
    final seed = widget.label.isEmpty ? 0 : widget.label.hashCode;
    final hue = ((seed % 360).abs()).toDouble();
    final base = HSLColor.fromAHSL(
      1.0,
      hue,
      dark ? 0.22 : 0.28,
      dark ? 0.22 : 0.82,
    ).toColor();
    final deep = HSLColor.fromAHSL(
      1.0,
      (hue + 28) % 360,
      dark ? 0.26 : 0.30,
      dark ? 0.14 : 0.72,
    ).toColor();
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [base, deep],
        ),
        borderRadius:
            widget.isCircle ? null : BorderRadius.circular(widget.radius),
        shape: widget.isCircle ? BoxShape.circle : BoxShape.rectangle,
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (initials.isNotEmpty)
              Text(
                initials,
                style: WaveType.sectionTitle.copyWith(
                  fontSize: widget.size * 0.24,
                  fontWeight: FontWeight.w700,
                  color: dark
                      ? Colors.white.withValues(alpha: 0.82)
                      : Colors.black.withValues(alpha: 0.62),
                ),
              )
            else
              Icon(
                WaveIcons.music,
                size: widget.size * 0.30,
                color: dark
                    ? Colors.white.withValues(alpha: 0.55)
                    : Colors.black.withValues(alpha: 0.45),
              ),
            SizedBox(height: widget.size * 0.06),
            Container(
              width: widget.size * 0.22,
              height: 2,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(1),
                color: (dark ? Colors.white : Colors.black)
                    .withValues(alpha: 0.35),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onError(int gen, int index, int attempt) async {
    if (!mounted || gen != _gen || index != _chainIndex ||
        attempt != _attempt) {
      return;
    }
    final errorKey = '$gen|$index|$attempt';
    if (_handledError == errorKey) return;
    _handledError = errorKey;
    await ArtworkResolver.evict(_chain[index]);
    if (!mounted || gen != _gen || index != _chainIndex ||
        attempt != _attempt) {
      return;
    }
    if (_chainIndex + 1 < _chain.length) {
      setState(() => _chainIndex++);
      return;
    }
    if (_attempt == 0) {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!mounted || gen != _gen) return;
      setState(() {
        _attempt = 1;
        _chainIndex = 0;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    if (_chain.isEmpty || _chainIndex >= _chain.length) {
      return _fallback(context, dark);
    }
    final gen = _gen;
    final index = _chainIndex;
    final attempt = _attempt;
    final currentUrl = _chain[_chainIndex];
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    final pixels = (widget.size * dpr).clamp(64, 1024).toInt();
    // Rows ≈96 backing px, grids ≈300–450, Now Playing ≈640–900.
    // Disk tiers track backing pixels without 4x overfetch.
    final diskCache = pixels <= 128
        ? 256
        : pixels <= 320
            ? 512
            : 1024;
    final isSmall = widget.size <= 56;
    final image = RepaintBoundary(
      child: CachedNetworkImage(
        key: ValueKey('$currentUrl|$_attempt'),
        imageUrl: currentUrl,
        width: widget.size,
        height: widget.size,
        memCacheWidth: pixels,
        memCacheHeight: pixels,
        maxWidthDiskCache: diskCache,
        maxHeightDiskCache: diskCache,
        fit: BoxFit.cover,
        fadeInDuration: isSmall ? Duration.zero : WaveMotion.fast,
        fadeOutDuration: WaveMotion.fast,
        placeholder: (context, _) => _fallback(context, dark),
        errorWidget: (context, _, _) {
          WidgetsBinding.instance.addPostFrameCallback(
              (_) => _onError(gen, index, attempt));
          return _fallback(context, dark);
        },
      ),
    );
    if (widget.isCircle) {
      return SizedBox(
        width: widget.size,
        height: widget.size,
        child: ClipOval(child: image),
      );
    }
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.radius),
        child: image,
      ),
    );
  }
}
