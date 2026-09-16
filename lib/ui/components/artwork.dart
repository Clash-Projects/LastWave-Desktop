import 'package:cached_network_image/cached_network_image.dart';
import 'package:fluent_ui/fluent_ui.dart';

import '../../core/artwork/artwork_resolver.dart';
import '../../core/artwork/official_artwork_service.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

export '../../core/artwork/artwork_resolver.dart' show ArtworkKind;

/// Canonical artwork primitive — pure image, no dashboard borders.
///
/// All artwork flows through [ArtworkResolver]: URL normalization, per-
/// context resolution (rows ≈96px, grids ≈300px, Now Playing ≈640px),
/// memory + disk caching, in-flight dedup, single timed retry, and a
/// fallback chain (primary → [fallbackUrls] → generated tonal visual).
/// Rapid track switches carry a generation counter so stale requests can
/// never overwrite the current image. No stars, no generic error icons.
///
/// Official-source upgrade: when the primary URL is NOT from an official
/// store CDN (YouTube video still, Last.fm crowd photo, …) and the widget
/// carries title/artist metadata, the official cover/photo is resolved in
/// the background (iTunes store covers for tracks/albums, Deezer press
/// photos for artists) and hot-swapped in — the original image keeps
/// showing until then and remains as fallback.
class WaveArtwork extends StatefulWidget {
  final String url;
  final String videoId;
  final List<String> fallbackUrls;
  final double size;
  final double radius;
  final bool isCircle;
  final String label;
  final String title;
  final String artist;

  /// Optional content hint: [ArtworkKind.album] resolves via the album
  /// catalog (exact collection match), [ArtworkKind.artist] via artist
  /// photos. Defaults to artist when [isCircle], else track.
  final ArtworkKind? kind;

  const WaveArtwork({
    super.key,
    required this.url,
    this.videoId = '',
    this.fallbackUrls = const [],
    required this.size,
    this.radius = WaveRadius.artwork,
    this.isCircle = false,
    this.label = '',
    this.title = '',
    this.artist = '',
    this.kind,
  });

  const WaveArtwork.circle({
    super.key,
    required this.url,
    this.videoId = '',
    this.fallbackUrls = const [],
    required this.size,
    this.label = '',
    this.title = '',
    this.artist = '',
  })  : radius = 999,
        isCircle = true,
        kind = ArtworkKind.artist;

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
  String? _resolvedUrl;
  bool _isResolving = false;
  bool _upgradeAttempted = false;
  bool _resolveFailed = false;

  /// Effective content kind: explicit hint, else circle ⇒ artist.
  ArtworkKind get _kind =>
      widget.kind ??
      (widget.isCircle ? ArtworkKind.artist : ArtworkKind.track);

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
    OfficialArtworkService.instance.addListener(_onArtworkCache);
  }

  @override
  void dispose() {
    OfficialArtworkService.instance.removeListener(_onArtworkCache);
    super.dispose();
  }

  /// Playback / another tile found a studio cover — swap this one too.
  void _onArtworkCache() {
    if (!mounted) return;
    if (_kind == ArtworkKind.artist) return;
    final title = widget.title.isNotEmpty ? widget.title : widget.label;
    final artist = widget.artist;
    if (title.isEmpty) return;
    final hit = OfficialArtworkService.instance.peekTrack(
      title: title,
      artist: artist,
    );
    if (hit == null || hit.artworkUrl.isEmpty) return;
    if (_resolvedUrl == hit.artworkUrl) return;
    setState(() {
      _resolvedUrl = hit.artworkUrl;
      _resolveFailed = false;
      _isResolving = false;
      final target =
          (widget.size * _lastDpr).clamp(64, 1024).toDouble();
      _chain = ArtworkResolver.resolve(
        ArtworkRequest(
          kind: _kind,
          candidates: [
            hit.artworkUrl,
            widget.url,
            ...widget.fallbackUrls,
          ],
          label: widget.label,
          targetPx: target,
          videoId: widget.videoId,
        ),
      ).urls;
      _chainIndex = 0;
      _attempt = 0;
    });
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
        old.title != widget.title ||
        old.artist != widget.artist ||
        old.videoId != widget.videoId ||
        !_fallbacksEqual(old.fallbackUrls, widget.fallbackUrls) ||
        old.size != widget.size ||
        old.label != widget.label) {
      if (old.url != widget.url ||
          old.title != widget.title ||
          old.artist != widget.artist) {
        _resolvedUrl = null;
        _isResolving = false;
        _upgradeAttempted = false;
        _resolveFailed = false;
      }
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
    final candidates = [
      widget.url,
      ...widget.fallbackUrls,
      ?_resolvedUrl,
    ];
    final req = ArtworkRequest(
      kind: _kind,
      candidates: candidates,
      label: widget.label,
      targetPx: target,
      videoId: widget.videoId,
    );
    _chain = ArtworkResolver.resolve(req).urls;

    _maybeUpgradeOfficial();
  }

  /// Proactive official-source upgrade: when the primary image is NOT
  /// from an official store CDN (YouTube video still, Last.fm crowd
  /// photo, …) resolve the official cover/photo in the background and
  /// hot-swap it in. The current image keeps showing until then and
  /// stays in the chain as fallback if the official source has no match.
  void _maybeUpgradeOfficial() {
    if (_upgradeAttempted || _resolveFailed || _isResolving) return;
    if (_resolvedUrl != null) return;
    final title = widget.title.isNotEmpty ? widget.title : widget.label;
    final artist = widget.artist;
    // Per-kind metadata requirements — a bare label (e.g. a playlist
    // name) must never trigger a store search that could swap in an
    // unrelated "official" cover.
    switch (_kind) {
      case ArtworkKind.track:
        if (title.isEmpty || artist.isEmpty) return;
      case ArtworkKind.album:
        if (title.isEmpty) return;
      case ArtworkKind.artist:
        if (artist.isEmpty && title.isEmpty) return;
    }
    // Album/track: skip if we already have a store sleeve.
    // Artist circles: skip only if we already have a Deezer *artist*
    // press photo — an iTunes album cover is official, but it is the
    // wrong kind of image for an artist tile.
    if (_kind == ArtworkKind.artist) {
      if (OfficialArtworkService.isOfficialArtistPhoto(widget.url)) {
        return;
      }
    } else if (OfficialArtworkService.isOfficialArtwork(widget.url)) {
      return;
    }
    _upgradeAttempted = true;
    _checkAndResolveArtwork();
  }

  void _checkAndResolveArtwork() {
    if (_isResolving || _resolveFailed) return;
    final title = widget.title.isNotEmpty ? widget.title : widget.label;
    final artist = widget.artist;
    if (title.isEmpty && artist.isEmpty) return;

    _isResolving = true;
    final service = OfficialArtworkService.instance;
    // Route by content kind: artist circles → Deezer press photos,
    // albums → iTunes album catalog, tracks → iTunes song catalog.
    final Future<OfficialArtworkResult?> task = switch (_kind) {
      ArtworkKind.artist => service
          .resolveArtistArtwork(artist.isNotEmpty ? artist : title),
      ArtworkKind.album =>
        service.resolveAlbumArtwork(album: title, artist: artist),
      ArtworkKind.track =>
        service.resolveOfficialArtwork(title: title, artist: artist),
    };
    task.then((res) {
      if (!mounted) return;
      _isResolving = false;
      if (res != null && res.artworkUrl.isNotEmpty) {
        final usable = _kind == ArtworkKind.artist
            ? OfficialArtworkService.isOfficialArtistPhoto(res.artworkUrl)
            : OfficialArtworkService.isOfficialArtwork(res.artworkUrl);
        if (!usable) {
          _resolveFailed = true;
          return;
        }
        if (res.artworkUrl == _resolvedUrl) return;
        setState(() {
          _resolvedUrl = res.artworkUrl;
          final target =
              (widget.size * _lastDpr).clamp(64, 1024).toDouble();
          // Official URL leads; previous candidates stay as fallbacks.
          final req = ArtworkRequest(
            kind: _kind,
            candidates: [
              res.artworkUrl,
              widget.url,
              ...widget.fallbackUrls,
            ],
            label: widget.label,
            targetPx: target,
            videoId: widget.videoId,
          );
          _chain = ArtworkResolver.resolve(req).urls;
          _chainIndex = 0;
          _attempt = 0;
        });
      } else {
        _resolveFailed = true;
      }
    }).catchError((_) {
      if (mounted) {
        _isResolving = false;
        _resolveFailed = true;
      }
    });
  }

  String get _initials {
    final text = widget.label.isNotEmpty
        ? widget.label
        : (widget.title.isNotEmpty ? widget.title : widget.artist);
    final parts = text
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
    return AnimatedContainer(
      duration: WaveMotion.normal,
      curve: WaveMotion.standard,
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
    } else if (!_isResolving && _resolvedUrl == null) {
      _checkAndResolveArtwork();
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
      return AnimatedContainer(
        duration: WaveMotion.normal,
        curve: WaveMotion.standard,
        width: widget.size,
        height: widget.size,
        child: ClipOval(child: image),
      );
    }
    return AnimatedContainer(
      duration: WaveMotion.normal,
      curve: WaveMotion.standard,
      width: widget.size,
      height: widget.size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.radius),
        child: image,
      ),
    );
  }
}
