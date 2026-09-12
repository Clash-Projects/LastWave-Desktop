import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/stream_models.dart';
import '../../core/network/dio_factory.dart';
import '../../core/network/lastfm_crypto.dart';
import '../../core/storage/secure_store.dart';

/// YouTube Music / InnerTube client for desktop.
///
/// Ported from LastWave-native `data/music/InnerTubeMusicApi.kt`
/// (endpoint paths, context shape, header/auth behaviour, client
/// rotation, caching, retry policy). Playback stays anonymous unless
/// the user connects a YouTube Music session cookie.
class YouTubeMusicTrack {
  final String videoId;
  final String title;
  final String artist;
  final String album;
  final String artworkUrl;
  final int durationSeconds;

  const YouTubeMusicTrack({
    required this.videoId,
    required this.title,
    required this.artist,
    this.album = '',
    this.artworkUrl = '',
    this.durationSeconds = 0,
  });
}

enum YouTubeEntityKind { artist, album, playlist }

class YouTubeMusicEntity {
  final YouTubeEntityKind kind;
  final String name;
  final String artist;
  final String subtitle;
  final String browseId;
  final String playlistId;
  final String artworkUrl;

  const YouTubeMusicEntity({
    required this.kind,
    required this.name,
    this.artist = '',
    this.subtitle = '',
    this.browseId = '',
    this.playlistId = '',
    this.artworkUrl = '',
  });
}

class YouTubePlaylistResult {
  final String id;
  final String title;
  final String author;
  final String artworkUrl;
  final List<YouTubeMusicTrack> tracks;

  const YouTubePlaylistResult({
    required this.id,
    required this.title,
    this.author = '',
    this.artworkUrl = '',
    this.tracks = const [],
  });
}

/// Authenticated YTM connection (raw cookie header + identity).
class YtConnection {
  final bool connected;
  final String cookies;
  final String accountName;
  final String channelHandle;
  final String photoUrl;

  const YtConnection({
    this.connected = false,
    this.cookies = '',
    this.accountName = '',
    this.channelHandle = '',
    this.photoUrl = '',
  });
}

class _PlayerClient {
  final String name;
  final String version;
  final String apiKey;
  final String userAgent;
  const _PlayerClient(
      this.name, this.version, this.apiKey, this.userAgent);
}

class _CachedStream {
  final ResolvedStream stream;
  final DateTime cachedAt;
  _CachedStream(this.stream, this.cachedAt);
}

class InnerTubeMusicApi {
  // -- endpoints (mirror Android constants) ------------------------------
  static const String musicApi = 'https://music.youtube.com/youtubei/v1';
  static const String youtubeApi = 'https://www.youtube.com/youtubei/v1';
  static const String musicOrigin = 'https://music.youtube.com';
  static const String webUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) '
      'Gecko/20100101 Firefox/140.0';

  static const String fallbackWebKey =
      'AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30';
  static const String fallbackWebVersion = '1.20260707.12.00';

  static const _clients = [
    _PlayerClient(
      'ANDROID_VR',
      '1.37',
      'AIzaSyD-p045F5RJsEM5fFzZpTwR0p2FpzO0w4I',
      'com.google.android.apps.youtube.vr.oculus/1.37 '
          '(Linux; U; Android 12; eureka)',
    ),
    _PlayerClient(
      'TVHTML5',
      '7.20260308.08.00',
      'AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8',
      'Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version',
    ),
  ];

  final Dio _dio;
  final SecureStore _secure;

  String _apiKey = fallbackWebKey;
  String _clientVersion = fallbackWebVersion;
  String? _visitorData;
  bool _configLoaded = false;
  Future<void>? _configFuture;

  final Map<String, _CachedStream> _streamCache = {};
  final Map<String, Future<ResolvedStream?>> _inflight = {};
  DateTime? _failedClientsUntil;

  YtConnection _connection = const YtConnection();

  InnerTubeMusicApi(this._dio, this._secure);

  YtConnection get connection => _connection;

  void setConnection(YtConnection c) => _connection = c;

  Future<void> loadPersistedConnection() async {
    final cookies = await _secure.readYtCookies() ?? '';
    if (cookies.isNotEmpty) {
      _connection = YtConnection(connected: true, cookies: cookies);
    }
  }

  Future<void> connect(String rawCookies) async {
    await _secure.writeYtCookies(rawCookies);
    _connection = YtConnection(connected: true, cookies: rawCookies);
  }

  Future<void> signOut() async {
    await _secure.writeYtCookies(null);
    _connection = const YtConnection();
  }

  // -- bootstrap ----------------------------------------------------------

  Future<void> _ensureConfig() {
    _configFuture ??= _fetchWebConfig();
    return _configFuture!;
  }

  Future<void> _fetchWebConfig() async {
    try {
      final res = await _dio.get<String>(
        '$musicOrigin/',
        options: Options(
          headers: {'User-Agent': webUserAgent},
          responseType: ResponseType.plain,
        ),
      );
      final html = res.data ?? '';
      final key = RegExp(r'"INNERTUBE_API_KEY"\s*:\s*"([^"]+)"')
          .firstMatch(html)
          ?.group(1);
      final version = RegExp(
              r'"INNERTUBE_CONTEXT_CLIENT_VERSION"\s*:\s*"([^"]+)"')
          .firstMatch(html)
          ?.group(1);
      final visitor = RegExp(r'"VISITOR_DATA"\s*:\s*"([^"]+)"')
          .firstMatch(html)
          ?.group(1);
      if (key != null && key.isNotEmpty) _apiKey = key;
      if (version != null && version.isNotEmpty) {
        _clientVersion = version;
      }
      _visitorData = visitor;
      _configLoaded = true;
    } catch (_) {
      _apiKey = fallbackWebKey;
      _clientVersion = fallbackWebVersion;
    }
  }

  // -- request plumbing ---------------------------------------------------

  String? _sapisid() {
    final cookies = _connection.cookies;
    if (cookies.isEmpty) return null;
    String? pick(String name) {
      for (final part in cookies.split(';')) {
        final kv = part.trim().split('=');
        if (kv.length >= 2 && kv[0].trim() == name) {
          return kv.sublist(1).join('=').trim();
        }
      }
      return null;
    }

    return pick('__Secure-3PAPISID') ??
        pick('SAPISID') ??
        pick('APISID');
  }

  Map<String, String> _postHeaders(String origin, String clientName,
      String clientVersion, bool authenticated) {
    final headers = {
      'Content-Type': 'application/json',
      'User-Agent': webUserAgent,
      'Origin': origin,
      'X-Origin': origin,
      'Referer': '$origin/',
      'X-Goog-Api-Format-Version': '1',
      'X-YouTube-Client-Name': _clientId(clientName),
      'X-YouTube-Client-Version': clientVersion,
    };
    if (_visitorData != null) {
      headers['X-Goog-Visitor-Id'] = _visitorData!;
    }
    if (authenticated && _connection.connected) {
      headers['Cookie'] = _connection.cookies;
      final sapisid = _sapisid();
      if (sapisid != null) {
        headers['Authorization'] =
            LastFmSigner.sapisidHash(sapisid, origin);
      }
    }
    return headers;
  }

  String _clientId(String name) {
    switch (name) {
      case 'WEB_REMIX':
        return '67';
      case 'TVHTML5':
        return '7';
      case 'ANDROID_VR':
        return '28';
      default:
        return '67';
    }
  }

  Map<String, dynamic> _context(String clientName, String clientVersion,
      {String? userAgent}) {
    return {
      'client': {
        'clientName': clientName,
        'clientVersion': clientVersion,
        'hl': 'en',
        'gl': 'US',
        'userAgent': ?userAgent,
      },
    };
  }

  Future<Map<String, dynamic>> _post(
    String path, {
    required Map<String, dynamic> body,
    bool youtubeHost = false,
    bool authenticated = false,
    String? apiKey,
    String? clientName,
    String? clientVersion,
  }) async {
    await _ensureConfig();
    final name = clientName ?? 'WEB_REMIX';
    final version =
        clientVersion ?? (_configLoaded ? _clientVersion : fallbackWebVersion);
    final key = apiKey ?? (_configLoaded ? _apiKey : fallbackWebKey);
    final origin = youtubeHost ? 'https://www.youtube.com' : musicOrigin;
    final url =
        '${youtubeHost ? youtubeApi : musicApi}/$path?key=$key';
    final res = await DioFactory.withRetry(() => _dio.post<String>(
          url,
          data: jsonEncode({
            'context': _context(name, version),
            ...body,
          }),
          options: Options(
            headers: _postHeaders(origin, name, version, authenticated),
            responseType: ResponseType.plain,
          ),
        ));
    final data = res.data;
    if (data == null || data.isEmpty) return const {};
    final decoded = jsonDecode(data);
    return decoded is Map<String, dynamic> ? decoded : const {};
  }

  // -- search ---------------------------------------------------------------

  Future<List<YouTubeMusicTrack>> searchSongs(String query,
      {int limit = 30}) async {
    final json = await _post('search', body: {
      'query': query,
      'params': 'EgWKAQIIAWoKEAkQBRAKEAMQBA==',
    });
    final tracks = _parseSongRenderers(json);
    return tracks.take(limit).toList();
  }

  Future<List<YouTubeMusicEntity>> searchArtists(String query,
      {int limit = 15}) async {
    final json = await _post('search', body: {
      'query': query,
      'params': 'EgWKAQIgAWoKEAkQBRAKEAMQBA==',
    });
    return _parseEntities(json, YouTubeEntityKind.artist).take(limit).toList();
  }

  Future<List<YouTubeMusicEntity>> searchAlbums(String query,
      {int limit = 15}) async {
    final json = await _post('search', body: {
      'query': query,
      'params': 'EgWKAQIYAWoKEAkQBRAKEAMQBA==',
    });
    return _parseEntities(json, YouTubeEntityKind.album).take(limit).toList();
  }

  Future<List<YouTubeMusicEntity>> searchPlaylists(String query,
      {int limit = 15}) async {
    final json = await _post('search', body: {'query': query});
    return _parseEntities(json, YouTubeEntityKind.playlist)
        .take(limit)
        .toList();
  }

  Future<List<String>> getSuggestions(String query) async {
    try {
      final res = await _dio.get<String>(
        'https://suggestqueries.google.com/complete/search',
        queryParameters: {
          'client': 'firefox',
          'ds': 'yt',
          'q': query,
        },
        options: Options(headers: {'User-Agent': webUserAgent}),
      );
      final decoded = jsonDecode(res.data ?? '[]');
      if (decoded is List && decoded.length > 1 && decoded[1] is List) {
        return (decoded[1] as List).map((e) => e.toString()).toList();
      }
    } catch (_) {}
    return const [];
  }

  // -- browse -----------------------------------------------------------------

  Future<List<YouTubeMusicTrack>> browseSongs(String browseId,
      {String? params, int limit = 30}) async {
    final json = await _post('browse', body: {
      'browseId': browseId,
      'params': ?params,
    });
    return _parseSongRenderers(json).take(limit).toList();
  }

  Future<List<YouTubeMusicTrack>> fetchRelatedSongs(String videoId,
      {int limit = 30}) async {
    final json = await _post('next', body: {
      'videoId': videoId,
      'playlistId': 'RDAMVM$videoId',
      'params': 'wAEB',
      'isAudioOnly': true,
    });
    return _parseSongRenderers(json).take(limit).toList();
  }

  Future<YouTubeMusicTrack?> fetchSongDetails(String videoId) async {
    final stream = await resolveAudioStream(videoId);
    if (stream == null) return null;
    return YouTubeMusicTrack(
      videoId: videoId,
      title: stream.cacheKey,
      artist: '',
    );
  }

  Future<YouTubePlaylistResult> fetchPlaylist(String playlistId,
      {int maxTracks = 200}) async {
    var id = playlistId.trim();
    if (!id.startsWith('VL') &&
        !id.startsWith('PL') &&
        !id.startsWith('RD') &&
        !id.startsWith('OLAK')) {
      id = 'VL$id';
    }
    final json = await _post('browse', body: {'browseId': id});
    final tracks = _parseSongRenderers(json).take(maxTracks).toList();
    final header = _findMap(json, [
      'musicDetailHeaderRenderer',
      'musicEditablePlaylistDetailHeaderRenderer',
    ]);
    String title() {
      final t = header?['title'];
      if (t is Map) {
        return _runsText(t['runs']) ?? t['text']?.toString() ?? '';
      }
      return t?.toString() ?? '';
    }

    return YouTubePlaylistResult(
      id: playlistId,
      title: title(),
      tracks: tracks,
    );
  }

  // -- stream resolution ---------------------------------------------------------

  /// Resolve the best audio-only stream for [videoId].
  ///
  /// Tries direct player clients in order (ANDROID_VR, TVHTML5, web
  /// fallback), picks the highest-bitrate audio format, and probes the
  /// URL before returning. Results are cached for 4h (mirror Android).
  Future<ResolvedStream?> resolveAudioStream(String videoId) async {
    final cached = _streamCache[videoId];
    if (cached != null) {
      final age =
          DateTime.now().difference(cached.cachedAt).inHours;
      if (age < 4 && !cached.stream.isExpired) return cached.stream;
      _streamCache.remove(videoId);
    }
    if (_inflight.containsKey(videoId)) return _inflight[videoId];
    final future = _resolveAudioStreamInternal(videoId);
    _inflight[videoId] = future;
    try {
      final stream = await future;
      if (stream != null) {
        _streamCache[videoId] = _CachedStream(stream, DateTime.now());
        if (_streamCache.length > 64) {
          _streamCache.remove(_streamCache.keys.first);
        }
      }
      return stream;
    } finally {
      _inflight.remove(videoId);
    }
  }

  Future<ResolvedStream?> _resolveAudioStreamInternal(
      String videoId) async {
    if (_failedClientsUntil != null &&
        DateTime.now().isBefore(_failedClientsUntil!)) {
      // fall through to web client only
    }
    final attempts = <_PlayerClient>[
      ..._clients,
      _PlayerClient('WEB_REMIX', _clientVersion, _apiKey, webUserAgent),
    ];
    var failures = 0;
    for (final client in attempts.take(2)) {
      try {
        final stream =
            await _playerStream(videoId, client).timeout(
          const Duration(seconds: 20),
        );
        if (stream != null && await _probeStream(stream.url)) {
          return stream;
        }
      } catch (_) {
        failures++;
      }
    }
    if (failures >= 2) {
      _failedClientsUntil =
          DateTime.now().add(const Duration(seconds: 60));
    }
    try {
      final stream = await _playerStream(videoId, attempts.last)
          .timeout(const Duration(seconds: 20));
      if (stream != null && await _probeStream(stream.url)) {
        return stream;
      }
      return stream;
    } catch (_) {
      return null;
    }
  }

  Future<ResolvedStream?> _playerStream(
      String videoId, _PlayerClient client) async {
    final json = await _post(
      'player',
      body: {
        'videoId': videoId,
        'contentCheckOk': true,
        'racyCheckOk': true,
      },
      youtubeHost: client.name != 'WEB_REMIX',
      clientName: client.name,
      clientVersion: client.version,
      apiKey: client.apiKey,
    );
    final streamingData =
        json['streamingData'] as Map<String, dynamic>?;
    if (streamingData == null) return null;
    final formats = <Map<String, dynamic>>[
      ..._asList(streamingData['adaptiveFormats']),
      ..._asList(streamingData['formats']),
    ];
    Map<String, dynamic>? best;
    var bestBitrate = -1;
    for (final f in formats) {
      final mime = (f['mimeType']?.toString() ?? '').toLowerCase();
      if (!mime.startsWith('audio/')) continue;
      if (f['url'] == null) continue; // skip ciphered formats
      final bitrate =
          (f['bitrate'] as num?)?.toInt() ?? (f['averageBitrate'] as num?)?.toInt() ?? 0;
      if (bitrate > bestBitrate) {
        bestBitrate = bitrate;
        best = f;
      }
    }
    if (best == null) return null;
    final mime = best['mimeType']?.toString() ?? 'audio/webm';
    final codec = mime.contains('opus')
        ? 'OPUS'
        : mime.contains('mp4')
            ? 'AAC'
            : 'AUDIO';
    final expire = RegExp(r'[?&]expire=(\d+)')
        .firstMatch(best['url'].toString())
        ?.group(1);
    return ResolvedStream(
      url: best['url'].toString(),
      mimeType: mime.split(';').first,
      bitrateKbps: (bestBitrate / 1000).round(),
      audioCodec: codec,
      cacheKey: 'yt:$videoId:${best['itag']}',
      expiresAt: expire == null
          ? DateTime.now().add(const Duration(hours: 5))
          : DateTime.fromMillisecondsSinceEpoch(
              int.parse(expire) * 1000),
    );
  }

  Future<bool> _probeStream(String url) async {
    try {
      final res = await _dio.get<List<int>>(
        url,
        options: Options(
          headers: {
            'Range': 'bytes=0-1',
            'User-Agent': webUserAgent,
          },
          responseType: ResponseType.bytes,
        ),
      ).timeout(const Duration(seconds: 10));
      final code = res.statusCode ?? 0;
      if (code != 200 && code != 206) return false;
      final contentType =
          res.headers.value('content-type')?.toLowerCase() ?? '';
      if (contentType.contains('html') ||
          contentType.contains('json') ||
          contentType.contains('text')) {
        return false;
      }
      return (res.data?.isNotEmpty ?? false);
    } catch (_) {
      return true; // fail-open: some hosts reject Range probes
    }
  }

  void reportPlaybackFailure(String videoId) {
    _streamCache.remove(videoId);
    _failedClientsUntil =
        DateTime.now().add(const Duration(seconds: 60));
  }

  // -- matching (mirrors Android findBestMatch) ------------------------------------

  static String normalize(String s) {
    var v = s.toLowerCase();
    v = v.replaceAll(RegExp(r'^\s*[\w&.\- ]+\s*-\s+'), '');
    v = v.replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ');
    return v.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static int similarity(String a, String b) {
    if (a == b) return 100;
    if (a.isEmpty || b.isEmpty) return 0;
    final dist = _levenshtein(a, b);
    final maxLen = max(a.length, b.length);
    return ((1 - dist / maxLen) * 100).round();
  }

  static int _levenshtein(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    var prev = List<int>.generate(b.length + 1, (i) => i);
    var curr = List<int>.filled(b.length + 1, 0);
    for (var i = 1; i <= a.length; i++) {
      curr[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        curr[j] = min(
          min(curr[j - 1] + 1, prev[j] + 1),
          prev[j - 1] + cost,
        );
      }
      final tmp = prev;
      prev = curr;
      curr = tmp;
    }
    return prev[b.length];
  }

  /// Score candidates the same way Android does (title ≥72, artist ≥50).
  Future<YouTubeMusicTrack?> findBestMatch(
    String title,
    String artist, {
    int? expectedDurationSeconds,
    Set<String> excludedVideoIds = const {},
  }) async {
    final candidates = await searchSongs('$title $artist', limit: 15);
    YouTubeMusicTrack? best;
    var bestScore = -1;
    final nTitle = normalize(title);
    final nArtist = normalize(artist);
    for (final c in candidates) {
      if (excludedVideoIds.contains(c.videoId)) continue;
      final ts = similarity(normalize(c.title), nTitle);
      if (ts < 72) continue;
      final as = nArtist.isEmpty
          ? 60
          : similarity(normalize(c.artist), nArtist);
      if (nArtist.isNotEmpty && as < 50) continue;
      var score = ts + as;
      if (expectedDurationSeconds != null &&
          expectedDurationSeconds > 0 &&
          c.durationSeconds > 0) {
        final diff =
            (c.durationSeconds - expectedDurationSeconds).abs();
        if (diff > 8) continue;
        score += (8 - diff) * 10;
      }
      if (score > bestScore) {
        bestScore = score;
        best = c;
      }
    }
    return best;
  }

  // -- JSON parsing helpers ----------------------------------------------------------

  List<Map<String, dynamic>> _asList(Object? v) {
    if (v is List) return v.whereType<Map<String, dynamic>>().toList();
    if (v is Map<String, dynamic>) return [v];
    return const [];
  }

  String? _runsText(Object? runs) {
    if (runs is List) {
      return runs
          .whereType<Map>()
          .map((r) => r['text']?.toString() ?? '')
          .join();
    }
    return null;
  }

  List<YouTubeMusicTrack> _parseSongRenderers(
      Map<String, dynamic> root) {
    final out = <YouTubeMusicTrack>[];
    final queue = <Object?>[root];
    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      if (current is Map<String, dynamic>) {
        if (current.containsKey('musicResponsiveListItemRenderer')) {
          final track = _parseListItem(
              current['musicResponsiveListItemRenderer']
                  as Map<String, dynamic>);
          if (track != null) out.add(track);
        } else if (current
            .containsKey('musicTwoRowItemRenderer')) {
          final track = _parseTwoRowItem(
              current['musicTwoRowItemRenderer']
                  as Map<String, dynamic>);
          if (track != null) out.add(track);
        }
        queue.addAll(current.values);
      } else if (current is List) {
        queue.addAll(current);
      }
    }
    return out;
  }

  YouTubeMusicTrack? _parseListItem(Map<String, dynamic> r) {
    String? videoId;
    final playlistItem = r['playlistItemData'] as Map<String, dynamic>?;
    videoId = playlistItem?['videoId']?.toString();
    videoId ??= (r['navigationEndpoint'] as Map?)?['watchEndpoint']
        ?['videoId']
        ?.toString();
    final flex = _asList(r['flexColumns']);
    if (flex.length < 2) {
      // still try: some shelves put videoId in overlay
      final overlay = r['overlay'] as Map<String, dynamic>?;
      videoId ??= _findVideoId(overlay);
      if (videoId == null || flex.isEmpty) return null;
    }
    String textOf(int i) {
      if (i >= flex.length) return '';
      final runs = ((flex[i] as Map)['musicResponsiveListItemFlexColumnRenderer']
              as Map?)?['text'];
      if (runs is Map) {
        return _runsText(runs['runs']) ?? runs['text']?.toString() ?? '';
      }
      return '';
    }

    videoId ??= _findVideoId(r);
    if (videoId == null || videoId.isEmpty) return null;
    final title = textOf(0);
    if (title.isEmpty) return null;
    final subtitle = textOf(1);
    final parts = subtitle.split(' • ');
    final artist = parts.isNotEmpty ? parts.first : '';
    final album = parts.length > 1 ? parts[1] : '';
    return YouTubeMusicTrack(
      videoId: videoId,
      title: title,
      artist: artist,
      album: album,
      artworkUrl: _thumbnail(r),
      durationSeconds: _parseDuration(textOf(2)),
    );
  }

  YouTubeMusicTrack? _parseTwoRowItem(Map<String, dynamic> r) {
    final titleObj = r['title'] as Map<String, dynamic>?;
    final title = titleObj?['text']?.toString() ??
        _runsText(titleObj?['runs']) ??
        '';
    final subtitleObj = r['subtitle'] as Map<String, dynamic>?;
    final subtitle = subtitleObj?['text']?.toString() ??
        _runsText(subtitleObj?['runs']) ??
        '';
    final videoId = _findVideoId(r);
    if (title.isEmpty || videoId == null) return null;
    final parts = subtitle.split(' • ');
    return YouTubeMusicTrack(
      videoId: videoId,
      title: title,
      artist: parts.isNotEmpty ? parts.first : '',
      album: parts.length > 1 ? parts[1] : '',
      artworkUrl: _thumbnail(r),
    );
  }

  String? _findVideoId(Object? node) {
    if (node is Map) {
      final watch = node['watchEndpoint'] as Map?;
      final id = watch?['videoId']?.toString();
      if (id != null && id.isNotEmpty) return id;
      for (final v in node.values) {
        final found = _findVideoId(v);
        if (found != null) return found;
      }
    } else if (node is List) {
      // shallow search to avoid runaway recursion
      for (final v in node.take(25)) {
        final found = _findVideoId(v);
        if (found != null) return found;
      }
    }
    return null;
  }

  Map<String, dynamic>? _findMap(
      Map<String, dynamic> root, List<String> keys) {
    final queue = <Object?>[root];
    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      if (current is Map<String, dynamic>) {
        for (final k in keys) {
          if (current[k] is Map<String, dynamic>) {
            return current[k] as Map<String, dynamic>;
          }
        }
        queue.addAll(current.values.take(200));
      } else if (current is List) {
        queue.addAll(current.take(200));
      }
    }
    return null;
  }

  List<YouTubeMusicEntity> _parseEntities(
      Map<String, dynamic> root, YouTubeEntityKind kind) {
    final out = <YouTubeMusicEntity>[];
    final queue = <Object?>[root];
    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      if (current is Map<String, dynamic>) {
        if (current.containsKey('musicTwoRowItemRenderer')) {
          final r = current['musicTwoRowItemRenderer']
              as Map<String, dynamic>;
          final titleObj = r['title'] as Map<String, dynamic>?;
          final name = titleObj?['text']?.toString() ??
              _runsText(titleObj?['runs']) ??
              '';
          final subtitleObj = r['subtitle'] as Map<String, dynamic>?;
          final subtitle = subtitleObj?['text']?.toString() ??
              _runsText(subtitleObj?['runs']) ??
              '';
          final nav = r['navigationEndpoint'] as Map<String, dynamic>?;
          final browse = (nav?['browseEndpoint']
                  as Map?)?['browseId']
              ?.toString();
          if (name.isNotEmpty) {
            out.add(YouTubeMusicEntity(
              kind: kind,
              name: name,
              subtitle: subtitle,
              browseId: browse ?? '',
              artworkUrl: _thumbnail(r),
            ));
          }
        } else {
          queue.addAll((current.values).take(300));
        }
      } else if (current is List) {
        queue.addAll(current.take(300));
      }
    }
    return out;
  }

  String _thumbnail(Map<String, dynamic> r) {
    final queue = <Object?>[r['thumbnail']];
    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      if (current is Map<String, dynamic>) {
        if (current['url'] is String &&
            current['width'] is num &&
            current['height'] is num) {
          return current['url'] as String;
        }
        queue.addAll(current.values);
      } else if (current is List) {
        queue.addAll(current);
      }
    }
    return '';
  }

  int _parseDuration(String s) {
    final parts = s.split(':').map(int.tryParse).toList();
    if (parts.any((e) => e == null)) return 0;
    final nums = parts.whereType<int>().toList();
    if (nums.length == 2) return nums[0] * 60 + nums[1];
    if (nums.length == 3) {
      return nums[0] * 3600 + nums[1] * 60 + nums[2];
    }
    return 0;
  }
}

final innerTubeProvider = Provider<InnerTubeMusicApi>((ref) {
  final dio = DioFactory.create();
  final api = InnerTubeMusicApi(dio, ref.watch(secureStoreProvider));
  api.loadPersistedConnection();
  return api;
});
