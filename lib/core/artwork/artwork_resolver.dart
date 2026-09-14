import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';

/// Central artwork pipeline — the ONLY place artwork URLs are normalized,
/// sized, deduplicated, preloaded, and fallen back.
///
/// Pipeline: metadata source → model field → [ArtworkResolver] →
/// [CachedNetworkImage] → widget. Every stage is audited here:
///
/// - null / "null" / "undefined" / "N/A" / empty → rejected, never fetched.
/// - whitespace / newlines trimmed; schemeless `//host/…` → `https:`;
///   missing scheme with known host → `https://`. Query parameters are
///   NEVER stripped (CDN signatures live there; stripping expires URLs).
/// - http → https upgrade for image CDNs (ytimg, googleusercontent,
///   last.fm, deezer, spotify, apple). Plain http kept only for
///   unrecognized hosts to avoid breaking LAN servers.
/// - redirects: left to the HTTP client (CachedNetworkImage follows them).
/// - resolution: [sized] rewrites ONLY recognized size patterns
///   (googleusercontent `=wX-hY` / `/wX-hY/`, ytimg `hqdefault→mq/sd/maxres`
///   for large targets); unknown patterns return the original so we never
///   404 a hand-built URL. Small rows ≈96px, grids ≈300px, Now Playing
///   ≈640px (backing pixels, clamped).
/// - cache: memory via image cache + disk via cached_network_image.
///   Failures are NEVER permanently cached: on error we evict that URL
///   and advance the fallback chain; a single timed retry is allowed for
///   transient blips.
/// - dedup: identical in-flight preloads share one future.
/// - race: widgets carry a generation counter; rapid A→B→C→D switches can
///   never let B/C overwrite D when an older request finishes late.
/// - preload: [preload] warms current + next artwork off the critical path.
enum ArtworkKind { track, album, artist }

class ArtworkRequest {
  final ArtworkKind kind;
  final List<String> candidates;
  final String label;
  final double targetPx;
  final String videoId;
  const ArtworkRequest({
    required this.kind,
    required this.candidates,
    this.label = '',
    this.targetPx = 300,
    this.videoId = '',
  });
}

class ResolvedArtwork {
  final List<String> urls;
  final bool isFallback;
  const ResolvedArtwork(this.urls, {this.isFallback = false});
}

class ArtworkResolver {
  ArtworkResolver._();

  static const _badTokens = {
    '',
    'null',
    'undefined',
    'n/a',
    'na',
    'none',
  };

  static final Map<String, Future<void>> _inflightPreloads = {};

  /// Track hierarchy: track → album → related → generated fallback.
  static ArtworkRequest track({
    String trackArt = '',
    String albumArt = '',
    String relatedArt = '',
    String label = '',
    double targetPx = 160,
  }) =>
      ArtworkRequest(
        kind: ArtworkKind.track,
        candidates: [trackArt, albumArt, relatedArt],
        label: label,
        targetPx: targetPx,
      );

  /// Album hierarchy: album → representative track → generated.
  static ArtworkRequest album({
    String albumArt = '',
    String representativeArt = '',
    String label = '',
    double targetPx = 300,
  }) =>
      ArtworkRequest(
        kind: ArtworkKind.album,
        candidates: [albumArt, representativeArt],
        label: label,
        targetPx: targetPx,
      );

  /// Artist hierarchy: real image → associated → generated.
  /// (Collages compose at the widget layer from multiple resolved URLs.)
  static ArtworkRequest artist({
    String artistImage = '',
    String associatedArt = '',
    String label = '',
    double targetPx = 256,
  }) =>
      ArtworkRequest(
        kind: ArtworkKind.artist,
        candidates: [artistImage, associatedArt],
        label: label,
        targetPx: targetPx,
      );

  static ResolvedArtwork resolve(ArtworkRequest request) {
    final primary = <String>{};
    final fallback = <String>{};
    for (final raw in request.candidates) {
      final n = normalize(raw);
      if (n == null) continue;
      final host = Uri.parse(n).host;
      final youtube = ['ytimg.com', 'googleusercontent.com', 'ggpht.com']
          .any((domain) => host == domain || host.endsWith('.$domain'));
      final target = youtube ? primary : fallback;
      target.add(sized(n, request.targetPx));
      target.add(n);
      if (host == 'i.ytimg.com' || host.endsWith('.ytimg.com')) {
        final uri = Uri.parse(n);
        if (uri.pathSegments.length == 3) {
          final id = uri.pathSegments[1];
          if (RegExp(r'^[\w-]{11}$').hasMatch(id)) {
            target.add('https://i.ytimg.com/vi/$id/hqdefault.jpg');
          }
        }
      }
    }
    final id = request.videoId.trim();
    if (RegExp(r'^[\w-]{11}$').hasMatch(id)) {
      if (request.targetPx >= 400) {
        primary.add('https://i.ytimg.com/vi/$id/maxresdefault.jpg');
      }
      primary.add('https://i.ytimg.com/vi/$id/hqdefault.jpg');
    }
    final urls = {...primary, ...fallback}.toList();
    return ResolvedArtwork(urls, isFallback: urls.isEmpty);
  }

  /// Normalize without destroying CDN signatures. Returns null when the
  /// URL is unusable so callers advance the chain instead of fetching it.
  static String? normalize(String raw) {
    var s = raw.trim().replaceAll(RegExp(r'\s+'), '');
    if (s.isEmpty) return null;
    if (_badTokens.contains(s.toLowerCase())) return null;
    if (s.startsWith('//')) s = 'https:$s';
    Uri? uri;
    try {
      uri = Uri.parse(s);
    } catch (_) {
      return null;
    }
    if (!uri.hasScheme) {
      // Bare host/path (e.g. "i.ytimg.com/…") → https.
      try {
        uri = Uri.parse('https://$s');
      } catch (_) {
        return null;
      }
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    final host = uri.host.toLowerCase();
    if (host.isEmpty) return null;
    if (uri.scheme == 'http' && _tlsHosts.any(host.contains)) {
      uri = uri.replace(scheme: 'https');
    }
    final out = uri.toString();
    if (out.length < 12 || !out.contains('.')) return null;
    return out;
  }

  static const _tlsHosts = [
    'ytimg.com',
    'googleusercontent.com',
    'ggpht.com',
    'last.fm',
    'lastfm',
    'deezer.com',
    'dzcdn.net',
    'spotifycdn.com',
    'scdn.co',
    'mzstatic.com',
    'apple.com',
    'i.scdn.co',
  ];

  /// Pick an appropriate rendition for recognized patterns only.
  static String sized(String url, double targetPx) {
    final px = targetPx.clamp(64, 1024).round();
    // googleusercontent / ggpht: =wX-hY[-c] or /wX-hY/.
    if (url.contains('googleusercontent.com') ||
        url.contains('ggpht.com')) {
      var next = url.replaceAllMapped(
        RegExp(r'=w\d+(-h\d+)?(-c)?(-p)?'),
        (_) => '=w$px-h$px-c',
      );
      if (next == url) {
        next = url.replaceAllMapped(
          RegExp(r'/w\d+(-h\d+)?/'),
          (_) => '/w$px-h$px/',
        );
      }
      if (next != url) return next;
    }
    // YouTube thumbs: hqdefault (120px) → mq/sd/maxres by target.
    if (url.contains('ytimg.com')) {
      if (px >= 640 && url.contains('hqdefault')) {
        return url.replaceAll('hqdefault', 'maxresdefault');
      }
      if (px >= 400 && url.contains('hqdefault')) {
        return url.replaceAll('hqdefault', 'sddefault');
      }
      // Small rows stay on hqdefault; grids get mqdefault (320px).
      if (url.contains('default.jpg') || url.contains('hqdefault')) {
        if (px >= 200 && px < 400 && url.contains('hqdefault')) {
          return url.replaceAll('hqdefault', 'mqdefault');
        }
      }
    }
    return url;
  }

  /// Warm current + next artwork. Deduplicates identical in-flight work,
  /// never throws (preload is best-effort, off the critical path).
  static Future<void> preload(
      BuildContext context, Iterable<String> urls,
      {double targetPx = 300}) {
    final tasks = <Future<void>>[];
    final px = targetPx.clamp(64, 1024).round();
    for (final raw in urls) {
      final n = normalize(raw);
      if (n == null) continue;
      final finalUrl = sized(n, targetPx);
      if (_inflightPreloads.containsKey(finalUrl)) {
        tasks.add(_inflightPreloads[finalUrl]!);
        continue;
      }
      final provider = CachedNetworkImageProvider(
        finalUrl,
        maxWidth: px,
        maxHeight: px,
      );
      final task = precacheImage(provider, context).catchError((_) {});
      _inflightPreloads[finalUrl] = task;
      task.whenComplete(() => _inflightPreloads.remove(finalUrl));
      tasks.add(task);
    }
    return Future.wait(tasks).then((_) {});
  }

  static Future<void> evict(String url) async {
    try {
      await CachedNetworkImage.evictFromCache(url);
    } catch (_) {}
  }
}
