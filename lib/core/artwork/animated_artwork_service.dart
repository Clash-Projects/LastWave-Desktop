import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../network/dio_factory.dart';
import '../storage/app_database.dart';
import '../../features/player/playback_service.dart';
import '../../features/search/shared_providers.dart';
import 'official_artwork_service.dart';

/// Square HLS/fMP4 motion artwork from https://artwork.m8tec.top
class AnimatedArtwork {
  final String url;
  final String urlTall;

  const AnimatedArtwork({
    required this.url,
    this.urlTall = '',
  });

  bool get hasUrl => url.isNotEmpty;
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
const _animMiss = 'anim-miss';
const _hitTtl = Duration(days: 30);
const _missTtl = Duration(days: 7);

String animatedArtworkCacheKey({
  required String artist,
  String album = '',
  required String title,
}) {
  final a = OfficialArtworkService.normalizeForSearch(artist);
  final b = OfficialArtworkService.normalizeForSearch(album);
  if (b.isNotEmpty) {
    return 'anim5|$a|$b';
  }
  return 'anim5|$a||${OfficialArtworkService.normalizeForSearch(title)}';
}

const appleArtworkHeaders = {
  'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
  'Referer': 'https://music.apple.com/',
  'Origin': 'https://music.apple.com',
  'Accept': '*/*',
};

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
  );
}

/// Lookup + memory/SQLite cache for Apple Music motion artwork.
class AnimatedArtworkService {
  static const baseUrl = 'https://artwork.m8tec.top';

  final Dio _dio;
  final AppDatabase? _db;
  final Map<String, AnimatedArtwork?> _memory = {};
  final Map<String, Future<AnimatedArtwork?>> _inflight = {};
  int _active = 0;
  final List<void Function()> _queue = [];

  AnimatedArtworkService({Dio? dio, this._db})
      : _dio = dio ?? DioFactory.create();

  AnimatedArtwork? peek(AnimatedArtworkQuery query) => _memory[query.cacheKey];

  bool isCached(AnimatedArtworkQuery query) =>
      _memory.containsKey(query.cacheKey);

  void prefetch(AnimatedArtworkQuery query) {
    unawaited(lookup(query));
  }

  Future<AnimatedArtwork?> lookup(AnimatedArtworkQuery query) {
    final key = query.cacheKey;
    if (OfficialArtworkService.normalizeForSearch(query.artist).isEmpty &&
        OfficialArtworkService.normalizeForSearch(query.title).isEmpty) {
      return Future.value(null);
    }
    return _lookupKey(key, () => _fetchSearch(query, key));
  }

  Future<AnimatedArtwork?> lookupByUrl(String appleMusicUrl) {
    final url = appleMusicUrl.trim();
    if (url.isEmpty || !url.contains('music.apple.com')) {
      return Future.value(null);
    }
    final key = 'anim5|url|${url.toLowerCase()}';
    return _lookupKey(key, () => _fetchUrl(url, key));
  }

  Future<AnimatedArtwork?> _lookupKey(
    String key,
    Future<AnimatedArtwork?> Function() fetch,
  ) {
    if (_memory.containsKey(key)) return Future.value(_memory[key]);

    final disk = _readDisk(key);
    if (disk != null) {
      _memory[key] = disk.$1;
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
    if (provider == _animHit &&
        (url.contains('.m3u8') || url.contains('.mp4'))) {
      return (AnimatedArtwork(url: url), age < _hitTtl.inMilliseconds);
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
      final artist = query.artist.trim();
      var album = query.album.trim();
      final title = query.title.trim();
      if (album.isEmpty) {
        album = await _albumFromOfficial(artist: artist, title: title);
      }

      AnimatedArtwork? found;
      if (album.isNotEmpty && title.isNotEmpty) {
        found =
            await _requestSearch(artist: artist, album: album, title: title);
      }
      if (found == null && album.isNotEmpty) {
        found = await _requestSearch(artist: artist, album: album);
      }
      found ??= await _lookupViaItunes(
        artist,
        album.isNotEmpty ? album : title,
      );
      if (found == null) {
        _store(key, null);
        return null;
      }
      final playable = await _resolvePlayableUrl(found.url);
      final resolved = AnimatedArtwork(url: playable, urlTall: found.urlTall);
      _store(key, resolved);
      return resolved;
    } catch (_) {
      return _memory[key];
    }
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
      final resolved = AnimatedArtwork(url: playable, urlTall: found.urlTall);
      _store(key, resolved);
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

  Future<String> _resolvePlayableUrl(String masterUrl) async {
    try {
      final master = await _getPlain(masterUrl);
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
        headers: appleArtworkHeaders,
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
    _db?.saveArtworkEntry(
      cacheKey: key,
      url: art?.url ?? '',
      provider: art == null ? _animMiss : _animHit,
    );
  }
}

final animatedArtworkServiceProvider = Provider<AnimatedArtworkService>((ref) {
  return AnimatedArtworkService(db: ref.watch(databaseProvider));
});

final animatedArtworkProvider =
    FutureProvider.family<AnimatedArtwork?, AnimatedArtworkQuery>((ref, query) {
  final svc = ref.watch(animatedArtworkServiceProvider);
  if (svc.isCached(query)) return Future.value(svc.peek(query));
  return svc.lookup(query);
});

/// Warms JSON lookup for the current track and next two in queue.
final animatedArtworkWarmupProvider = Provider<void>((ref) {
  final svc = ref.watch(animatedArtworkServiceProvider);
  ref.listen(
    playbackServiceProvider.select((s) => s.current?.queueKey ?? ''),
    (_, _) {
      final snap = ref.read(playbackServiceProvider);
      final current = snap.current;
      if (current == null) return;
      svc.prefetch(AnimatedArtworkQuery(
        artist: current.artist,
        album: current.album,
        title: current.title,
      ));
      final q = snap.queue;
      final i = snap.currentIndex;
      for (final offset in [1, 2]) {
        if (i + offset >= q.length) continue;
        final track = q[i + offset];
        svc.prefetch(AnimatedArtworkQuery(
          artist: track.artist,
          album: track.album,
          title: track.title,
        ));
      }
    },
    fireImmediately: true,
  );
});
