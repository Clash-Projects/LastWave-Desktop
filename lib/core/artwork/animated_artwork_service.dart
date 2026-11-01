import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../diagnostics/memory_probe.dart';
import '../network/dio_factory.dart';
import '../storage/app_database.dart';
import '../../features/innertube/innertube_api.dart';
import '../../features/search/shared_providers.dart';
import 'apple_music_canvas.dart';
import 'community_canvas.dart';
import 'official_artwork_service.dart';
import 'tidal_canvas.dart';

export 'apple_music_canvas.dart';
export 'community_canvas.dart';
export 'tidal_canvas.dart';

/// Which provider a motion artwork clip came from.
///
/// Priority order: [apple] > [tidal] > [community].
enum CanvasSource {
  apple,
  tidal,
  community,
}

typedef CanvasArtwork = AnimatedArtwork;

/// Looping motion artwork clip (Apple Music editorialVideo HLS/fMP4,
/// Tidal 1280x1280 video cover MP4, or Community Canvas manifest MP4).
class AnimatedArtwork {
  final String url;
  final String urlTall;
  final String? fallbackUrl;
  final String? title;
  final String? artist;
  final String? album;
  final CanvasSource source;

  const AnimatedArtwork({
    required this.url,
    this.urlTall = '',
    this.fallbackUrl,
    this.title,
    this.artist,
    this.album,
    this.source = CanvasSource.apple,
  });

  bool get hasUrl => url.isNotEmpty;

  /// Whether this clip really belongs to the track we asked about.
  ///
  /// Title and artists must match once punctuation, case and accents
  /// are stripped. The album is checked when both sides provide it.
  bool matches({
    required String wantTitle,
    required String wantArtist,
    String? wantAlbum,
  }) {
    final titleOk = title == null ||
        wantTitle.trim().isEmpty ||
        canvasTitlesMatch(wantTitle, title!);

    final artistOk = artist == null ||
        wantArtist.trim().isEmpty ||
        canvasArtistsMatch(
          wantArtist,
          artist!,
          wantTitle: wantTitle,
          gotTitle: title,
        );

    final nAlbum = album != null ? normalizeCanvasMatch(album!) : '';
    final nWantAlbum =
        wantAlbum != null ? normalizeCanvasMatch(wantAlbum) : '';
    final sAlbum =
        album != null ? normalizeCanvasMatch(stripCanvasSubtitles(album!)) : '';
    final sWantAlbum = wantAlbum != null
        ? normalizeCanvasMatch(stripCanvasSubtitles(wantAlbum))
        : '';
    final albumOk = nAlbum.isEmpty ||
        nWantAlbum.isEmpty ||
        nAlbum == nWantAlbum ||
        nAlbum.contains(nWantAlbum) ||
        nWantAlbum.contains(nAlbum) ||
        (sAlbum.isNotEmpty &&
            sWantAlbum.isNotEmpty &&
            (sAlbum == sWantAlbum ||
                sAlbum.contains(sWantAlbum) ||
                sWantAlbum.contains(sAlbum)));

    return titleOk && artistOk && albumOk;
  }
}

/// Normalizes case, accents and punctuation between platforms (e.g.
/// "Beyoncé - CRAZY IN LOVE (feat. JAY-Z)" -> "beyonce crazy in love feat jay z").
String normalizeCanvasMatch(String raw) => unorm
    .nfd(raw)
    .replaceAll(RegExp(r'[\u0300-\u036f]+'), '')
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

final RegExp _subtitleBrackets = RegExp(
  r'\s*(?:\([^)]*\)|\[[^\]]*\])\s*',
  caseSensitive: false,
);

final RegExp _trailingDashTag = RegExp(
  r'\s+-\s+(?:single|ep|deluxe|remaster(?:ed)?|explicit|bonus.*|feat\.?.*|ft\.?.*)$',
  caseSensitive: false,
);

/// Strips parenthetical/bracketed subtitles such as `(feat. Daft Punk)`,
/// `(Deluxe Edition)`, `[Official Audio]`, or `- Single` so core titles
/// and album names can match across catalogs.
String stripCanvasSubtitles(String raw) {
  final stripped = raw
      .replaceAll(_subtitleBrackets, ' ')
      .replaceAll(_trailingDashTag, ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return stripped.isEmpty ? raw.trim() : stripped;
}

/// Compares two track or album titles across catalog conventions.
bool canvasTitlesMatch(String wantTitle, String gotTitle) {
  final nWant = normalizeCanvasMatch(wantTitle);
  final nGot = normalizeCanvasMatch(gotTitle);
  if (nWant.isEmpty || nGot.isEmpty) return false;
  if (nWant == nGot || nGot.contains(nWant) || nWant.contains(nGot)) {
    return true;
  }
  final sWant = normalizeCanvasMatch(stripCanvasSubtitles(wantTitle));
  final sGot = normalizeCanvasMatch(stripCanvasSubtitles(gotTitle));
  if (sWant.isNotEmpty && sGot.isNotEmpty) {
    if (sWant == sGot || sGot.contains(sWant) || sWant.contains(sGot)) {
      return true;
    }
  }
  return false;
}

/// Compares credited artists across platforms.
///
/// Handles cases where YouTube Music lists featured artists in the artist
/// field (`"The Weeknd, Daft Punk"`) while Apple Music, Tidal, or Community
/// Canvas credits only the primary artist (`"The Weeknd"`) or puts
/// `(feat. Daft Punk)` in the song title.
bool canvasArtistsMatch(
  String wantArtist,
  String gotArtist, {
  String? wantTitle,
  String? gotTitle,
}) {
  final wanted = splitCanvasArtists(wantArtist);
  final credited = splitCanvasArtists(gotArtist);
  if (wanted.isEmpty || credited.isEmpty) {
    final nWant = normalizeCanvasMatch(wantArtist);
    final nGot = normalizeCanvasMatch(gotArtist);
    if (nWant.isEmpty || nGot.isEmpty) return false;
    return nWant == nGot || nGot.contains(nWant) || nWant.contains(nGot);
  }

  final nGotTitle = gotTitle != null ? normalizeCanvasMatch(gotTitle) : '';
  final nWantTitle = wantTitle != null ? normalizeCanvasMatch(wantTitle) : '';

  bool tokenMatchesList(String token, List<String> pool, String extraTitle) {
    if (pool.any((it) => it == token || it.contains(token) || token.contains(it))) {
      return true;
    }
    if (extraTitle.isNotEmpty && extraTitle.contains(token)) {
      return true;
    }
    return false;
  }

  // Match if all wanted artists are accounted for in credited (+ gotTitle),
  // OR all credited artists are accounted for in wanted (+ wantTitle).
  final allWantedMatched =
      wanted.every((w) => tokenMatchesList(w, credited, nGotTitle));
  if (allWantedMatched) return true;

  final allCreditedMatched =
      credited.every((c) => tokenMatchesList(c, wanted, nWantTitle));
  if (allCreditedMatched) return true;

  return false;
}

final RegExp _artistSeparators = RegExp(
  r'(?:\s*,\s*|\s*&\s*|\s+×\s+|\s+x\s+|\bfeat\.?\b|\bft\.?\b|\bfeaturing\b|\bwith\b)',
  caseSensitive: false,
);

/// Splits credited artists across varying separators (commas, ampersands,
/// "feat.", "ft.", "x", "with").
List<String> splitCanvasArtists(String raw) => raw
    .split(_artistSeparators)
    .map(normalizeCanvasMatch)
    .where((s) => s.isNotEmpty)
    .toList();

/// Extracts the primary artist name so tracks on the same album with
/// different featured artists share a canonical artist key.
String primaryCanvasArtist(String raw) {
  final parts = raw.split(_artistSeparators);
  for (final part in parts) {
    final trimmed = part.trim();
    if (trimmed.isNotEmpty) return trimmed;
  }
  return raw.trim();
}

final RegExp _canvasNoise = RegExp(
  r'\((?:from|official|lyrical|video|audio)[^)]*\)|\[[^\]]*\]|'
  r'\b(?:official (?:video|audio|music video)|lyrical|full song|4k video)\b',
  caseSensitive: false,
);

/// Strips YouTube/video noise markers before querying canvas providers.
String cleanCanvasQuery(String raw) {
  final cleaned = raw
      .replaceAll(_canvasNoise, ' ')
      .split(' | ')
      .first
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return cleaned.isEmpty ? raw.trim() : cleaned;
}

const String canvasUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

/// Plain GET returning response text, or null on non-2xx or failure.
Future<String?> canvasGetText(
  Dio dio,
  String url, {
  Map<String, String> headers = const {},
  Map<String, dynamic>? queryParameters,
}) async {
  try {
    final res = await dio.get<Object?>(
      url,
      queryParameters: queryParameters,
      options: Options(
        responseType: ResponseType.plain,
        headers: {
          'User-Agent': canvasUserAgent,
          ...headers,
        },
        validateStatus: (code) => code != null && code >= 200 && code < 300,
      ),
    );
    if (res.statusCode == null ||
        res.statusCode! < 200 ||
        res.statusCode! >= 300) {
      return null;
    }
    final data = res.data;
    if (data is String) return data;
    if (data is Map || data is List) return jsonEncode(data);
    return data?.toString();
  } catch (_) {
    return null;
  }
}

/// Plain GET returning a decoded JSON object map, or null on non-2xx/failure.
Future<Map<String, dynamic>?> canvasGetJson(
  Dio dio,
  String url, {
  Map<String, String> headers = const {},
  Map<String, dynamic>? queryParameters,
}) async {
  try {
    final res = await dio.get<Object?>(
      url,
      queryParameters: queryParameters,
      options: Options(
        headers: {
          'User-Agent': canvasUserAgent,
          ...headers,
        },
        validateStatus: (code) => code != null && code >= 200 && code < 300,
      ),
    );
    if (res.statusCode == null ||
        res.statusCode! < 200 ||
        res.statusCode! >= 300) {
      return null;
    }
    final data = res.data;
    if (data is Map) {
      return Map<String, dynamic>.from(data);
    }
    if (data is String && data.isNotEmpty) {
      final decoded = jsonDecode(data);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    }
  } catch (_) {}
  return null;
}

class AnimatedArtworkQuery {
  final String artist;
  final String album;
  final String title;

  const AnimatedArtworkQuery({
    required this.artist,
    this.album = '',
    required this.title,
  });

  String get cacheKey => animatedArtworkCacheKey(
        artist: artist,
        album: album,
        title: title,
      );

  @override
  bool operator ==(Object other) =>
      other is AnimatedArtworkQuery && other.cacheKey == cacheKey;

  @override
  int get hashCode => cacheKey.hashCode;
}

const _animHit = 'anim';
const _animTidalHit = 'anim-tidal';
const _animCommunityHit = 'anim-community';
const _animMiss = 'anim-v2-miss';
const _hitTtl = Duration(days: 30);
// Short miss memory: a transient failure (offline first play,
// backend 404) must not brick an album for a week. Hits stay 30d.
const _missTtl = Duration(hours: 12);

String animatedArtworkCacheKey({
  required String artist,
  String album = '',
  required String title,
}) {
  final cleanedAlbum = cleanCanvasQuery(stripCanvasSubtitles(album));
  final b = OfficialArtworkService.normalizeForSearch(
    cleanedAlbum.isNotEmpty ? cleanedAlbum : album,
  );
  if (b.isNotEmpty) {
    final primary = primaryCanvasArtist(cleanCanvasQuery(artist));
    final aPrimary = OfficialArtworkService.normalizeForSearch(
      primary.isNotEmpty ? primary : artist,
    );
    return 'anim6|$aPrimary|$b';
  }
  final a = OfficialArtworkService.normalizeForSearch(artist);
  return 'anim6|$a||${OfficialArtworkService.normalizeForSearch(title)}';
}

const appleArtworkHeaders = {
  'User-Agent': canvasUserAgent,
  'Referer': 'https://music.apple.com/',
  'Origin': 'https://music.apple.com',
  'Accept': '*/*',
};

Map<String, String> headersForAnimatedArtworkUrl(String url) {
  final lower = url.toLowerCase();
  if (lower.contains('apple.com')) {
    return appleArtworkHeaders;
  }
  if (lower.contains('tidal.com')) {
    return const {
      'User-Agent': canvasUserAgent,
      'Accept': '*/*',
    };
  }
  if (lower.contains('spotify') || lower.contains('scdn.co')) {
    return const {
      'User-Agent': canvasUserAgent,
      'Referer': 'https://open.spotify.com/',
      'Origin': 'https://open.spotify.com',
      'Accept': '*/*',
    };
  }
  return const {
    'User-Agent': canvasUserAgent,
    'Accept': '*/*',
  };
}

/// Persistent disk cache for `.mp4` animated cover loops.
///
/// Saves resolved `.mp4` clips (Apple Music fMP4, Tidal 1280x1280 MP4,
/// Community Canvas MP4) to `<systemTemp>/lastwave_canvas_cache/` with a
/// 150 MB LRU cap so repeated plays, same-album track switches, and app
/// restarts decode directly from local disk without re-downloading.
class CanvasDiskCache {
  CanvasDiskCache._();

  static final CanvasDiskCache instance = CanvasDiskCache._();

  static const int _maxCacheBytes = 150 * 1024 * 1024;
  static const int _minValidBytes = 1024;

  final Map<String, Future<String?>> _inFlight = {};
  Directory? _dir;

  Directory _ensureDir() {
    final existing = _dir;
    if (existing != null && existing.existsSync()) return existing;
    final dir = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}lastwave_canvas_cache',
    );
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    _dir = dir;
    return dir;
  }

  /// Whether [url] is a direct HTTP(S) `.mp4` video file suitable for single-file
  /// disk caching (as opposed to a multi-segment `.m3u8` HLS playlist).
  static bool isCacheableMp4(String url) {
    final lower = url.trim().toLowerCase();
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      return false;
    }
    final path = lower.split('?').first.split('#').first;
    return path.endsWith('.mp4') ||
        path.endsWith('.m4v') ||
        path.endsWith('.mov');
  }

  static String _hashUrl(String url) {
    var hash = BigInt.parse('cbf29ce484222325', radix: 16);
    final prime = BigInt.parse('100000001b3', radix: 16);
    final mask = BigInt.parse('ffffffffffffffff', radix: 16);
    for (final byte in utf8.encode(url.trim())) {
      hash = (hash ^ BigInt.from(byte)) & mask;
      hash = (hash * prime) & mask;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  File _fileFor(String url) {
    final dir = _ensureDir();
    return File(
      '${dir.path}${Platform.pathSeparator}canvas_${_hashUrl(url)}.mp4',
    );
  }

  /// Returns the local `.mp4` file path if [url] is already cached on disk,
  /// or `null` if it hasn't been downloaded yet.
  String? peekFilePath(String url) {
    if (!isCacheableMp4(url)) return null;
    try {
      final file = _fileFor(url);
      if (file.existsSync() && file.lengthSync() >= _minValidBytes) {
        return file.path;
      }
    } catch (_) {}
    return null;
  }

  /// Downloads [url] to the local disk cache in the background if not already
  /// present. No-ops inside `flutter test` runs so offline unit tests stay pure.
  Future<String?> warm(String url) {
    if (!isCacheableMp4(url)) return Future.value(null);
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      return Future.value(null);
    }
    final existing = peekFilePath(url);
    if (existing != null) return Future.value(existing);
    return _inFlight[url] ??= _download(url).whenComplete(() {
      _inFlight.remove(url);
    });
  }

  Future<String?> _download(String url) async {
    HttpClient? client;
    try {
      final target = _fileFor(url);
      if (target.existsSync() && target.lengthSync() >= _minValidBytes) {
        return target.path;
      }
      final tmp = File('${target.path}.tmp');
      client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
      final req = await client.getUrl(Uri.parse(url));
      headersForAnimatedArtworkUrl(url).forEach(req.headers.set);
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        return null;
      }
      final sink = tmp.openWrite();
      var total = 0;
      await for (final chunk in res) {
        total += chunk.length;
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      if (total < _minValidBytes) {
        try {
          if (tmp.existsSync()) tmp.deleteSync();
        } catch (_) {}
        return null;
      }
      if (target.existsSync()) {
        try {
          target.deleteSync();
        } catch (_) {}
      }
      tmp.renameSync(target.path);
      _evictIfNeeded();
      return target.path;
    } catch (_) {
      return null;
    } finally {
      client?.close(force: false);
    }
  }

  void _evictIfNeeded() {
    try {
      final dir = _ensureDir();
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.mp4'))
          .toList();
      var totalBytes = 0;
      final entries = <({File file, int size, DateTime modified})>[];
      for (final file in files) {
        final stat = file.statSync();
        totalBytes += stat.size;
        entries.add((file: file, size: stat.size, modified: stat.modified));
      }
      if (totalBytes <= _maxCacheBytes) return;
      entries.sort((a, b) => a.modified.compareTo(b.modified));
      for (final entry in entries) {
        if (totalBytes <= _maxCacheBytes) break;
        try {
          entry.file.deleteSync();
          totalBytes -= entry.size;
        } catch (_) {}
      }
    } catch (_) {}
  }
}

/// Picks a mid-size H.264 STREAM-INF rendition. Apple masters list
/// I-frame trick-play first, then 4K HEVC — those look still or fail.
String? pickAnimatedArtworkStream(String playlist, {String masterUrl = ''}) {
  final lines = playlist.split(RegExp(r'\r?\n'));
  var bestUrl = '';
  var bestScore = -0x7fffffff;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;
    final res = RegExp(r'RESOLUTION=(\d+)x(\d+)').firstMatch(line);
    final w = int.tryParse(res?.group(1) ?? '') ?? 0;
    final h = int.tryParse(res?.group(2) ?? '') ?? 0;
    final size = w > h ? w : h;
    if (i + 1 >= lines.length) continue;
    final next = lines[i + 1].trim();
    if (next.isEmpty || next.startsWith('#')) continue;
    var score = 0;
    if (line.contains('avc1')) score += 2000;
    if (line.contains('hvc1') || line.contains('hev1')) score -= 400;
    score -= (size - 640).abs();
    if (size >= 1080) score -= 800;
    if (size >= 1920) score -= 2000;
    if (score > bestScore) {
      bestScore = score;
      bestUrl = next;
    }
  }
  if (bestUrl.isEmpty) return null;
  if (masterUrl.isEmpty) return bestUrl;
  return Uri.parse(masterUrl).resolve(bestUrl).toString();
}

/// Apple motion-art variants are one fMP4 addressed by HLS byteranges.
String? pickAnimatedArtworkFile(
  String variantPlaylist, {
  required String variantUrl,
}) {
  if (!variantPlaylist.contains('#EXT-X-MAP:')) return null;
  final mapped =
      RegExp(r'#EXT-X-MAP:URI="([^"]+)"').firstMatch(variantPlaylist);
  var uri = mapped?.group(1)?.trim() ?? '';
  if (uri.isEmpty) {
    for (final line in variantPlaylist.split(RegExp(r'\r?\n'))) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      uri = trimmed;
      break;
    }
  }
  if (uri.isEmpty) return null;
  return Uri.parse(variantUrl).resolve(uri).toString();
}

AnimatedArtwork? parseAnimatedArtworkPayload(Object? json) {
  if (json is! Map) return null;
  final url = json['url']?.toString() ?? '';
  if (url.isEmpty || !url.contains('.m3u8')) return null;
  return AnimatedArtwork(
    url: url,
    urlTall: json['url_tall']?.toString() ?? '',
    source: CanvasSource.apple,
  );
}

/// Multi-source lookup + memory/SQLite cache for animated album artwork.
///
/// Waterfall priority order (matching LastWave-Native `CanvasRepository`):
/// 1. Apple Music (`AppleMusicCanvas` + proxy fallback)
/// 2. Tidal (`TidalCanvas` 1280x1280 video covers)
/// 3. Community (`CommunityCanvas` ViMusic manifest)
class AnimatedArtworkService {
  static const baseUrl = 'https://artwork.m8tec.top';

  final Dio _dio;
  final AppDatabase? _db;

  /// YouTube Music album backfill for tracks whose metadata lacks an
  /// album (store catalogs can't derive "Currents" from title+artist
  /// when covers pollute term search). Closure-injected so tests stay
  /// offline. Returns '' when unknown.
  final Future<String> Function(String title, String artist)? albumLookup;
  final Map<String, AnimatedArtwork?> _memory = {};
  final Map<String, String> _trackAlbumKeys = {};
  final Map<String, Future<AnimatedArtwork?>> _inflight = {};
  int _active = 0;
  final List<void Function()> _queue = [];

  AnimatedArtworkService({Dio? dio, this._db, this.albumLookup})
      : _dio = dio ?? DioFactory.create() {
    MemoryProbe.register('motion', () => debugGauge);
  }

  /// Motion-art plumbing residency: memory cache (bounded), in-flight
  /// lookups (a memo that never clears would pin album queries) and the
  /// two-deep concurrency queue.
  String get debugGauge =>
      'cache=${_memory.length} inflight=${_inflight.length} '
      'queue=${_queue.length} active=$_active';

  String _trackKeyId(String artist, String title) {
    final p = OfficialArtworkService.normalizeForSearch(
      primaryCanvasArtist(cleanCanvasQuery(artist)),
    );
    final t = OfficialArtworkService.normalizeForSearch(
      stripCanvasSubtitles(cleanCanvasQuery(title)),
    );
    return '$p|$t';
  }

  /// Resolves a secondary album-based cache key when [query.album] was empty
  /// on the incoming track but `OfficialArtworkService` or a previous lookup
  /// already resolved the track's album.
  String? _fallbackAlbumKey(AnimatedArtworkQuery query) {
    if (query.album.trim().isNotEmpty) return null;
    final id = _trackKeyId(query.artist, query.title);
    final mapped = _trackAlbumKeys[id];
    if (mapped != null && mapped.isNotEmpty) return mapped;
    try {
      final peeked = OfficialArtworkService.instance.peekTrack(
        title: cleanCanvasQuery(query.title),
        artist: cleanCanvasQuery(query.artist),
      );
      final officialAlbum = peeked?.albumTitle.trim() ?? '';
      if (officialAlbum.isNotEmpty) {
        return animatedArtworkCacheKey(
          artist: query.artist,
          album: officialAlbum,
          title: query.title,
        );
      }
    } catch (_) {}
    return null;
  }

  AnimatedArtwork? peek(AnimatedArtworkQuery query) {
    final key = query.cacheKey;
    if (_memory.containsKey(key)) {
      final direct = _memory[key];
      if (direct != null) return direct;
    }
    final altKey = _fallbackAlbumKey(query);
    if (altKey != null && _memory.containsKey(altKey)) {
      final viaAlbum = _memory[altKey];
      if (viaAlbum != null) {
        _memory[key] = viaAlbum;
        return viaAlbum;
      }
    }
    return _memory[key];
  }

  bool isCached(AnimatedArtworkQuery query) {
    final key = query.cacheKey;
    if (_memory.containsKey(key)) return true;
    final altKey = _fallbackAlbumKey(query);
    if (altKey != null && _memory.containsKey(altKey)) {
      _memory[key] = _memory[altKey];
      return true;
    }
    return false;
  }

  void prefetch(AnimatedArtworkQuery query) {
    unawaited(lookup(query));
  }

  Future<AnimatedArtwork?> lookup(AnimatedArtworkQuery query) {
    final key = query.cacheKey;
    if (OfficialArtworkService.normalizeForSearch(query.artist).isEmpty &&
        OfficialArtworkService.normalizeForSearch(query.title).isEmpty) {
      return Future.value(null);
    }
    return _lookupKey(
      key,
      () => _fetchSearch(query, key),
      query: query,
    );
  }

  Future<AnimatedArtwork?> lookupByUrl(String appleMusicUrl) {
    final url = appleMusicUrl.trim();
    if (url.isEmpty || !url.contains('music.apple.com')) {
      return Future.value(null);
    }
    final key = 'anim6|url|${url.toLowerCase()}';
    return _lookupKey(key, () => _fetchUrl(url, key));
  }

  Future<AnimatedArtwork?> _lookupKey(
    String key,
    Future<AnimatedArtwork?> Function() fetch, {
    AnimatedArtworkQuery? query,
  }) {
    if (_memory.containsKey(key)) {
      final cached = _memory[key];
      if (cached != null) return Future.value(cached);
      if (query != null && query.title.trim().isNotEmpty) {
        final communityHit = CommunityCanvas.peekMatch(
          title: cleanCanvasQuery(query.title),
          artist: cleanCanvasQuery(query.artist),
          album: query.album.trim().isEmpty
              ? null
              : cleanCanvasQuery(query.album),
        );
        if (communityHit != null) return Future.value(communityHit);
      }
      return Future.value(null);
    }

    if (query != null) {
      final altKey = _fallbackAlbumKey(query);
      if (altKey != null) {
        if (_memory.containsKey(altKey) && _memory[altKey] != null) {
          final hit = _memory[altKey]!;
          _memory[key] = hit;
          return Future.value(hit);
        }
        final altDisk = _readDisk(altKey);
        if (altDisk != null && altDisk.$2 && altDisk.$1 != null) {
          _memory[altKey] = altDisk.$1;
          _memory[key] = altDisk.$1;
          return Future.value(altDisk.$1);
        }
      }
    }

    final disk = _readDisk(key);
    if (disk != null) {
      _memory[key] = disk.$1;
      if (disk.$1 != null) {
        unawaited(CanvasDiskCache.instance.warm(disk.$1!.url));
      }
      if (disk.$2) return Future.value(disk.$1);
    }

    return _inflight[key] ??= _throttle(fetch).whenComplete(() {
      _inflight.remove(key);
    });
  }

  (AnimatedArtwork?, bool)? _readDisk(String key) {
    final row = _db?.loadArtworkRecord(key);
    if (row == null) return null;
    final provider = row['provider'] as String? ?? '';
    final url = row['url'] as String? ?? '';
    final ts = row['timestamp_millis'] as int? ?? 0;
    final age = DateTime.now().millisecondsSinceEpoch - ts;
    if (provider == _animMiss) {
      return (null, age < _missTtl.inMilliseconds);
    }
    final isHitProvider = provider == _animHit ||
        provider == _animTidalHit ||
        provider == _animCommunityHit;
    if (isHitProvider &&
        (url.contains('.m3u8') ||
            url.contains('.mp4') ||
            url.startsWith('http'))) {
      final source = switch (provider) {
        _animTidalHit => CanvasSource.tidal,
        _animCommunityHit => CanvasSource.community,
        _ => CanvasSource.apple,
      };
      return (
        AnimatedArtwork(url: url, source: source),
        age < _hitTtl.inMilliseconds,
      );
    }
    return null;
  }

  Future<T> _throttle<T>(Future<T> Function() task) {
    final completer = Completer<T>();
    void run() {
      _active++;
      task().then(completer.complete).catchError(completer.completeError)
          .whenComplete(() {
        _active--;
        if (_queue.isNotEmpty) _queue.removeAt(0)();
      });
    }

    if (_active < 2) {
      run();
    } else {
      _queue.add(run);
    }
    return completer.future;
  }

  Future<AnimatedArtwork?> _fetchSearch(
    AnimatedArtworkQuery query,
    String key,
  ) async {
    try {
      final rawArtist = query.artist.trim();
      final rawTitle = query.title.trim();
      final rawAlbum = query.album.trim();

      final artist = cleanCanvasQuery(rawArtist);
      final title = cleanCanvasQuery(rawTitle);
      var album = rawAlbum.isEmpty ? '' : cleanCanvasQuery(rawAlbum);

      if (album.isEmpty && (artist.isNotEmpty || title.isNotEmpty)) {
        album = await _albumFromOfficial(artist: artist, title: title);
      }
      // YouTube Music knows the album the stores can't derive: its
      // search rows carry the MPRE album badge, immune to cover-song
      // pollution ("The Less I Know The Better" → Currents).
      if (album.isEmpty && albumLookup != null) {
        try {
          final viaYtm = await albumLookup!(title, artist)
              .timeout(const Duration(seconds: 8));
          if (viaYtm.trim().isNotEmpty) {
            album = cleanCanvasQuery(viaYtm.trim());
          }
        } catch (_) {}
      }

      // If album was backfilled (was empty on the incoming query), check
      // whether another track on the same album already cached this album's
      // animated cover in memory or SQLite before hitting the network.
      if (rawAlbum.isEmpty && album.isNotEmpty) {
        final albumKey = animatedArtworkCacheKey(
          artist: artist,
          album: album,
          title: title,
        );
        _trackAlbumKeys[_trackKeyId(artist, title)] = albumKey;
        if (_memory.containsKey(albumKey) && _memory[albumKey] != null) {
          final cachedAlbumArt = _memory[albumKey]!;
          _store(key, cachedAlbumArt);
          return cachedAlbumArt;
        }
        final diskAlbum = _readDisk(albumKey);
        if (diskAlbum != null && diskAlbum.$2 && diskAlbum.$1 != null) {
          final cachedAlbumArt = diskAlbum.$1!;
          _memory[albumKey] = cachedAlbumArt;
          _store(key, cachedAlbumArt);
          unawaited(CanvasDiskCache.instance.warm(cachedAlbumArt.url));
          return cachedAlbumArt;
        }
      }

      // Waterfall lookup in strict priority order:
      // 1. Apple Music > 2. Tidal > 3. Community
      final found = await _firstHit(
        [
          () => _lookupAppleMusic(
                artist: artist,
                album: album,
                title: title,
              ),
          () => _lookupTidal(
                artist: artist,
                album: album,
                title: title,
              ),
          () => _lookupCommunity(
                artist: artist,
                album: album,
                title: title,
              ),
        ],
        wantTitle: title,
        wantArtist: artist,
        wantAlbum: album.isEmpty ? null : album,
      );

      if (found == null) {
        _store(key, null);
        return null;
      }

      final playable = await _resolvePlayableIfNeeded(found.url);
      final fallbackPlayable =
          (found.fallbackUrl != null && found.fallbackUrl!.isNotEmpty)
              ? await _resolvePlayableIfNeeded(found.fallbackUrl!)
              : null;
      final effectiveAlbum = album.isNotEmpty
          ? album
          : (found.album?.trim().isNotEmpty == true ? found.album!.trim() : '');
      final resolved = AnimatedArtwork(
        url: playable,
        urlTall: found.urlTall,
        fallbackUrl: fallbackPlayable,
        title: found.title,
        artist: found.artist,
        album: effectiveAlbum.isEmpty ? found.album : effectiveAlbum,
        source: found.source,
      );
      _store(key, resolved);
      if (effectiveAlbum.isNotEmpty) {
        final albumKey = animatedArtworkCacheKey(
          artist: artist,
          album: effectiveAlbum,
          title: title,
        );
        _trackAlbumKeys[_trackKeyId(artist, title)] = albumKey;
        if (albumKey != key) {
          _store(albumKey, resolved);
        }
      }
      unawaited(CanvasDiskCache.instance.warm(resolved.url));
      return resolved;
    } catch (_) {
      return _memory[key];
    }
  }

  Future<AnimatedArtwork?> _firstHit(
    List<Future<AnimatedArtwork?> Function()> sources, {
    required String wantTitle,
    required String wantArtist,
    String? wantAlbum,
  }) async {
    for (final source in sources) {
      try {
        final found = await source();
        if (found == null || !found.hasUrl) continue;
        // Validate against requested metadata; if album metadata from YTM is
        // noisy (e.g. single name instead of album), accept a title+artist match
        // when the provider returned a song-specific title.
        final matchesWithAlbum = found.matches(
          wantTitle: wantTitle,
          wantArtist: wantArtist,
          wantAlbum: wantAlbum,
        );
        final matchesSong = wantTitle.isNotEmpty &&
            found.title != null &&
            found.matches(
              wantTitle: wantTitle,
              wantArtist: wantArtist,
            );
        if (!matchesWithAlbum && !matchesSong) continue;
        return found;
      } catch (_) {}
    }
    return null;
  }

  Future<AnimatedArtwork?> _lookupAppleMusic({
    required String artist,
    required String album,
    required String title,
  }) async {
    // 1a. Direct Apple Music AMP catalog (editorialVideo)
    AnimatedArtwork? found;
    if (title.isNotEmpty && artist.isNotEmpty) {
      found = await AppleMusicCanvas.search(
        _dio,
        title: title,
        artist: artist,
        album: album.isEmpty ? null : album,
      );
      if (found == null && album.isNotEmpty) {
        found = await AppleMusicCanvas.search(
          _dio,
          title: title,
          artist: artist,
        );
      }
      if (found == null && album.isNotEmpty) {
        found = await AppleMusicCanvas.searchAlbum(
          _dio,
          album: album,
          artist: artist,
        );
      }
    } else if (album.isNotEmpty && artist.isNotEmpty) {
      found = await AppleMusicCanvas.searchAlbum(
        _dio,
        album: album,
        artist: artist,
      );
    }
    if (found != null) return found;

    // 1b. Proxy / iTunes fallback for Apple Music
    final primary = primaryCanvasArtist(artist);
    if (album.isNotEmpty && title.isNotEmpty) {
      found = await _requestSearch(artist: artist, album: album, title: title);
      if (found == null && primary != artist) {
        found =
            await _requestSearch(artist: primary, album: album, title: title);
      }
    }
    if (found == null && album.isNotEmpty) {
      found = await _requestSearch(artist: artist, album: album);
      if (found == null && primary != artist) {
        found = await _requestSearch(artist: primary, album: album);
      }
    }
    found ??= await _lookupViaItunes(
      primary.isNotEmpty ? primary : artist,
      album.isNotEmpty ? album : title,
    );
    return found;
  }

  Future<AnimatedArtwork?> _lookupTidal({
    required String artist,
    required String album,
    required String title,
  }) async {
    if (artist.isEmpty) return null;
    AnimatedArtwork? found;
    if (title.isNotEmpty) {
      found = await TidalCanvas.search(
        _dio,
        title: title,
        artist: artist,
        album: album.isEmpty ? null : album,
      );
      if (found == null && album.isNotEmpty) {
        found = await TidalCanvas.search(
          _dio,
          title: title,
          artist: artist,
        );
      }
      if (found == null && album.isNotEmpty) {
        found = await TidalCanvas.searchAlbum(
          _dio,
          album: album,
          artist: artist,
        );
      }
    } else if (album.isNotEmpty) {
      found = await TidalCanvas.searchAlbum(
        _dio,
        album: album,
        artist: artist,
      );
    }
    return found;
  }

  Future<AnimatedArtwork?> _lookupCommunity({
    required String artist,
    required String album,
    required String title,
  }) async {
    final searchTitle = title.isNotEmpty ? title : album;
    if (searchTitle.isEmpty || artist.isEmpty) return null;
    var found = await CommunityCanvas.search(
      _dio,
      title: searchTitle,
      artist: artist,
      album: album.isEmpty ? null : album,
    );
    if (found == null && album.isNotEmpty && title.isNotEmpty) {
      found = await CommunityCanvas.search(
        _dio,
        title: title,
        artist: artist,
      );
    }
    return found;
  }

  Future<String> _albumFromOfficial({
    required String artist,
    required String title,
  }) async {
    try {
      final peeked = OfficialArtworkService.instance.peekTrack(
        title: title,
        artist: artist,
      );
      if (peeked != null && peeked.albumTitle.trim().isNotEmpty) {
        return peeked.albumTitle.trim();
      }
      final official = await OfficialArtworkService.instance
          .resolveOfficialArtwork(title: title, artist: artist);
      return official?.albumTitle.trim() ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<AnimatedArtwork?> _fetchUrl(String appleMusicUrl, String key) async {
    try {
      final found = await _request(
        path: '/api/v1/artwork/url',
        queryParameters: {'url': appleMusicUrl},
      );
      if (found == null) {
        _store(key, null);
        return null;
      }
      final playable = await _resolvePlayableUrl(found.url);
      final resolved = AnimatedArtwork(
        url: playable,
        urlTall: found.urlTall,
        source: CanvasSource.apple,
      );
      _store(key, resolved);
      unawaited(CanvasDiskCache.instance.warm(resolved.url));
      return resolved;
    } catch (_) {
      return _memory[key];
    }
  }

  Future<AnimatedArtwork?> _requestSearch({
    required String artist,
    required String album,
    String title = '',
  }) {
    return _request(
      path: '/api/v1/artwork/search',
      queryParameters: {
        'artist': artist,
        'album': album,
        if (title.isNotEmpty) 'title': title,
      },
    );
  }

  Future<AnimatedArtwork?> _lookupViaItunes(String artist, String album) async {
    if (artist.isEmpty || album.isEmpty) return null;
    try {
      final res = await _dio.get(
        'https://itunes.apple.com/search',
        queryParameters: {
          'term': '$artist $album',
          'entity': 'album',
          'limit': 5,
        },
      );
      final results = res.data is Map ? res.data['results'] : null;
      if (results is! List) return null;
      for (final item in results) {
        if (item is! Map) continue;
        final raw = item['collectionViewUrl']?.toString() ?? '';
        if (raw.isEmpty) continue;
        final art = await _request(
          path: '/api/v1/artwork/url',
          queryParameters: {'url': raw.split('?').first},
        );
        if (art != null) return art;
      }
    } catch (_) {}
    return null;
  }

  Future<AnimatedArtwork?> _request({
    required String path,
    required Map<String, dynamic> queryParameters,
  }) async {
    try {
      final res = await DioFactory.withRetry(
        () => _dio.get(
          '$baseUrl$path',
          queryParameters: queryParameters,
          options: Options(
            validateStatus: (code) =>
                code != null && (code == 200 || code == 400 || code == 404),
          ),
        ),
      );
      if (res.statusCode != 200) return null;
      return parseAnimatedArtworkPayload(res.data);
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 400 || code == 404) return null;
      rethrow;
    }
  }

  Future<String> _resolvePlayableIfNeeded(String url) async {
    if (url.contains('.m3u8')) {
      return _resolvePlayableUrl(url);
    }
    return url;
  }

  Future<String> _resolvePlayableUrl(String masterUrl) async {
    try {
      final master = await _getPlain(masterUrl);
      final directFile = pickAnimatedArtworkFile(master, variantUrl: masterUrl);
      if (directFile != null && directFile.contains('.mp4')) return directFile;
      final stream = pickAnimatedArtworkStream(master, masterUrl: masterUrl);
      final variantUrl = stream ?? masterUrl;
      if (stream != null && stream != masterUrl) {
        final variant = await _getPlain(stream);
        final file = pickAnimatedArtworkFile(variant, variantUrl: stream);
        if (file != null && file.contains('.mp4')) return file;
      }
      if (variantUrl.contains('.m3u8') || variantUrl.contains('.mp4')) {
        return variantUrl;
      }
    } catch (_) {}
    return masterUrl;
  }

  Future<String> _getPlain(String url) async {
    final res = await _dio.get(
      url,
      options: Options(
        responseType: ResponseType.plain,
        headers: headersForAnimatedArtworkUrl(url),
        validateStatus: (code) => code != null && code >= 200 && code < 400,
      ),
    );
    return res.data?.toString() ?? '';
  }

  void _store(String key, AnimatedArtwork? art) {
    _memory[key] = art;
    if (_memory.length > 256) {
      _memory.remove(_memory.keys.first);
    }
    final provider = switch (art?.source) {
      null => _animMiss,
      CanvasSource.apple => _animHit,
      CanvasSource.tidal => _animTidalHit,
      CanvasSource.community => _animCommunityHit,
    };
    _db?.saveArtworkEntry(
      cacheKey: key,
      url: art?.url ?? '',
      provider: provider,
    );
  }
}

final animatedArtworkServiceProvider = Provider<AnimatedArtworkService>((ref) {
  // NOTE: read (not watch) — the closure runs at lookup time, long
  // after this provider builds, where watch throws.
  return AnimatedArtworkService(
    db: ref.watch(databaseProvider),
    albumLookup: (title, artist) async {
      try {
        final match = await ref
            .read(innerTubeProvider)
            .findBestMatchOrNull(title, artist)
            .timeout(const Duration(seconds: 8));
        return match?.album.trim() ?? '';
      } catch (_) {
        return '';
      }
    },
  );
});

final animatedArtworkProvider =
    FutureProvider.family<AnimatedArtwork?, AnimatedArtworkQuery>((ref, query) {
  final svc = ref.watch(animatedArtworkServiceProvider);
  if (svc.isCached(query)) return Future.value(svc.peek(query));
  return svc.lookup(query);
});
