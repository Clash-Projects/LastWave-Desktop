import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../../core/audio/stream_models.dart';
import '../../core/network/dio_factory.dart';
import '../../core/network/lastfm_crypto.dart';
import '../../core/storage/app_database.dart';
import '../../core/storage/secure_store.dart';
import '../search/shared_providers.dart';
import 'potoken_engine.dart';
import 'signature_decipher.dart';

/// Structured stream debug log. Mirrors Android `STREAM_LOG_TAG`
/// fields (stage/videoId/client/itag/mime/expiry/retry/http).
/// NEVER logs URLs, cookies, tokens or auth headers.
void _logStream(
  String stage, {
  String videoId = '',
  String client = '',
  int itag = -1,
  String mime = '',
  String expiry = 'unknown',
  int retry = 0,
  int http = 0,
  String detail = '',
}) {
  if (!kDebugMode) return;
  final d = detail.length > 80 ? detail.substring(0, 80) : detail;
  debugPrint(
      'LastWaveStream stage=$stage videoId=$videoId client=$client '
      'itag=$itag mime=$mime expiry=$expiry retry=$retry http=$http $d');
}

class InnerTubeHttpException implements Exception {
  final int responseCode;
  InnerTubeHttpException(this.responseCode);
  @override
  String toString() => 'InnerTube HTTP $responseCode';
}

class ConfirmedUnplayableMediaException implements Exception {
  final String message;
  ConfirmedUnplayableMediaException(this.message);
  @override
  String toString() => 'ConfirmedUnplayable: $message';
}

class NoReliableMatchException implements Exception {
  final String message;
  NoReliableMatchException(this.message);
  @override
  String toString() => message;
}

/// YouTube Music / InnerTube client â€” Android parity port.
///
/// Behaviour mirrors LastWave-native `InnerTubeMusicApi`:
/// same endpoints, client table, headers, auth gating, parsing,
/// matching, player strategy, probing, caching, retries and
/// cooldowns. Two deliberate desktop adaptations:
/// - signature decipher is pure Dart (base.js) instead of NewPipe.
/// - poToken minting (Android WebView BotGuard) is unavailable, so
///   requests proceed without it â€” the same fail-open path Android
///   takes when minting fails.
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

enum YouTubeEntityKind { artist, album }

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
  final int trackCount;
  final List<YouTubeMusicTrack> tracks;

  const YouTubePlaylistResult({
    required this.id,
    required this.title,
    this.author = '',
    this.artworkUrl = '',
    this.trackCount = 0,
    this.tracks = const [],
  });
}

/// Album browse result: page header metadata plus its tracks.
///
/// Album track rows omit per-track artist/album/artwork (they are
/// implied by the header), so [browseAlbum] inherits those fields
/// onto every track that lacks them.
class YouTubeAlbumResult {
  final String browseId;
  final String title;
  final String artist;
  final String artworkUrl;
  final String year;
  final List<YouTubeMusicTrack> tracks;

  const YouTubeAlbumResult({
    required this.browseId,
    required this.title,
    this.artist = '',
    this.artworkUrl = '',
    this.year = '',
    this.tracks = const [],
  });
}

class YouTubePlaylistSummary {
  final String id;
  final String title;
  final String author;
  final String trackCountText;
  final String artworkUrl;

  const YouTubePlaylistSummary({
    required this.id,
    required this.title,
    this.author = '',
    this.trackCountText = '',
    this.artworkUrl = '',
  });
}

/// Authenticated YTM connection (raw cookie header + identity).
class YtConnection {
  final bool connected;
  final String cookies;
  final String accountName;
  final String channelHandle;
  final String photoUrl;
  final int connectedAtMillis;

  const YtConnection({
    this.connected = false,
    this.cookies = '',
    this.accountName = '',
    this.channelHandle = '',
    this.photoUrl = '',
    this.connectedAtMillis = 0,
  });
}

class PlayerClient {
  final String name;
  final String version;
  final String apiKey;
  final String userAgent;
  final String? osName;
  final String? osVersion;
  final String? deviceMake;
  final String? deviceModel;
  final String? androidSdkVersion;

  const PlayerClient(
    this.name,
    this.version,
    this.apiKey,
    this.userAgent, {
    this.osName,
    this.osVersion,
    this.deviceMake,
    this.deviceModel,
    this.androidSdkVersion,
  });

  String get key => '$name@$version';

  String get origin => name == 'WEB_REMIX'
      ? InnerTubeMusicApi.musicOrigin
      : InnerTubeMusicApi.youtubeOrigin;

  String get referer {
    switch (name) {
      case 'WEB_REMIX':
        return '${InnerTubeMusicApi.musicOrigin}/';
      case 'TVHTML5':
      case 'TVHTML5_SIMPLY_EMBEDDED_PLAYER':
        return '${InnerTubeMusicApi.youtubeOrigin}/tv';
      case 'WEB_EMBEDDED_PLAYER':
        return '${InnerTubeMusicApi.youtubeOrigin}/embed';
      default:
        return '${InnerTubeMusicApi.youtubeOrigin}/';
    }
  }

  Map<String, String> get streamRequestHeaders {
    final headers = {
      'User-Agent': userAgent,
      'X-YouTube-Client-Name':
          InnerTubeMusicApi.clientIds[name] ?? name,
      'X-YouTube-Client-Version': version,
    };
    if (name == 'WEB_REMIX' ||
        name == 'TVHTML5' ||
        name == 'TVHTML5_SIMPLY_EMBEDDED_PLAYER' ||
        name == 'WEB_EMBEDDED_PLAYER' ||
        name == 'MWEB') {
      headers['Origin'] = origin;
      headers['Referer'] = referer;
    }
    return headers;
  }
}

class _CachedStream {
  final ResolvedStream stream;
  final String clientProfile;
  final int itag;
  final bool adaptive;
  final String authScope;
  final DateTime cachedAt;
  _CachedStream(
    this.stream,
    this.clientProfile,
    this.itag,
    this.adaptive,
    this.authScope,
    this.cachedAt,
  );
}

class InnerTubeMusicApi {
  // -- endpoints ---------------------------------------------------------
  static const String musicApi =
      'https://music.youtube.com/youtubei/v1';
  static const String youtubeApi =
      'https://www.youtube.com/youtubei/v1';
  static const String musicOrigin = 'https://music.youtube.com';
  static const String youtubeOrigin = 'https://www.youtube.com';
  static const String webUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) '
      'Gecko/20100101 Firefox/140.0';

  static const String fallbackWebKey =
      'AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30';
  static const String fallbackWebVersion = '1.20260707.12.00';

  static const String libraryPlaylistsBrowseId =
      'FEmusic_liked_playlists';
  static const String historyBrowseId = 'FEmusic_history';
  static const String likedBrowseId = 'VLLM';
  static const String homeBrowseId = 'FEmusic_home';
  static const String newReleasesBrowseId =
      'FEmusic_new_releases';
  static const String chartsBrowseId = 'FEmusic_charts';

  static const String songsSearchFilter =
      'EgWKAQIIAWoKEAkQBRAKEAMQBA==';
  static const String artistSearchFilter =
      'EgWKAQIgAWoKEAkQBRAKEAMQBA==';
  static const String albumSearchFilter =
      'EgWKAQIYAWoKEAkQBRAKEAMQBA==';
  static const String playlistSearchFilter =
      'Eg-KAQwIABAAGAAgACgB';

  static const Map<String, String> clientIds = {
    'WEB_REMIX': '67',
    'IOS': '5',
    'IOS_MUSIC': '26',
    'IOS_CREATOR': '15',
    'ANDROID': '3',
    'ANDROID_MUSIC': '21',
    'ANDROID_VR': '28',
    'ANDROID_TESTSUITE': '30',
    'ANDROID_CREATOR': '14',
    'TVHTML5': '7',
    'TVHTML5_SIMPLY_EMBEDDED_PLAYER': '85',
    'VISIONOS': '101',
    'WEB_EMBEDDED_PLAYER': '56',
    'MWEB': '62',
  };

  static const List<PlayerClient> playerClients = [
    // Limusic fast order: direct-URL clients first (no cipher/poToken),
    // ciphered web clients last. The resolver tries VISIONOS alone
    // first, then at most 2 more fallbacks — never the full table.
    PlayerClient(
      'VISIONOS',
      '0.1',
      'AIzaSyB-63vPrdThhKuerbB2N_l7Kwwcxj6yUAc',
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15',
      osName: 'visionOS',
      osVersion: '1.3.21O771',
      deviceMake: 'Apple',
      deviceModel: 'RealityDevice14,1',
    ),
    PlayerClient(
      'ANDROID_VR',
      '1.65.10',
      'AIzaSyD-p045F_WzU-vA_YgX20SCx4KAo',
      'com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip',
      osName: 'Android',
      osVersion: '12L',
      deviceMake: 'Oculus',
      deviceModel: 'Quest 3',
      androidSdkVersion: '32',
    ),
    PlayerClient(
      'ANDROID_TESTSUITE',
      '1.9',
      'AIzaSyD-p045F_WzU-vA_YgX20SCx4KAo',
      'com.google.android.youtube/1.9 (Linux; U; Android 12) gzip',
      osName: 'Android',
      osVersion: '12',
    ),
    PlayerClient(
      'ANDROID_MUSIC',
      '7.27.52',
      'AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w',
      'com.google.android.apps.youtube.music/7.27.52 (Linux; U; Android 14; en_US; Pixel 8; Build/UD1A.230803.041) gzip',
      osName: 'Android',
      osVersion: '14',
      deviceMake: 'Google',
      deviceModel: 'Pixel 8',
      androidSdkVersion: '34',
    ),
    PlayerClient(
      'IOS_MUSIC',
      '7.27.0',
      'AIzaSyB-63vPrdThhKuerbB2N_l7Kwwcxj6yUAc',
      'com.google.ios.youtubemusic/7.27.0 (iPhone16,2; U; CPU iOS 17_5_1 like Mac OS X;)',
      osName: 'iOS',
      osVersion: '17.5.1.21F90',
      deviceMake: 'Apple',
      deviceModel: 'iPhone16,2',
    ),
    PlayerClient(
      'TVHTML5',
      '7.20260308.08.00',
      'AIzaSyAO_FJ2SlqAz8GlBg1fA54p0wDE7Xk80mU',
      'Mozilla/5.0 (SMART-TV; Linux; Tizen 6.0) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/4.0 Chrome/76.0.3809.146 TV Safari/537.36',
    ),
    PlayerClient(
      'TVHTML5_SIMPLY_EMBEDDED_PLAYER',
      '2.0',
      'AIzaSyAO_FJ2SlqAz8GlBg1fA54p0wDE7Xk80mU',
      'Mozilla/5.0 (SMART-TV; Linux; Tizen 6.0) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/4.0 Chrome/76.0.3809.146 TV Safari/537.36',
    ),
    PlayerClient(
      'IOS',
      '21.26.4',
      'AIzaSyB-63vPrdThhKuerbB2N_l7Kwwcxj6yUAc',
      'com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2;)',
      osName: 'iPhone',
      osVersion: '18.3.2.22D82',
      deviceMake: 'Apple',
      deviceModel: 'iPhone16,2',
    ),
    PlayerClient(
      'ANDROID',
      '21.26.364',
      'AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w',
      'com.google.android.youtube/21.26.364 (Linux; U; Android 11) gzip',
      osName: 'Android',
      osVersion: '11',
    ),
    PlayerClient(
      'ANDROID_CREATOR',
      '24.32.100',
      'AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w',
      'com.google.android.apps.youtube.creator/24.32.100 (Linux; U; Android 13; en_US) gzip',
      osName: 'Android',
      osVersion: '13',
    ),
    PlayerClient(
      'IOS_CREATOR',
      '24.32.100',
      'AIzaSyB-63vPrdThhKuerbB2N_l7Kwwcxj6yUAc',
      'com.google.ios.creator/24.32.100 (iPhone16,2; U; CPU iOS 17_5_1 like Mac OS X;)',
      osName: 'iOS',
      osVersion: '17.5.1.21F90',
    ),
    PlayerClient(
      'WEB_REMIX',
      fallbackWebVersion,
      'AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30',
      webUserAgent,
    ),
    PlayerClient(
      'WEB_EMBEDDED_PLAYER',
      fallbackWebVersion,
      'AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30',
      webUserAgent,
    ),
    PlayerClient(
      'MWEB',
      '2.20260707.01.00',
      'AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30',
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1',
    ),
  ];

  // -- matching tables (mirror Android companion) --------------------------
  static final RegExp _nonWord = RegExp(r'[^a-z0-9]+');
  static final RegExp _diacritics = RegExp(r'\p{M}+', unicode: true);
  static final RegExp _multiSpace = RegExp(r'\s+');
  static const Set<String> _variantWords = {
    'live', 'remix', 'karaoke', 'cover', 'instrumental', 'slowed',
    'sped', 'nightcore', 'acoustic', 'demo', 'edit', 'remaster',
    'remastered', 'mono', 'stereo',
  };
  static const Set<String> _matchNoiseWords = {
    'official', 'audio', 'video', 'visualizer', 'lyrics', 'lyric',
  };
  static final RegExp _featuringClause = RegExp(
      r'[(\\[]\s*(feat(?:uring)?|ft)\.?\s+.*?[)\]]',
      caseSensitive: false);
  static final RegExp _versionClause = RegExp(
      r'[(\\[][^)\]]*(live|remix|acoustic|demo|edit|remaster(?:ed)?|mono|stereo)[^)\]]*[)\]]',
      caseSensitive: false);
  static final RegExp _codecPattern =
      RegExp('codecs?=["\']([^"\']+)["\']', caseSensitive: false);

  static const List<String> _confirmedUnavailableReasons = [
    'video has been removed',
    'video has been deleted',
    'video was removed',
    'video was deleted',
    'this video is private',
    'this is a private video',
    'not available in your country',
    'blocked in your country',
    'copyright claim',
  ];

  static const int _maxContinuationPages = 600;
  static const int _maxPlayerRequestAttempts = 1;
  static const int _clientCooldownMs = 60000;
  static const int _maxStreamCacheEntries = 256;
  static const int _streamTtlMs = 4 * 60 * 60 * 1000;
  static const int _maxMatchCacheEntries = 1024;
  static const int _urlExpiryMarginMs = 2 * 60 * 1000;
  static const int _unknownExpiryTtlMs = 5 * 60 * 1000;
  // Limusic fast path: one preferred direct-URL client first,
  // then at most 2 limited fallbacks. Never fan out to the full table.
  static const String _fastPreferredClient = 'VISIONOS';
  static const int _maxStreamClients = 3;
  static const Duration _fastClientTimeout = Duration(seconds: 8);

  final Dio _dio;
  final SecureStore _secure;
  late final SignatureDecipher _decipher;
  final PoTokenEngine? _poTokens;
  AppDatabase? _disk;
  bool _diskLoaded = false;

  String _apiKey = fallbackWebKey;
  String _clientVersion = fallbackWebVersion;
  String? _visitorData;
  Future<void>? _configFuture;

  final Map<String, _CachedStream> _streamCache = {};
  final Map<String, Future<ResolvedStream?>> _inflight = {};
  final Map<String, DateTime> _failedClientsUntil = {};
  final Map<String, YouTubeMusicTrack> _matchCache = {};
  final Map<String, _ResolvedRef> _lastResolved = {};
  String? _lastSuccessfulClientName;

  YtConnection _connection = const YtConnection();

  InnerTubeMusicApi(this._dio, this._secure,
      [this._poTokens]) {
    _decipher = SignatureDecipher(_dio);
  }

  /// Attach the persistent disk cache (call once from the provider).
  /// Loads up to 256 recent stream entries + prunes expired rows.
  /// Also restores the InnerTube web config (API key / client version /
  /// visitorData) so a cold start skips the music.youtube.com HTML
  /// fetch — Limusic keeps its client registry on disk for the same
  /// reason (clients.json + override file) instead of re-bootstrapping
  /// every launch.
  void attachDiskCache(AppDatabase db) {
    _disk = db;
    try {
      final rawCfg = db.kvGet('yt_web_config');
      if (rawCfg != null && rawCfg.isNotEmpty) {
        final decoded = jsonDecode(rawCfg);
        if (decoded is Map<String, dynamic>) {
          final key = decoded['apiKey']?.toString() ?? '';
          final version = decoded['clientVersion']?.toString() ?? '';
          final visitor = decoded['visitorData']?.toString() ?? '';
          final savedAt =
              (decoded['savedAtMs'] as num?)?.toInt() ?? 0;
          if (key.isNotEmpty) _apiKey = key;
          if (version.isNotEmpty) _clientVersion = version;
          if (visitor.isNotEmpty) _visitorData = visitor;
          if (savedAt > 0) {
            // Instant cold start: serve from disk now, refresh the
            // config in the background when older than 24h.
            _configFuture = Future.value();
            final ageMs = DateTime.now().millisecondsSinceEpoch -
                savedAt;
            if (ageMs > 24 * 60 * 60 * 1000) {
              unawaited(_fetchWebConfig());
            }
          }
        }
      }
    } catch (_) {}
    if (_diskLoaded) return;
    _diskLoaded = true;
    try {
      db.pruneExpiredStreams(
          DateTime.now().millisecondsSinceEpoch + _urlExpiryMarginMs);
      final rows = db.loadStreamEntries(limit: 256);
      final now = DateTime.now();
      for (final r in rows) {
        try {
          final videoId = r['video_id']?.toString() ?? '';
          if (videoId.isEmpty) continue;
          final clientProfile =
              r['client_profile']?.toString() ?? '';
          final itag = (r['itag'] as num?)?.toInt() ?? -1;
          final url = r['url']?.toString() ?? '';
          if (url.isEmpty) continue;
          final authScope =
              r['auth_scope']?.toString() ?? 'anonymous';
          final expiresAtMs =
              (r['expires_at_ms'] as num?)?.toInt() ?? 0;
          final cachedAtMs =
              (r['cached_at_ms'] as num?)?.toInt() ?? 0;
          final expiresAt = expiresAtMs > 0
              ? DateTime.fromMillisecondsSinceEpoch(expiresAtMs)
              : null;
          if (expiresAt != null &&
              expiresAt.difference(now).inMilliseconds <=
                  _urlExpiryMarginMs) {
            continue;
          }
          Map<String, String> headers = const {};
          try {
            final decoded = jsonDecode(
                r['headers_json']?.toString() ?? '{}');
            if (decoded is Map) {
              headers = decoded.map((k, v) => MapEntry(
                  k.toString(), v.toString()));
            }
          } catch (_) {}
          final stream = ResolvedStream(
            url: url,
            mimeType: r['mime']?.toString() ?? 'audio/webm',
            bitrateKbps:
                (r['bitrate_kbps'] as num?)?.toInt() ?? 0,
            audioCodec:
                r['codec']?.toString() ?? 'OPUS',
            cacheKey:
                'youtube:$videoId:$clientProfile:$itag:$authScope:$expiresAtMs',
            requestHeaders: headers,
            expiresAt: expiresAt,
          );
          final adaptive = !(stream.mimeType
                  .toLowerCase()
                  .contains('mp4') &&
              itag >= 0 &&
              itag < 300);
          _streamCache[
                  '$videoId|$clientProfile|$itag|$authScope|$expiresAtMs'] =
              _CachedStream(stream, clientProfile, itag,
                  adaptive, authScope,
                  DateTime.fromMillisecondsSinceEpoch(
                      cachedAtMs > 0
                          ? cachedAtMs
                          : now.millisecondsSinceEpoch));
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Warm the single hidden BotGuard WebView early (no UI blocking).
  void preWarmBotGuard() {
    try {
      unawaited(_poTokens?.preWarm());
    } catch (_) {}
  }

  YtConnection get connection => _connection;

  void setConnection(YtConnection c) => _connection = c;

  Future<void> loadPersistedConnection() async {
    final cookies = await _secure.readYtCookies() ?? '';
    if (cookies.isNotEmpty) {
      _connection = YtConnection(
        connected: true,
        cookies: cookies,
        connectedAtMillis:
            DateTime.now().millisecondsSinceEpoch,
      );
    }
  }

  Future<void> connect(String rawCookies) async {
    await _secure.writeYtCookies(rawCookies);
    _connection = YtConnection(
      connected: true,
      cookies: rawCookies,
      connectedAtMillis:
          DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<void> signOut() async {
    await _secure.writeYtCookies(null);
    _connection = const YtConnection();
  }

  // -- auth helpers (mirror YtMusicAuthManager) ------------------------------

  String? _sapisid() {
    final cookies = _connection.cookies;
    if (cookies.isEmpty) return null;
    String? pick(String name) {
      for (final part in cookies.split(';')) {
        final idx = part.indexOf('=');
        if (idx <= 0) continue;
        if (part.substring(0, idx).trim() == name) {
          return part.substring(idx + 1).trim();
        }
      }
      return null;
    }

    return pick('__Secure-3PAPISID') ??
        pick('SAPISID') ??
        pick('APISID');
  }

  String? _cookieHeaderValue() {
    if (_connection.cookies.isEmpty) return null;
    return _connection.cookies;
  }

  String? _authorizationHeaderValue([String? origin]) {
    final sapisid = _sapisid();
    if (sapisid == null) return null;
    return LastFmSigner.sapisidHash(
        sapisid, origin ?? musicOrigin);
  }

  String _playbackAuthScope() {
    if (!_connection.connected) return 'anonymous';
    final digest = sha256
        .convert(utf8.encode(_connection.cookies))
        .bytes
        .take(8)
        .map((b) =>
            (b & 0xff).toRadixString(16).padLeft(2, '0'))
        .join();
    return 'account:${_connection.connectedAtMillis}:$digest';
  }

  // -- bootstrap ---------------------------------------------------------------

  Future<void> _ensureConfig() {
    _configFuture ??= _fetchWebConfig();
    return _configFuture!;
  }

  Future<void> _fetchWebConfig() async {
    try {
      final res = await _dio
          .get<String>(
            '$musicOrigin/',
            options: Options(
              headers: {'User-Agent': webUserAgent},
              responseType: ResponseType.plain,
            ),
          )
          .timeout(const Duration(seconds: 4));
      final html = res.data ?? '';
      final key = _findConfig(html, 'INNERTUBE_API_KEY');
      final version = _findConfig(
          html, 'INNERTUBE_CONTEXT_CLIENT_VERSION');
      final visitor = _findConfig(html, 'VISITOR_DATA');
      if (visitor != null && visitor.isNotEmpty) {
        _visitorData = visitor;
      }
      if (key != null && key.isNotEmpty) _apiKey = key;
      if (version != null && version.isNotEmpty) {
        _clientVersion = version;
      }
      // Persist for instant cold starts (see attachDiskCache).
      try {
        _disk?.kvSet(
            'yt_web_config',
            jsonEncode({
              'apiKey': _apiKey,
              'clientVersion': _clientVersion,
              'visitorData': _visitorData ?? '',
              'savedAtMs':
                  DateTime.now().millisecondsSinceEpoch,
            }));
      } catch (_) {}
    } catch (_) {
      // Keep current values (fallbacks on first run, disk-restored
      // config afterwards) so an offline cold start still plays.
    }
  }

  void _clearWebConfig() {
    _configFuture = null;
  }

  static String? _findConfig(String html, String key) {
    if (html.isEmpty) return null;
    final m = RegExp('"$key"\\s*:\\s*"([^"]+)"')
        .firstMatch(html)
        ?.group(1);
    return m
        ?.replaceAll('\\u003d', '=')
        .replaceAll('\\x3d', '=')
        .replaceAll('\\/', '/');
  }

  // -- request plumbing ----------------------------------------------------------

  Map<String, dynamic> _context(
    String name,
    String version, {
    String? visitorData,
    String? osVersion,
    String? osName,
    String? deviceMake,
    String? deviceModel,
    String? androidSdkVersion,
    String? poToken,
  }) {
    return {
      'client': {
        'clientName': name,
        'clientVersion': version,
        'hl': 'en',
        'gl': 'US',
        if (visitorData != null && visitorData.isNotEmpty)
          'visitorData': visitorData,
        if (osName != null && osName.isNotEmpty)
          'osName': osName,
        if (osVersion != null && osVersion.isNotEmpty)
          'osVersion': osVersion,
        if (deviceMake != null && deviceMake.isNotEmpty)
          'deviceMake': deviceMake,
        if (deviceModel != null && deviceModel.isNotEmpty)
          'deviceModel': deviceModel,
        if (androidSdkVersion != null &&
            androidSdkVersion.isNotEmpty)
          'androidSdkVersion': androidSdkVersion,
      },
      if (poToken != null && poToken.isNotEmpty)
        'serviceIntegrityDimensions': {
          'poToken': poToken,
        },
    };
  }

  Map<String, dynamic> _webContext(String version, String? visitor) =>
      _context('WEB_REMIX', version, visitorData: visitor);

  Future<Map<String, dynamic>> _post(
    String url, {
    required Map<String, dynamic> body,
    required String clientName,
    required String clientVersion,
    required String userAgent,
    bool authenticated = false,
    String? origin,
    String? referer,
    String? visitorData,
    int maxAttempts = 2,
    Duration? callTimeout,
  }) async {
    await _ensureConfig();
    origin ??= clientName == 'WEB_REMIX'
        ? musicOrigin
        : youtubeOrigin;
    referer ??= clientName == 'WEB_REMIX'
        ? '$musicOrigin/'
        : '$youtubeOrigin/';
    final headers = {
      'Content-Type': 'application/json',
      'User-Agent': userAgent,
      'Origin': origin,
      'X-Origin': origin,
      'Referer': referer,
      'X-Goog-Api-Format-Version': '1',
      'X-YouTube-Client-Name':
          clientIds[clientName] ?? clientName,
      'X-YouTube-Client-Version': clientVersion,
      if (visitorData != null && visitorData.isNotEmpty)
        'X-Goog-Visitor-Id': visitorData,
      // Account surface only when requested AND connected â€”
      // anonymous endpoints stay cookie-free.
      if (authenticated && _connection.connected) ...{
        'Cookie': ?_cookieHeaderValue(),
        'Authorization': ?_authorizationHeaderValue(origin),
      },
    };
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final res = await _dio
            .post<String>(
              url,
              data: jsonEncode(body),
              options: Options(
                headers: headers,
                responseType: ResponseType.plain,
              ),
            )
            .timeout(callTimeout ?? const Duration(seconds: 15));
        final data = res.data;
        if (data == null || data.isEmpty) return const {};
        final decoded = jsonDecode(data);
        return decoded is Map<String, dynamic>
            ? decoded
            : const {};
      } on DioException catch (e) {
        lastError = e;
        final code = e.response?.statusCode;
        if (code == 400 || code == 403 || code == 429) {
          _clearWebConfig();
        }
        if (attempt >= maxAttempts ||
            !_isTransient(code, e)) {
          if (code != null) {
            throw InnerTubeHttpException(code);
          }
          rethrow;
        }
        final backoff =
            Duration(milliseconds: 250 * (1 << (attempt - 1)));
        await Future<void>.delayed(
            backoff + Duration(milliseconds: _jitter(180)));
      }
    }
    throw lastError ?? InnerTubeHttpException(0);
  }

  static int _jitter(int maxMs) =>
      maxMs <= 0 ? 0 : Random().nextInt(maxMs + 1);

  static bool _isTransient(int? code, DioException e) {
    if (code == 408 || code == 429) return true;
    if (code != null && code >= 500) return true;
    return e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.sendTimeout;
  }

  // -- search ----------------------------------------------------------------------

  Future<List<YouTubeMusicTrack>> searchSongs(
    String query, {
    int limit = 30,
    bool prefetchStreams = false,
  }) async {
    if (query.trim().isEmpty) return const [];
    await _ensureConfig();
    final root = await _post(
      '$musicApi/search?key=$_apiKey&prettyPrint=false',
      body: {
        'context': _webContext(_clientVersion, _visitorData),
        'query': query.trim(),
        'params': songsSearchFilter,
      },
      clientName: 'WEB_REMIX',
      clientVersion: _clientVersion,
      userAgent: webUserAgent,
    );
    final results = _parseSongRenderers(root).take(limit).toList();
    // Limusic behavior: never prefetch search results. Only the next
    // likely queue track is pre-resolved (see prefetchNextTrack).
    // The flag is kept for API compatibility but ignored.
    return results;
  }

  Future<List<YouTubeMusicEntity>> searchArtists(
    String query, {
    int limit = 30,
  }) =>
      _searchEntities(query, YouTubeEntityKind.artist,
          artistSearchFilter, limit);

  Future<List<YouTubeMusicEntity>> searchAlbums(
    String query, {
    int limit = 30,
  }) =>
      _searchEntities(query, YouTubeEntityKind.album,
          albumSearchFilter, limit);

  Future<List<YouTubeMusicEntity>> _searchEntities(
    String query,
    YouTubeEntityKind kind,
    String filter,
    int limit,
  ) async {
    if (query.trim().isEmpty) return const [];
    await _ensureConfig();
    final root = await _post(
      '$musicApi/search?key=$_apiKey&prettyPrint=false',
      body: {
        'context': _webContext(_clientVersion, _visitorData),
        'query': query.trim(),
        'params': filter,
      },
      clientName: 'WEB_REMIX',
      clientVersion: _clientVersion,
      userAgent: webUserAgent,
    );
    return _parseEntityRenderers(root, kind).take(limit).toList();
  }

  Future<List<YouTubePlaylistSummary>> searchPlaylists(
    String query, {
    int limit = 30,
  }) async {
    if (query.trim().isEmpty) return const [];
    await _ensureConfig();
    Map<String, dynamic>? root;
    try {
      root = await _post(
        '$musicApi/search?key=$_apiKey&prettyPrint=false',
        body: {
          'context':
              _webContext(_clientVersion, _visitorData),
          'query': query.trim(),
          'params': playlistSearchFilter,
        },
        clientName: 'WEB_REMIX',
        clientVersion: _clientVersion,
        userAgent: webUserAgent,
      );
    } catch (_) {
      return const [];
    }
    return _parsePlaylistRenderers(root).take(limit).toList();
  }

  /// YouTube Music autocomplete — not the public YouTube (`ds=yt`)
  /// complete API, which mixes in games, TV, and unrelated videos.
  Future<List<String>> getSuggestions(String query) async {
    final q = query.trim();
    if (q.length < 2) return const [];
    try {
      await _ensureConfig();
      final root = await _post(
        '$musicApi/music/get_search_suggestions?key=$_apiKey&prettyPrint=false',
        body: {
          'context': _webContext(_clientVersion, _visitorData),
          'input': q,
        },
        clientName: 'WEB_REMIX',
        clientVersion: _clientVersion,
        userAgent: webUserAgent,
      );
      final out = <String>[];
      final seen = <String>{};
      void walk(Object? node) {
        if (node is Map) {
          final endpoint = node['searchEndpoint'] ??
              (node['navigationEndpoint'] is Map
                  ? (node['navigationEndpoint'] as Map)['searchEndpoint']
                  : null);
          if (endpoint is Map) {
            final text = endpoint['query']?.toString().trim() ?? '';
            if (text.isNotEmpty && seen.add(text.toLowerCase())) {
              out.add(text);
            }
          }
          for (final v in node.values) {
            walk(v);
          }
        } else if (node is List) {
          for (final v in node) {
            walk(v);
          }
        }
      }

      walk(root['contents'] ?? root);
      return out;
    } catch (_) {
      return const [];
    }
  }

  // -- browse ------------------------------------------------------------------------

  Future<List<YouTubeMusicTrack>> browseSongs(
    String browseId, {
    String? params,
    int? limit,
  }) async {
    if (browseId.trim().isEmpty) {
      throw ArgumentError('Missing YouTube Music browse id');
    }
    await _ensureConfig();
    final root = await _post(
      '$musicApi/browse?key=$_apiKey&prettyPrint=false',
      body: {
        'context': _webContext(_clientVersion, _visitorData),
        'browseId': browseId,
        if (params != null && params.isNotEmpty)
          'params': params,
      },
      clientName: 'WEB_REMIX',
      clientVersion: _clientVersion,
      userAgent: webUserAgent,
    );
    final result = await _collectBrowseSongPages(root, limit);
    return result.tracks;
  }

  /// Browse an album page: header metadata (title/artist/artwork/year)
  /// plus tracks with header metadata inherited where the per-row
  /// renderer omits it (artist, album, artwork) — which is the norm
  /// for single-artist album pages.
  Future<YouTubeAlbumResult?> browseAlbum(
    String browseId, {
    int? limit,
  }) async {
    if (browseId.trim().isEmpty) return null;
    await _ensureConfig();
    Map<String, dynamic> root;
    try {
      root = await _post(
        '$musicApi/browse?key=$_apiKey&prettyPrint=false',
        body: {
          'context': _webContext(_clientVersion, _visitorData),
          'browseId': browseId,
        },
        clientName: 'WEB_REMIX',
        clientVersion: _clientVersion,
        userAgent: webUserAgent,
      );
    } catch (_) {
      return null;
    }
    final header = _playlistHeader(root);
    final title = _extractTitleFromHeader(header, root) ?? '';
    final artist = _albumHeaderArtist(header) ?? '';
    final artwork = _extractArtworkFromHeader(header, root) ?? '';
    var year = '';
    final subtitleRuns =
        ((header?['subtitle']) as Map?)?['runs'];
    if (subtitleRuns is List) {
      for (final run in subtitleRuns.whereType<Map>()) {
        final text = run['text']?.toString().trim() ?? '';
        if (RegExp(r'^\d{4}$').hasMatch(text)) {
          year = text;
          break;
        }
      }
    }
    final pages = await _collectBrowseSongPages(root, limit);
    final tracks = pages.tracks
        .map((t) => YouTubeMusicTrack(
              videoId: t.videoId,
              title: t.title,
              artist: t.artist.isEmpty || t.artist == 'Unknown artist'
                  ? (artist.isNotEmpty ? artist : t.artist)
                  : t.artist,
              album: t.album.isEmpty ? title : t.album,
              artworkUrl: t.artworkUrl.isNotEmpty
                  ? t.artworkUrl
                  : artwork,
              durationSeconds: t.durationSeconds,
            ))
        .toList();
    return YouTubeAlbumResult(
      browseId: browseId,
      title: title,
      artist: artist,
      artworkUrl: artwork,
      year: year,
      tracks: tracks,
    );
  }

  /// Album header subtitle runs look like ["Album", " • ", "Future",
  /// " • ", "2015"] — the artist is the run whose browse endpoint is a
  /// channel (UC…). Falls back to the first non-label run.
  String? _albumHeaderArtist(Map<String, dynamic>? header) {
    if (header == null) return null;
    const labels = {'album', 'single', 'ep', 'song', 'playlist'};
    for (final key in ['subtitle', 'straplineTextOne']) {
      final runs = (header[key] as Map?)?['runs'];
      if (runs is! List) continue;
      // Prefer a run linked to an artist channel.
      for (final run in runs.whereType<Map>()) {
        final bid = ((run['navigationEndpoint'] as Map?)?[
                'browseEndpoint'] as Map?)?['browseId']
            ?.toString();
        if (bid != null && bid.startsWith('UC')) {
          final text = run['text']?.toString().trim() ?? '';
          if (text.isNotEmpty) return text;
        }
      }
      // Otherwise the first run that is not a type label/separator.
      for (final run in runs.whereType<Map>()) {
        final text = run['text']?.toString().trim() ?? '';
        if (text.isEmpty) continue;
        final lower = text.toLowerCase();
        if (labels.contains(lower) ||
            lower == '•' ||
            RegExp(r'^\d{4}$').hasMatch(text)) {
          continue;
        }
        return text;
      }
    }
    return null;
  }

  Future<_BrowsePages> _collectBrowseSongPages(
      Map<String, dynamic> root, int? limit) async {
    final shelves = <Map<String, dynamic>>[];
    _collectObjects(root, 'musicPlaylistShelfRenderer', shelves);
    if (shelves.isEmpty) {
      _collectObjects(root, 'musicShelfRenderer', shelves);
    }
    Map<String, dynamic>? primary;
    for (final shelf in shelves) {
      final heading = _runsText(
          (shelf['title'] as Map?)?['runs']);
      if (heading != null &&
          (heading.toLowerCase() == 'songs' ||
              heading.toLowerCase() == 'tracks')) {
        primary = shelf;
        break;
      }
    }
    primary ??= shelves.isNotEmpty ? shelves.first : null;

    final songs = <YouTubeMusicTrack>[];
    songs.addAll(_parseSongRenderers(primary ?? root));
    if (primary == null) {
      final take = limit ?? songs.length;
      return _BrowsePages(
          songs.take(take).toList(), false);
    }
    var token = _playlistTrackContinuationToken(primary);
    final seenTokens = <String>{};
    final knownIds = songs.map((s) => s.videoId).toSet();
    var page = 0;
    final maxPages =
        limit != null ? min(8, (limit ~/ 20) + 1) : 6;
    while (token != null &&
        token.isNotEmpty &&
        page < maxPages &&
        (limit == null || songs.length < limit)) {
      if (!seenTokens.add(token)) break;
      Map<String, dynamic>? nextPage;
      try {
        nextPage =
            await _browseContinuation(token, authenticated: false);
      } catch (_) {
        break;
      }
      final containers = _playlistTrackContainers(nextPage);
      if (containers.isEmpty) break;
      for (final s in containers.expand(_parseSongRenderers)) {
        if (knownIds.add(s.videoId)) songs.add(s);
      }
      token = containers
          .map(_playlistTrackContinuationToken)
          .firstWhere((t) => t != null && t.isNotEmpty,
              orElse: () => null);
      page++;
    }
    final result =
        limit != null ? songs.take(limit).toList() : songs;
    return _BrowsePages(
        result,
        (token == null || token.isEmpty) &&
            result.length == songs.length);
  }

  /// Anonymous radio for a seed video (cookie-free by design).
  Future<List<YouTubeMusicTrack>> fetchRelatedSongs(
    String videoId, {
    int limit = 30,
    bool prefetchStreams = false,
  }) async {
    if (videoId.trim().isEmpty || limit <= 0) return const [];
    await _ensureConfig();
    final root = await _post(
      '$musicApi/next?key=$_apiKey&prettyPrint=false',
      body: {
        'context': _webContext(_clientVersion, _visitorData),
        'videoId': videoId,
        'playlistId': 'RDAMVM$videoId',
        'params': 'wAEB',
        'isAudioOnly': true,
      },
      clientName: 'WEB_REMIX',
      clientVersion: _clientVersion,
      userAgent: webUserAgent,
      callTimeout: const Duration(seconds: 8),
    );
    final results = _parseSongRenderers(root)
        .where((t) => t.videoId != videoId)
        .take(limit)
        .toList();
    return results;
  }

  /// Rich metadata for a single video ID (player videoDetails,
  /// falling back to oEmbed).
  Future<YouTubeMusicTrack?> fetchSongDetails(
      String videoId) async {
    if (videoId.trim().isEmpty) return null;
    try {
      await _ensureConfig();
      final root = await _post(
        '$musicApi/player?key=$_apiKey&prettyPrint=false',
        body: {
          'context':
              _webContext(_clientVersion, _visitorData),
          'videoId': videoId,
        },
        clientName: 'WEB_REMIX',
        clientVersion: _clientVersion,
        userAgent: webUserAgent,
      );
      final details = root['videoDetails'] as Map?;
      var title = details?['title']?.toString();
      var artist = details?['author']?.toString() ?? '';
      final duration = int.tryParse(
              details?['lengthSeconds']?.toString() ?? '') ??
          0;
      final thumbs =
          (details?['thumbnail'] as Map?)?['thumbnails'];
      String? artwork;
      if (thumbs is List && thumbs.isNotEmpty) {
        artwork = (thumbs.last as Map?)?['url']?.toString();
      }
      if (title != null &&
          title.isNotEmpty &&
          artist.isNotEmpty) {
        if (artist.endsWith(' - Topic')) {
          artist =
              artist.substring(0, artist.length - 8).trim();
        }
        if (title.contains(' - ')) {
          final parts = title.split(' - ');
          final head = parts.first.trim();
          if (artist.isEmpty ||
              artist == 'YouTube Music' ||
              artist.toLowerCase() == head.toLowerCase()) {
            artist = head;
            title = parts.sublist(1).join(' - ').trim();
          }
        }
        return YouTubeMusicTrack(
          videoId: videoId,
          title: title,
          artist: artist,
          artworkUrl: artwork ??
              'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
          durationSeconds: duration,
        );
      }
    } catch (_) {}
    try {
      final res = await _dio.get<String>(
        'https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v=$videoId&format=json',
        options: Options(headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
        }),
      );
      final obj = jsonDecode(res.data ?? '{}');
      if (obj is! Map<String, dynamic>) return null;
      final rawTitle = obj['title']?.toString() ?? '';
      var author =
          (obj['author_name']?.toString() ?? '').trim();
      if (author.endsWith(' - Topic')) {
        author = author.substring(0, author.length - 8).trim();
      }
      final thumbnail = obj['thumbnail_url']?.toString() ??
          'https://i.ytimg.com/vi/$videoId/hqdefault.jpg';
      var finalTitle = rawTitle;
      var finalArtist =
          author.isEmpty ? 'YouTube Music' : author;
      if (rawTitle.contains(' - ')) {
        final parts = rawTitle.split(' - ');
        finalArtist = parts.first.trim();
        finalTitle = parts.sublist(1).join(' - ').trim();
      }
      if (finalTitle.isEmpty) return null;
      return YouTubeMusicTrack(
        videoId: videoId,
        title: finalTitle,
        artist: finalArtist,
        artworkUrl: thumbnail,
      );
    } catch (_) {
      return null;
    }
  }

  // -- playlists -----------------------------------------------------------------------

  String extractPlaylistId(String input) {
    final clean = input.trim();
    if (clean.contains('list=')) {
      return clean
          .split('list=')
          .sublist(1)
          .join('list=')
          .split('&')
          .first
          .split('#')
          .first;
    }
    if (clean.contains('playlist/')) {
      return clean
          .split('playlist/')
          .sublist(1)
          .join('playlist/')
          .split('?')
          .first
          .split('/')
          .first;
    }
    return clean;
  }

  String _playlistBrowseId(String rawId) {
    if (rawId.startsWith('VL') ||
        rawId.startsWith('RDCLAK') ||
        rawId.startsWith('FE') ||
        rawId.startsWith('MPRE') ||
        rawId.startsWith('UC')) {
      return rawId;
    }
    return 'VL$rawId';
  }

  Future<YouTubePlaylistResult?> fetchPlaylist(
    String playlistIdOrUrl, {
    int? maxTracks,
  }) async {
    final rawId = extractPlaylistId(playlistIdOrUrl);
    if (rawId.isEmpty) return null;
    final browseId = _playlistBrowseId(rawId);
    final rootResult = await _fetchPlaylistRoot(browseId);
    if (rootResult == null) return null;
    final root = rootResult.root;
    final authenticatedAs = rootResult.authenticated;
    final header = _playlistHeader(root);
    final title = _extractTitleFromHeader(header, root);
    String? author;
    if (header is Map<String, dynamic>) {
      author = _firstRunText(header['subtitle']) ??
          _firstRunText(header['straplineTextOne']) ??
          _findFirstAuthor(header);
    } else {
      author = _findFirstAuthor(header);
    }
    final artworkUrl = _extractArtworkFromHeader(header, root);
    final trackLimit =
        maxTracks != null && maxTracks >= 1 ? maxTracks : null;
    final playlistPage = browseId.startsWith('VL');
    List<Object?> containersFor(Object? page) => playlistPage
        ? _playlistTrackContainers(page)
        : [page];
    final containers = containersFor(root);
    if (containers.isEmpty) return null;
    final songs = <YouTubeMusicTrack>[];
    final knownIds = <String>{};
    for (final s in containers.expand(_parseSongRenderers)) {
      if (knownIds.add(s.videoId)) songs.add(s);
    }
    var limited = trackLimit != null
        ? songs.take(trackLimit).toList()
        : List<YouTubeMusicTrack>.of(songs);
    String? token = _continuationToken(containers, playlistPage);
    final seenTokens = <String>{};
    var page = 0;
    while (token != null &&
        token.isNotEmpty &&
        page < _maxContinuationPages &&
        (trackLimit == null || songs.length < trackLimit)) {
      if (!seenTokens.add(token)) return null;
      Map<String, dynamic>? nextPage;
      try {
        nextPage = await _browseContinuation(token,
            authenticated: authenticatedAs);
      } catch (_) {
        return null;
      }
      final pageContainers = containersFor(nextPage);
      if (pageContainers.isEmpty) return null;
      for (final s in pageContainers.expand(_parseSongRenderers)) {
        if (knownIds.add(s.videoId)) songs.add(s);
      }
      if (trackLimit != null) {
        limited = songs.take(trackLimit).toList();
      } else {
        limited = List.of(songs);
      }
      token = _continuationToken(pageContainers, playlistPage);
      page++;
    }
    if (token != null &&
        token.isNotEmpty &&
        (trackLimit == null || songs.length < trackLimit)) {
      return null;
    }
    return YouTubePlaylistResult(
      id: rawId,
      title: title ?? '',
      author: author ?? '',
      artworkUrl: artworkUrl ?? '',
      trackCount: songs.length,
      tracks: limited,
    );
  }

  Future<String?> fetchPlaylistArtwork(
      String playlistIdOrUrl) async {
    final rawId = extractPlaylistId(playlistIdOrUrl);
    if (rawId.isEmpty) return null;
    final rootResult =
        await _fetchPlaylistRoot(_playlistBrowseId(rawId));
    if (rootResult == null) return null;
    return _extractArtworkFromHeader(
            _playlistHeader(rootResult.root), rootResult.root) ??
        _parseSongRenderers(rootResult.root)
            .map((s) => s.artworkUrl)
            .firstWhere((u) => u.isNotEmpty,
                orElse: () => '');
  }

  Future<_PlaylistRoot?> _fetchPlaylistRoot(
      String browseId) async {
    if (_connection.connected) {
      try {
        final root =
            await _browseRoot(browseId, authenticated: true);
        return _PlaylistRoot(root, true);
      } catch (_) {}
    }
    try {
      final root =
          await _browseRoot(browseId, authenticated: false);
      return _PlaylistRoot(root, false);
    } catch (_) {
      return null;
    }
  }

  Future<_Map> _browseRoot(String browseId,
      {required bool authenticated}) async {
    await _ensureConfig();
    return _post(
      '$musicApi/browse?key=$_apiKey&prettyPrint=false',
      body: {
        'context': _webContext(_clientVersion, _visitorData),
        'browseId': browseId,
      },
      clientName: 'WEB_REMIX',
      clientVersion: _clientVersion,
      userAgent: webUserAgent,
      authenticated: authenticated,
    );
  }

  Future<_Map> _browseContinuation(String token,
      {required bool authenticated}) async {
    await _ensureConfig();
    return _post(
      '$musicApi/browse?key=$_apiKey&prettyPrint=false',
      body: {
        'context': _webContext(_clientVersion, _visitorData),
        'continuation': token,
      },
      clientName: 'WEB_REMIX',
      clientVersion: _clientVersion,
      userAgent: webUserAgent,
      authenticated: authenticated,
    );
  }

  String? _continuationToken(
      List<Object?> containers, bool playlistPage) {
    for (final c in containers) {
      final t = playlistPage
          ? _playlistTrackContinuationToken(c)
          : _genericContinuationToken(c);
      if (t != null && t.isNotEmpty) return t;
    }
    return null;
  }

  List<Object?> _playlistTrackContainers(Object? root) {
    final shelves = <Map<String, dynamic>>[];
    _collectObjects(root, 'musicPlaylistShelfRenderer', shelves);
    _collectObjects(
        root, 'musicPlaylistShelfContinuation', shelves);
    _collectObjects(root, 'playlistVideoListRenderer', shelves);
    _collectObjects(
        root, 'playlistVideoListContinuation', shelves);
    if (shelves.isNotEmpty) return shelves;
    final musicShelves = <Map<String, dynamic>>[];
    _collectObjects(root, 'musicShelfRenderer', musicShelves);
    for (final shelf in musicShelves) {
      if (_parseSongRenderers(shelf).isNotEmpty) {
        return [shelf];
      }
    }
    if (root is Map) {
      final conts = root['continuationContents'];
      if (conts is Map &&
          conts['musicShelfContinuation'] is Map) {
        return [conts['musicShelfContinuation']!];
      }
    }
    final out = <Object?>[];
    for (final key in [
      'onResponseReceivedActions',
      'onResponseReceivedEndpoints',
      'onResponseReceivedCommands'
    ]) {
      final arr = root is Map ? root[key] : null;
      if (arr is! List) continue;
      for (final action in arr) {
        if (action is! Map) continue;
        final items = (action['appendContinuationItemsAction']
                as Map?)?['continuationItems'] ??
            (action['reloadContinuationItemsCommand']
                as Map?)?['continuationItems'];
        if (items != null) out.add(items);
      }
    }
    return out;
  }

  String? _firstRunText(Object? node) {
    if (node is! Map) return null;
    final runs = node['runs'];
    if (runs is! List || runs.isEmpty) return null;
    final first = runs.first;
    if (first is! Map) return null;
    final text = first['text']?.toString();
    return (text != null && text.isNotEmpty) ? text : null;
  }

  String? _playlistTrackContinuationToken(Object? container) {
    final contents = container is List
        ? container
        : (container is Map
            ? container['contents'] as List?
            : null);
    Object? last;
    if (contents != null && contents.isNotEmpty) {
      last = contents.last;
    }
    Map<String, dynamic>? endpoint;
    if (last is Map<String, dynamic>) {
      final cont = (last['continuationItemRenderer']
          as Map?)?['continuationEndpoint'];
      if (cont is Map<String, dynamic>) endpoint = cont;
    }
    if (endpoint != null) {
      final commands = <Map<String, dynamic>>[];
      _collectObjects(endpoint, 'continuationCommand', commands);
      for (final command in commands) {
        final token = command['token']?.toString();
        final request = command['request']?.toString();
        if (token != null &&
            token.isNotEmpty &&
            (request == null ||
                request == 'CONTINUATION_REQUEST_TYPE_BROWSE')) {
          return token;
        }
      }
    }
    if (container is Map) {
      final conts = container['continuations'];
      if (conts is List) {
        for (final c in conts) {
          final token = (c is Map
                  ? (c['nextContinuationData'] as Map?)
                  : null)?['continuation']
              ?.toString();
          if (token != null && token.isNotEmpty) return token;
        }
      }
    }
    return null;
  }

  String? _genericContinuationToken(Object? root) {
    final commands = <Map<String, dynamic>>[];
    _collectObjects(root, 'continuationCommand', commands);
    for (final cmd in commands) {
      final token = cmd['token']?.toString();
      if (token != null && token.isNotEmpty) return token;
    }
    return null;
  }

  Map<String, dynamic>? _playlistHeader(Object? root) {
    Map<String, dynamic>? firstHeader(List<String> keys) {
      for (final k in keys) {
        final found = <Map<String, dynamic>>[];
        _collectObjects(root, k, found);
        if (found.isNotEmpty) return found.first;
      }
      return null;
    }

    if (root is Map<String, dynamic>) {
      final header = root['header'];
      if (header is Map<String, dynamic>) {
        Map<String, dynamic>? at(List<String> path) {
          Object? node = header;
          for (final p in path) {
            node = node is Map ? node[p] : null;
          }
          return node is Map<String, dynamic> ? node : null;
        }

        return at(['musicDetailHeaderRenderer']) ??
            at(['musicResponsiveHeaderRenderer']) ??
            at([
              'musicEditablePlaylistDetailHeaderRenderer',
              'header',
              'musicResponsiveHeaderRenderer'
            ]) ??
            at([
              'musicEditablePlaylistDetailHeaderRenderer',
              'header',
              'musicDetailHeaderRenderer'
            ]) ??
            at(['musicEditablePlaylistDetailHeaderRenderer']) ??
            at(['musicVisualHeaderRenderer']) ??
            at(['musicHeaderRenderer']) ??
            at(['playlistHeaderRenderer']) ??
            firstHeader([
              'musicResponsiveHeaderRenderer',
              'musicDetailHeaderRenderer',
              'musicEditablePlaylistDetailHeaderRenderer',
              'musicVisualHeaderRenderer',
              'musicHeaderRenderer',
            ]);
      }
    }
    return firstHeader([
      'musicResponsiveHeaderRenderer',
      'musicDetailHeaderRenderer',
      'musicEditablePlaylistDetailHeaderRenderer',
      'musicVisualHeaderRenderer',
      'musicHeaderRenderer',
    ]);
  }

  String? _extractTitleFromHeader(
      Map<String, dynamic>? header, Object? root) {
    if (header != null) {
      final runs =
          (header['title'] as Map?)?['runs'];
      if (runs is List) {
        final text = runs
            .whereType<Map>()
            .map((r) => r['text']?.toString() ?? '')
            .join()
            .trim();
        if (text.isNotEmpty) return text;
      }
      Map<String, dynamic>? nestedHeader() {
        final h = header['header'];
        if (h is! Map) return null;
        for (final k in [
          'musicResponsiveHeaderRenderer',
          'musicDetailHeaderRenderer'
        ]) {
          if (h[k] is Map<String, dynamic>) {
            return h[k] as Map<String, dynamic>;
          }
        }
        return h is Map<String, dynamic> ? h : null;
      }

      final nested = nestedHeader();
      if (nested != null) {
        final runs2 =
            (nested['title'] as Map?)?['runs'];
        if (runs2 is List) {
          final text = runs2
              .whereType<Map>()
              .map((r) => r['text']?.toString() ?? '')
              .join()
              .trim();
          if (text.isNotEmpty) return text;
        }
      }
      final simple =
          (header['title'] as Map?)?['simpleText']?.toString() ??
              header['title']?.toString();
      if (simple != null && simple.isNotEmpty) {
        return simple.trim();
      }
    }
    final titles = <Map<String, dynamic>>[];
    _collectObjects(
        root, 'musicResponsiveHeaderRenderer', titles);
    for (final h in titles) {
      final runs = (h['title'] as Map?)?['runs'];
      if (runs is List) {
        final text = runs
            .whereType<Map>()
            .map((r) => r['text']?.toString() ?? '')
            .join()
            .trim();
        if (text.isNotEmpty) return text;
      }
    }
    return null;
  }

  String? _findFirstAuthor(Map<String, dynamic>? header) {
    if (header == null) return null;
    for (final k in [
      'subtitle',
      'straplineTextOne',
      'secondSubtitle'
    ]) {
      final runs = (header[k] as Map?)?['runs'];
      if (runs is List && runs.isNotEmpty) {
        final text =
            (runs.first as Map?)?['text']?.toString();
        if (text != null && text.isNotEmpty) return text;
      }
    }
    return null;
  }

  String? _extractArtworkFromHeader(
      Map<String, dynamic>? header, Object? root) {
    if (header != null) {
      final direct = _extractThumbnailsUrl(header);
      if (direct != null) return direct;
    }
    for (final k in [
      'musicResponsiveHeaderRenderer',
      'musicDetailHeaderRenderer',
      'musicEditablePlaylistDetailHeaderRenderer',
      'musicVisualHeaderRenderer',
      'musicThumbnailRenderer',
    ]) {
      final found = <Map<String, dynamic>>[];
      _collectObjects(root, k, found);
      for (final f in found) {
        final url = _extractThumbnailsUrl(f);
        if (url != null) return url;
      }
    }
    return null;
  }

  // -- album grids (desktop helper over shared parsers) --------------------------

  Future<List<YouTubeMusicEntity>> browseAlbums(
    String browseId, {
    int limit = 30,
  }) async {
    await _ensureConfig();
    final root = await _post(
      '$musicApi/browse?key=$_apiKey&prettyPrint=false',
      body: {
        'context': _webContext(_clientVersion, _visitorData),
        'browseId': browseId,
      },
      clientName: 'WEB_REMIX',
      clientVersion: _clientVersion,
      userAgent: webUserAgent,
    );
    final out = <YouTubeMusicEntity>[];
    final queue = <Object?>[root];
    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      if (current is Map<String, dynamic>) {
        if (current.containsKey('musicTwoRowItemRenderer')) {
          final entity = _parseTwoRowEntity(current[
              'musicTwoRowItemRenderer'] as Map<String, dynamic>);
          if (entity != null) out.add(entity);
        } else {
          queue.addAll(current.values.take(300));
        }
      } else if (current is List) {
        queue.addAll(current.take(300));
      }
      if (out.length >= limit) break;
    }
    return out.take(limit).toList();
  }

  YouTubeMusicEntity? _parseTwoRowEntity(
      Map<String, dynamic> r) {
    final titleObj = r['title'];
    String name = '';
    if (titleObj is Map) {
      name = titleObj['text']?.toString() ??
          _runsText(titleObj['runs']) ??
          '';
    }
    final subtitleObj = r['subtitle'];
    String subtitle = '';
    if (subtitleObj is Map) {
      subtitle = subtitleObj['text']?.toString() ??
          _runsText(subtitleObj['runs']) ??
          '';
    }
    String browseId = '';
    String playlistId = '';
    final nav = r['navigationEndpoint'];
    if (nav is Map) {
      final browse = nav['browseEndpoint'];
      if (browse is Map) {
        browseId = browse['browseId']?.toString() ?? '';
      }
      final watch = nav['watchEndpoint'];
      if (watch is Map) {
        playlistId =
            watch['playlistId']?.toString() ?? '';
      }
    }
    if (name.isEmpty) return null;
    if (browseId.isEmpty && playlistId.isEmpty) return null;
    return YouTubeMusicEntity(
      kind: YouTubeEntityKind.album,
      name: name,
      subtitle: subtitle,
      browseId: browseId,
      playlistId: playlistId,
      artworkUrl: _extractThumbnailsUrl(r) ?? '',
    );
  }

  static List<String> splitSubtitle(String subtitle) =>
      subtitle.split('â€¢').map((s) => s.trim()).toList();

  // -- matching (mirror Android exactly) --------------------------------------------

  static String normalize(String s) {
    // NFD first (like Android Normalizer.Form.NFD), so precomposed
    // characters decompose and diacritics can be stripped.
    var v = unorm.nfd(s.toLowerCase());
    v = v.replaceAll(_diacritics, '');
    v = v.replaceAll(_nonWord, ' ');
    v = v.trim().replaceAll(_multiSpace, ' ');
    return v;
  }

  static Set<String> _tokens(String value) => normalize(value)
      .split(' ')
      .where((t) => t.isNotEmpty && !_matchNoiseWords.contains(t))
      .toSet();

  static String baseTitle(String value) => value
      .replaceAll(_featuringClause, ' ')
      .replaceAll(_versionClause, ' ');

  /// Token-Dice similarity with substring fast-path (0â€“100).
  static int similarity(String a, String b) {
    final normA = normalize(a);
    final normB = normalize(b);
    if (normA == normB) return 100;
    if (normA.isNotEmpty && normB.isNotEmpty) {
      if (normA.contains(normB) || normB.contains(normA)) {
        final shorter = min(normA.length, normB.length);
        final longer = max(normA.length, normB.length);
        final ratio = (shorter * 100) ~/ longer;
        // Short titles ("Cider" in "Cinderella", "Piranha" in
        // "Wisakda Me (Piranha, Pt. 2)") must not count as the same song.
        if (shorter >= 8 && ratio >= 70) return max(85, ratio);
      }
    }
    final left = _tokens(a);
    final right = _tokens(b);
    if (left.isEmpty || right.isEmpty) return 0;
    final common = left.intersection(right).length;
    final dice = (200 * common) ~/ (left.length + right.length);
    final shorterCount = min(left.length, right.length);
    final subset =
        (common == shorterCount && common > 0 && shorterCount >= 2)
            ? 80
            : 0;
    return max(dice, subset);
  }

  static int matchScore(
      YouTubeMusicTrack candidate, String title, String artist) {
    final wantedTitle = normalize(title);
    final wantedArtist = normalize(artist);
    final candidateTitle = normalize(candidate.title);
    final candidateArtist = normalize(candidate.artist);
    var score = max(
            similarity(candidate.title, title),
            similarity(
                baseTitle(candidate.title), baseTitle(title))) *
        5 +
        similarity(candidate.artist, artist) * 3;
    if (candidateTitle == wantedTitle) score += 600;
    if (wantedArtist.isNotEmpty &&
        candidateArtist == wantedArtist) {
      score += 350;
    }
    final wantedVariants = _tokens(title).intersection(_variantWords);
    final unexpected = _tokens(candidate.title)
        .intersection(_variantWords)
        .difference(wantedVariants);
    score -= unexpected.length * 250;
    return score;
  }

  static String highResolutionArtwork(String url) {
    var u = url.startsWith('//') ? 'https:$url' : url;
    if ((u.contains('googleusercontent.com') ||
            u.contains('ggpht.com')) &&
        u.contains('=')) {
      u = '${u.substring(0, u.lastIndexOf('='))}=w512-h512-l90-rj';
    }
    return u;
  }

  static int? parseDuration(String value) {
    var cleaned = value.trim();
    if (cleaned.isEmpty) return null;
    cleaned = cleaned.replaceAll(
        RegExp(r'[\u200e\u200f\u202a-\u202e\u2066-\u2069]'), '');
    cleaned = cleaned.replaceAll('：', ':').trim();
    final match = RegExp(r'(\d{1,2}:)+\d{2}').firstMatch(cleaned);
    final token = match?.group(0) ?? cleaned;
    final parts = token.split(':').map(int.tryParse).toList();
    if (parts.isEmpty || parts.any((e) => e == null)) return null;
    final nums = parts.whereType<int>().toList();
    if (nums.length < 2 || nums.length > 3) return null;
    var total = 0;
    for (final n in nums) {
      total = total * 60 + n;
    }
    if (total <= 0 || total > 24 * 3600) return null;
    return total;
  }

  static bool _isUsefulDetail(String value) {
    final v = value.trim();
    return v.isNotEmpty && !{'â€¢', 'Â·', 'Song', 'Video'}.contains(v);
  }

  static bool _isLikelyArtistDetail(String value) {
    final v = value.trim();
    if (!_isUsefulDetail(v)) return false;
    final lower = v.toLowerCase();
    if (lower == 'album' ||
        lower == 'single' ||
        lower == 'ep' ||
        lower == 'playlist') {
      return false;
    }
    if (parseDuration(v) != null) return false;
    if (RegExp(r'^(19|20)\d{2}$').hasMatch(v)) return false;
    if (lower.contains(' view') || lower.contains(' song')) {
      return false;
    }
    return true;
  }

  /// Best match (throws [NoReliableMatchException] like Android's
  /// IOException when nothing is reliable).
  Future<YouTubeMusicTrack> findBestMatch(
    String title,
    String artist, {
    bool prefetchStreams = false,
    Set<String> excludedVideoIds = const {},
  }) async {
    final cacheKey = '${normalize(artist)}|${normalize(title)}';
    final cached = _matchCache[cacheKey];
    if (cached != null &&
        !excludedVideoIds.contains(cached.videoId) &&
        cached.durationSeconds > 0) {
      return cached;
    }
    // Persistent match cache: instant reuse across restarts.
    if (excludedVideoIds.isEmpty) {
      try {
        final disk = _disk?.loadMatchEntry(cacheKey);
        if (disk != null) {
          final dv = disk['video_id']?.toString() ?? '';
          if (dv.isNotEmpty) {
            final duration = (disk['duration_seconds'] as num?)?.toInt() ?? 0;
            final track = YouTubeMusicTrack(
              videoId: dv,
              title: disk['title']?.toString() ?? title,
              artist: disk['artist']?.toString() ?? artist,
              album: disk['album']?.toString() ?? '',
              artworkUrl:
                  disk['artwork_url']?.toString() ?? '',
              durationSeconds: duration,
            );
            if (duration > 0) {
              _matchCache[cacheKey] = track;
              return track;
            }
          }
        }
      } catch (_) {}
    }
    final results = await searchSongs('$title $artist',
        limit: 30, prefetchStreams: false);
    YouTubeMusicTrack? best;
    var bestScore = -1 << 30;
    for (final c in results) {
      if (c.videoId.isEmpty ||
          excludedVideoIds.contains(c.videoId)) {
        continue;
      }
      final titleSim = max(similarity(c.title, title),
          similarity(baseTitle(c.title), baseTitle(title)));
      if (titleSim < 72) continue;
      if (artist.trim().isNotEmpty &&
          similarity(c.artist, artist) < 50) {
        continue;
      }
      final score = matchScore(c, title, artist);
      if (score > bestScore) {
        bestScore = score;
        best = c;
      }
    }
    if (best == null) {
      throw NoReliableMatchException(
          'No reliable YouTube Music match found for $title by $artist');
    }
    if (_matchCache.length > _maxMatchCacheEntries) {
      _matchCache.clear();
    }
    _matchCache[cacheKey] = best;
    // Persist for instant reuse (disk cache).
    try {
      _disk?.saveMatchEntry(
        key: cacheKey,
        videoId: best.videoId,
        title: best.title,
        artist: best.artist,
        album: best.album,
        artworkUrl: best.artworkUrl,
        durationSeconds: best.durationSeconds,
      );
    } catch (_) {}
    return best;
  }

  Future<YouTubeMusicTrack?> findBestMatchOrNull(
    String title,
    String artist, {
    bool prefetchStreams = false,
    Set<String> excludedVideoIds = const {},
  }) async {
    try {
      return await findBestMatch(title, artist,
          prefetchStreams: prefetchStreams,
          excludedVideoIds: excludedVideoIds);
    } catch (_) {
      return null;
    }
  }

  void rememberMatch(YouTubeMusicTrack track,
      {String? title, String? artist}) {
    if (track.videoId.isEmpty) return;
    final cacheKey =
        '${normalize(artist ?? track.artist)}|${normalize(title ?? track.title)}';
    _matchCache[cacheKey] = track;
    try {
      _disk?.saveMatchEntry(
        key: cacheKey,
        videoId: track.videoId,
        title: track.title,
        artist: track.artist,
        album: track.album,
        artworkUrl: track.artworkUrl,
        durationSeconds: track.durationSeconds,
      );
    } catch (_) {}
  }

  Future<bool> isPlayable(String title, String artist) async =>
      await findBestMatchOrNull(title, artist) != null;

  void invalidateCache(String videoId) {
    _streamCache.removeWhere((k, _) => k.startsWith('$videoId|'));
    _matchCache.removeWhere((_, v) => v.videoId == videoId);
    _inflight.removeWhere((k, _) => k.startsWith('$videoId|'));
    try {
      _disk?.deleteStreamEntries(videoId);
      _disk?.deleteMatchesForVideo(videoId);
    } catch (_) {}
  }

  // -- stream resolution (Limusic fast path) -------------------------------
  //
  // - Reuse cached URLs until expiry or a real 403 (no blocking probes).
  // - Single-flight dedup via _inflight.
  // - Only the next queue track is pre-resolved (prefetchNextTrack).

  void prefetchStream(String videoId) {
    prefetchNextTrack(videoId);
  }

  /// Background pre-resolve for exactly one videoId (the next likely
  /// queue track). Deduped via the same single-flight map as playback,
  /// never blocks playback, never fans out.
  void prefetchNextTrack(String videoId) {
    if (videoId.isEmpty) return;
    final authScope = _playbackAuthScope();
    if (peekCachedStream(videoId) != null) return;
    final requestKey = '$videoId|$authScope';
    if (_inflight.containsKey(requestKey)) return;
    unawaited(resolveAudioStream(videoId).then(
      (_) {},
      onError: (_) {},
    ));
  }

  /// Non-network freshness peek used for instant playback decisions.
  ResolvedStream? peekCachedStream(String videoId) {
    if (videoId.isEmpty) return null;
    final authScope = _playbackAuthScope();
    final now = DateTime.now();
    _CachedStream? freshest;
    for (final e in _streamCache.values) {
      if (e.stream.url.isEmpty) continue;
      // Key prefix check via cacheKey (youtube:videoId:...).
      if (!e.stream.cacheKey.contains(videoId)) continue;
      if (e.authScope != authScope) continue;
      if (!_isFresh(e, now)) continue;
      if (freshest == null ||
          e.cachedAt.isAfter(freshest.cachedAt)) {
        freshest = e;
      }
    }
    return freshest?.stream;
  }

  Future<ResolvedStream?> resolveAudioStream(
      String videoId,
      {bool forceRefresh = false}) async {
    if (videoId.isEmpty) return null;
    final authScope = _playbackAuthScope();
    final now = DateTime.now();
    if (!forceRefresh) {
      final peek = peekCachedStream(videoId);
      if (peek != null) {
        _logStream('cache-hit',
            videoId: videoId,
            mime: peek.mimeType,
            expiry: _expiryState(peek.expiresAt));
        return peek;
      }
      // Drop only truly expired entries; keep the rest for fallback.
      _streamCache.removeWhere((_, c) =>
          c.stream.cacheKey.contains(videoId) &&
          !_isFresh(c, now));
    } else {
      _streamCache.removeWhere((k, _) => k.startsWith('$videoId|'));
    }
    final requestKey = '$videoId|$authScope';
    if (_inflight.containsKey(requestKey)) {
      return _inflight[requestKey];
    }
    final future = _resolveAudioStreamInternal(videoId, authScope);
    _inflight[requestKey] = future;
    try {
      return await future;
    } finally {
      _inflight.remove(requestKey);
    }
  }

  Future<ResolvedStream?> _resolveAudioStreamInternal(
      String videoId, String authScope) async {
    // Limusic fast path: direct-URL clients (VISIONOS, ANDROID_VR…)
    // need neither the signature decipher nor poTokens. Both are
    // created LAZILY inside ensureAux() — only when a ciphered
    // fallback (WEB_REMIX/EMBEDDED/MWEB) is actually reached — so the
    // common case opens zero WebViews and mints zero tokens.
    try {
      await _ensureConfig().timeout(const Duration(seconds: 4));
    } catch (_) {}
    PlayerScript? script;
    int? sts;
    String? playerPoToken;
    String? gvsPoToken;
    var auxReady = false;
    Future<void> ensureAux() async {
      if (auxReady) return;
      auxReady = true;
      try {
        final results = await Future.wait([
          _decipher
              .scriptFor(videoId)
              .timeout(const Duration(seconds: 8))
              .then<PlayerScript?>((s) => s, onError: (_) => null),
          _mintPoToken(videoId),
        ]).timeout(const Duration(seconds: 9));
        script = results[0] as PlayerScript?;
        sts = script?.sts;
        final po = results[1] as PoTokenResult?;
        playerPoToken = po?.playerToken;
        gvsPoToken =
            (po?.sessionToken.isNotEmpty ?? false) ? po?.sessionToken : null;
      } catch (_) {}
    }

    final available = _orderedFastClients(videoId);
    if (available.isEmpty) {
      _logStream('resolve-failed',
          videoId: videoId, detail: 'all clients cooling down');
      return null;
    }

    for (var i = 0; i < available.length; i++) {
      final client = available[i];
      final needsCipher = client.name == 'WEB_REMIX' ||
          client.name == 'WEB_EMBEDDED_PLAYER' ||
          client.name == 'MWEB';
      if (needsCipher) {
        await ensureAux();
      }
      try {
        final candidate = await _resolveDirectClientStream(
          videoId: videoId,
          client: client,
          visitorData: _visitorData,
          signatureTimestamp: sts,
          script: script,
          playerPoToken: playerPoToken,
          gvsPoToken:
              gvsPoToken != null && _visitorData != null ? gvsPoToken : null,
          authScope: authScope,
        ).timeout(_fastClientTimeout);
        if (candidate != null) {
          _lastSuccessfulClientName = client.name;
          _cacheResolvedStream(
              videoId, candidate, client.key, authScope, DateTime.now());
          _lastResolved[videoId] =
              _ResolvedRef(client.key, authScope);
          _logStream('resolved',
              videoId: videoId,
              client: client.key,
              itag: candidate.itag,
              mime: candidate.stream.mimeType,
              expiry:
                  _expiryState(candidate.stream.expiresAt));
          return candidate.stream;
        }
      } catch (e) {
        _failedClientsUntil[
                '$videoId|${client.key}|$authScope'] =
            DateTime.now()
                .add(Duration(milliseconds: _clientCooldownMs));
        _logStream('client-resolve-failed',
            videoId: videoId,
            client: client.key,
            detail: e.runtimeType.toString());
        if (e is ConfirmedUnplayableMediaException) {
          return null;
        }
        continue;
      }
    }
    return null;
  }

  /// Preferred client first (VISIONOS), then last-successful, then the
  /// Remaining clients are tried only after earlier clients fail, including
  /// the browser clients that can use the existing signature and token flow.
  List<PlayerClient> _orderedFastClients(String videoId) {
    final order = <PlayerClient>[];
    void add(String name) {
      for (final c in playerClients) {
        if (c.name == name &&
            !_isCooling(videoId, c.key) &&
            !order.any((e) => e.key == c.key)) {
          order.add(c);
          break;
        }
      }
    }

    add(_fastPreferredClient);
    if (_lastSuccessfulClientName != null &&
        _lastSuccessfulClientName != _fastPreferredClient) {
      add(_lastSuccessfulClientName!);
    }
    for (final c in playerClients) {
      if (!_isCooling(videoId, c.key) &&
          !order.any((e) => e.key == c.key)) {
        order.add(c);
      }
    }
    return order;
  }

  /// Mint poTokens for [videoId] (fail-open null, like Android).
  Future<PoTokenResult?> _mintPoToken(String videoId) async {
    final engine = _poTokens;
    if (engine == null) return null;
    try {
      return await engine
          .mintToken(videoId,
              sessionId: _visitorData ?? 'lastwave_session')
          .timeout(const Duration(seconds: 12));
    } catch (_) {
      return null;
    }
  }

  Future<_Candidate?> _resolveDirectClientStream({
    required String videoId,
    required PlayerClient client,
    required String? visitorData,
    required int? signatureTimestamp,
    required PlayerScript? script,
    required String? playerPoToken,
    required String? gvsPoToken,
    required String authScope,
  }) async {
    final body = {
      'context': _context(
        client.name,
        client.version,
        visitorData: visitorData,
        osName: client.osName,
        osVersion: client.osVersion,
        deviceMake: client.deviceMake,
        deviceModel: client.deviceModel,
        androidSdkVersion: client.androidSdkVersion,
        poToken: playerPoToken,
      ),
      'videoId': videoId,
      'contentCheckOk': true,
      'racyCheckOk': true,
      if (signatureTimestamp != null)
        'playbackContext': {
          'contentPlaybackContext': {
            'signatureTimestamp': signatureTimestamp,
          },
        },
    };
    final playerApi =
        client.name == 'WEB_REMIX' ? musicApi : youtubeApi;
    final root = await _post(
      '$playerApi/player?key=${client.apiKey}&prettyPrint=false',
      body: body,
      clientName: client.name,
      clientVersion: client.version,
      userAgent: client.userAgent,
      authenticated:
          client.name == 'WEB_REMIX' && _connection.connected,
      origin: client.origin,
      referer: client.referer,
      visitorData: visitorData,
      maxAttempts: _maxPlayerRequestAttempts,
    );
    final status = root['playabilityStatus'] as Map?;
    final state = status?['status']?.toString();
    if (state != 'OK') {
      final reason = status?['reason']?.toString() ?? '';
      if (state == 'UNPLAYABLE' &&
          _isConfirmedUnavailable(reason)) {
        throw ConfirmedUnplayableMediaException(
            reason.isEmpty ? (state ?? '') : reason);
      }
      throw Exception(
          reason.isEmpty ? 'Player status ${state ?? 'missing'}' : reason);
    }
    final headers = Map<String, String>.from(
        client.streamRequestHeaders);
    if (visitorData != null && visitorData.isNotEmpty) {
      headers['X-Goog-Visitor-Id'] = visitorData;
    }
    if (client.name == 'WEB_REMIX' && _connection.connected) {
      final cookies = _cookieHeaderValue();
      if (cookies != null) headers['Cookie'] = cookies;
      final auth = _authorizationHeaderValue(client.origin);
      if (auth != null) headers['Authorization'] = auth;
    }
    final streaming = root['streamingData'] as Map?;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final responseExpiry = (streaming?['expiresInSeconds'] != null)
        ? nowMs +
            max(
                    1,
                    int.tryParse(streaming!['expiresInSeconds']
                            .toString()) ??
                        0) *
                1000
        : null;
    final formats = <({Map<String, dynamic> format, bool adaptive})>[];
    final rawFormats = streaming?['formats'];
    if (rawFormats is List) {
      for (final f in rawFormats.whereType<Map<String, dynamic>>()) {
        formats.add((format: f, adaptive: false));
      }
    }
    final adaptive = streaming?['adaptiveFormats'];
    if (adaptive is List) {
      for (final f in adaptive.whereType<Map<String, dynamic>>()) {
        formats.add((format: f, adaptive: true));
      }
    }
    final candidates = <_Candidate>[];
    for (final entry in formats) {
      final format = entry.format;
      String? url = format['url']?.toString();
      url ??= () {
        final cipher = format['signatureCipher']?.toString() ??
            format['cipher']?.toString();
        if (cipher == null || script == null) return null;
        return _decipher.decipherUrl(cipher, script);
      }();
      if (url == null || url.isEmpty) continue;
      url = appendPot(url, gvsPoToken);
      final mime = format['mimeType']?.toString() ?? '';
      if (!mime.toLowerCase().startsWith('audio/')) continue;
      final codec = _extractCodec(mime);
      final bitrate =
          (format['bitrate'] as num?)?.toInt() ?? 0;
      if (!_isCompatibleAudio(
          mime.split(';').first, codec)) {
        continue;
      }
      final urlExpiry = _urlExpiryMs(url);
      DateTime? expiresAt;
      final options = [
        ?urlExpiry,
        ?responseExpiry,
      ];
      if (options.isNotEmpty) {
        expiresAt = DateTime.fromMillisecondsSinceEpoch(
            options.reduce(min));
      } else {
        expiresAt = DateTime.now()
            .add(Duration(milliseconds: _unknownExpiryTtlMs));
      }
      final codecLabel = (codec?.isNotEmpty ?? false)
          ? codec!.toUpperCase()
          : (mime.toLowerCase().contains('opus')
              ? 'OPUS'
              : mime.toLowerCase().contains('mp4')
                  ? 'AAC'
                  : 'AUDIO');
      final itag = (format['itag'] as num?)?.toInt() ?? -1;
      candidates.add(_Candidate(
        stream: ResolvedStream(
          url: url,
          mimeType: mime.split(';').first,
          bitrateKbps: (bitrate / 1000).round(),
          audioCodec: codecLabel,
          cacheKey:
              'youtube:$videoId:${client.key}:${format['itag']}:$authScope:${expiresAt.millisecondsSinceEpoch}',
          requestHeaders: headers,
          expiresAt: expiresAt,
        ),
        adaptive: entry.adaptive,
        bitrate: bitrate,
        itag: itag,
      ));
    }
    candidates.sort((a, b) {
      final adaptiveOrder =
          (a.adaptive ? 1 : 0).compareTo(b.adaptive ? 1 : 0);
      if (adaptiveOrder != 0) return adaptiveOrder;
      return b.bitrate.compareTo(a.bitrate);
    });
    // Limusic behavior: trust the chosen URL until expiry or a real
    // 403. No blocking Range probes on the playback hot path — mpv
    // itself is the validity check and reportPlaybackFailure handles
    // the retry. This removes 1–2 round trips per client.
    if (candidates.isEmpty) {
      throw Exception('${client.key} returned no usable audio URL');
    }
    return candidates.first;
  }

  /// Download-optimized resolution (M4A AAC container preferred).
  Future<ResolvedStream?> resolveDownloadStream(
      String videoId) async {
    if (videoId.isEmpty) return null;
    PlayerScript? script;
    int? sts;
    try {
      script = await _decipher
          .scriptFor(videoId)
          .timeout(const Duration(seconds: 30));
      sts = script?.sts;
    } catch (_) {}
    await _ensureConfig();
    final collected = <_Candidate>[];
    for (final client in playerClients) {
      try {
        final root = await _post(
          '${client.name == 'WEB_REMIX' ? musicApi : youtubeApi}/player?key=${client.apiKey}&prettyPrint=false',
          body: {
            'context': _context(
              client.name,
              client.version,
              visitorData: _visitorData,
              osName: client.osName,
              osVersion: client.osVersion,
              deviceMake: client.deviceMake,
              deviceModel: client.deviceModel,
              androidSdkVersion: client.androidSdkVersion,
            ),
            'videoId': videoId,
            'contentCheckOk': true,
            'racyCheckOk': true,
            if (sts != null)
              'playbackContext': {
                'contentPlaybackContext': {
                  'signatureTimestamp': sts,
                },
              },
          },
          clientName: client.name,
          clientVersion: client.version,
          userAgent: client.userAgent,
          maxAttempts: 1,
        );
        final status =
            (root['playabilityStatus'] as Map?)?['status']
                ?.toString();
        if (status != 'OK') continue;
        final streaming = root['streamingData'] as Map?;
        final lists = [
          streaming?['formats'],
          streaming?['adaptiveFormats']
        ];
        for (final list in lists) {
          if (list is! List) continue;
          for (final f in list.whereType<Map<String, dynamic>>()) {
            String? url = f['url']?.toString();
            url ??= () {
              final cipher =
                  f['signatureCipher']?.toString() ??
                      f['cipher']?.toString();
              if (cipher == null || script == null) {
                return null;
              }
              return _decipher.decipherUrl(cipher, script);
            }();
            if (url == null) continue;
            final mime = f['mimeType']?.toString() ?? '';
            if (!mime.toLowerCase().startsWith('audio/')) {
              continue;
            }
            final bitrate =
                (f['bitrate'] as num?)?.toInt() ?? 0;
            collected.add(_Candidate(
              stream: ResolvedStream(
                url: url,
                mimeType: mime.split(';').first,
                bitrateKbps: (bitrate / 1000).round(),
                audioCodec: 'AUDIO',
                cacheKey: 'yt-dl:$videoId:${f['itag']}',
                requestHeaders: client.streamRequestHeaders,
                expiresAt: _urlExpiryMs(url) != null
                    ? DateTime.fromMillisecondsSinceEpoch(
                        _urlExpiryMs(url)!)
                    : DateTime.now()
                        .add(Duration(milliseconds: _unknownExpiryTtlMs)),
              ),
              adaptive: true,
              bitrate: bitrate,
              itag: (f['itag'] as num?)?.toInt() ?? -1,
            ));
          }
        }
      } catch (_) {}
      if (collected.length >= 12) break;
    }
    _Candidate? best;
    final m4a = collected.where((c) =>
        c.stream.mimeType.toLowerCase().contains('mp4') ||
        c.stream.mimeType.toLowerCase().contains('m4a'));
    if (m4a.isNotEmpty) {
      best = m4a.reduce((a, b) =>
          a.bitrate >= b.bitrate ? a : b);
    } else if (collected.isNotEmpty) {
      best =
          collected.reduce((a, b) => a.bitrate >= b.bitrate ? a : b);
    }
    if (best == null) {
      return resolveAudioStream(videoId);
    }
    if (await _probeStream(best.stream, 'download-probe',
        adaptive: true)) {
      return best.stream;
    }
    return resolveAudioStream(videoId);
  }

  bool _isCooling(String videoId, String clientKey) {
    final prefix = '$videoId|$clientKey|';
    final now = DateTime.now();
    var cooling = false;
    final expired = <String>[];
    _failedClientsUntil.forEach((key, until) {
      if (!key.startsWith(prefix)) return;
      if (now.isBefore(until)) {
        cooling = true;
      } else {
        expired.add(key);
      }
    });
    for (final key in expired) {
      _failedClientsUntil.remove(key);
    }
    return cooling;
  }

  void _coolClient(String videoId, String clientKey) {
    _failedClientsUntil['$videoId|$clientKey|${_playbackAuthScope()}'] =
        DateTime.now().add(Duration(milliseconds: _clientCooldownMs));
  }

  void reportPlaybackFailure(String videoId) {
    _streamCache.removeWhere((k, _) => k.startsWith('$videoId|'));
    try {
      _disk?.deleteStreamEntries(videoId);
    } catch (_) {}
    final ref = _lastResolved.remove(videoId);
    if (ref != null) {
      _failedClientsUntil[
              '$videoId|${ref.clientProfile}|${ref.authScope}'] =
          DateTime.now().add(Duration(milliseconds: _clientCooldownMs));
      _logStream('report-failure',
          videoId: videoId, client: ref.clientProfile);
    } else {
      for (final c in playerClients.take(_maxStreamClients)) {
        _coolClient(videoId, c.key);
      }
      _logStream('report-failure', videoId: videoId);
    }
  }

  void _cacheResolvedStream(String videoId, _Candidate candidate,
      String clientProfile, String authScope, DateTime now) {
    _streamCache[
            '$videoId|$clientProfile|${candidate.itag}|$authScope|${candidate.stream.expiresAt?.millisecondsSinceEpoch ?? 0}'] =
        _CachedStream(candidate.stream, clientProfile,
            candidate.itag, candidate.adaptive, authScope, now);
    if (_streamCache.length > _maxStreamCacheEntries) {
      final sorted = _streamCache.entries.toList()
        ..sort((a, b) =>
            a.value.cachedAt.compareTo(b.value.cachedAt));
      for (final e in sorted.take(
          _streamCache.length - _maxStreamCacheEntries)) {
        _streamCache.remove(e.key);
      }
    }
    // Persistent disk copy for instant reuse across restarts.
    try {
      _disk?.saveStreamEntry(
        videoId: videoId,
        clientProfile: clientProfile,
        itag: candidate.itag,
        url: candidate.stream.url,
        headersJson: jsonEncode(candidate.stream.requestHeaders),
        mime: candidate.stream.mimeType,
        bitrateKbps: candidate.stream.bitrateKbps,
        codec: candidate.stream.audioCodec,
        expiresAtMs:
            candidate.stream.expiresAt?.millisecondsSinceEpoch ?? 0,
        cachedAtMs: now.millisecondsSinceEpoch,
        authScope: authScope,
      );
    } catch (_) {}
  }

  static bool _isFresh(_CachedStream c, DateTime now) {
    if (now.difference(c.cachedAt).inMilliseconds >=
        _streamTtlMs) {
      return false;
    }
    final exp = c.stream.expiresAt;
    return exp == null ||
        exp.difference(now).inMilliseconds > _urlExpiryMarginMs;
  }

  static String _expiryState(DateTime? exp) {
    if (exp == null) return 'unknown';
    return exp.isBefore(DateTime.now()) ? 'expired' : 'fresh';
  }

  /// Kept for download validation only. Playback never probes:
  /// cached URLs are trusted until expiry or a real 403 from mpv,
  /// mirroring Limusic (libmpv itself is the validity check).
  Future<bool> _probeStream(ResolvedStream stream, String stage,
      {required bool adaptive}) async {
    if (stream.expiresAt != null &&
        stream.expiresAt!.difference(DateTime.now()).inMilliseconds <=
            _urlExpiryMarginMs) {
      _logStream(stage,
          mime: stream.mimeType,
          expiry: 'expired',
          detail: 'expired=true');
      return false;
    }
    try {
      final headers = <String, String>{
        'Accept-Encoding': 'identity',
      };
      // Range probes only apply to non-adaptive (progressive)
      // formats â€” mirror Android.
      if (!adaptive) headers['Range'] = 'bytes=0-1';
      headers.addAll(stream.requestHeaders);
      var status = 0;
      var contentType = '';
      var gotByte = false;
      final client = HttpClient();
      try {
        final req = await client.getUrl(Uri.parse(stream.url));
        headers.forEach(req.headers.set);
        final res = await req.close().timeout(
            const Duration(seconds: 10));
        status = res.statusCode;
        contentType =
            res.headers.value('content-type')?.toLowerCase() ?? '';
        try {
          await res.first.timeout(
              const Duration(seconds: 10));
          gotByte = true;
        } catch (_) {
          gotByte = false;
        }
      } finally {
        client.close(force: true);
      }
      final validType = !contentType.contains('text/html') &&
          !contentType.contains('application/json') &&
          !contentType.contains('text/plain');
      final valid =
          (status == 200 || status == 206) && validType && gotByte;
      _logStream(stage,
          mime: stream.mimeType,
          expiry: _expiryState(stream.expiresAt),
          http: status,
          detail:
              'valid=$valid type=${_take40(contentType.split(';').first)}');
      return valid;
    } catch (e) {
      _logStream(stage,
          mime: stream.mimeType,
          expiry: _expiryState(stream.expiresAt),
          detail: 'error=${e.runtimeType}');
      return false;
    }
  }

  static String _take40(String s) =>
      s.length <= 40 ? s : s.substring(0, 40);

  static bool _isCompatibleAudio(String mime, String? codec) {
    final m = mime.toLowerCase();
    final c = (codec ?? '').toLowerCase();
    if (m == 'audio/webm') {
      return c.isEmpty || c.contains('opus') || c.contains('vorbis');
    }
    if (m == 'audio/mp4' || m == 'audio/m4a') {
      return c.isEmpty || c.contains('mp4a') || c.contains('aac');
    }
    if (m == 'audio/ogg') {
      return c.isEmpty || c.contains('opus') || c.contains('vorbis');
    }
    if (m == 'audio/mpeg') return true;
    return false;
  }

  static String? _extractCodec(String mime) {
    final m = _codecPattern.firstMatch(mime)?.group(1);
    if (m == null) return null;
    final first = m.split(',').first.trim();
    return first.isEmpty ? null : first;
  }

  static int? _urlExpiryMs(String url) {
    final exp = Uri.tryParse(url)?.queryParameters['expire'];
    final secs = exp == null ? null : int.tryParse(exp);
    return secs == null ? null : secs * 1000;
  }

  static String appendPot(String url, String? token) {
    if (token == null || token.isEmpty) return url;
    final parsed = Uri.tryParse(url);
    if (parsed == null) return url;
    if (parsed.queryParameters['pot'] != null) return url;
    final fragIdx = url.indexOf('#');
    final base = fragIdx >= 0 ? url.substring(0, fragIdx) : url;
    final fragment = fragIdx >= 0 ? url.substring(fragIdx) : '';
    final sep = base.endsWith('?') || base.endsWith('&')
        ? ''
        : (base.contains('?') ? '&' : '?');
    return '$base$sep${Uri.encodeQueryComponent('pot')}=${Uri.encodeQueryComponent(token)}$fragment';
  }

  static bool _isConfirmedUnavailable(String reason) {
    final lower = reason.toLowerCase();
    return _confirmedUnavailableReasons
        .any((r) => lower.contains(r));
  }

  // -- JSON parsing (mirror Android renderers) -------------------------------------

  List<YouTubeMusicTrack> _parseSongRenderers(Object? root) {
    final renderers = <Map<String, dynamic>>[];
    _collectObjects(
        root, 'musicResponsiveListItemRenderer', renderers);
    final songs = renderers.map(_parseSong).whereType<YouTubeMusicTrack>().toList();
    final queueRenderers = <Map<String, dynamic>>[];
    _collectObjects(
        root, 'playlistPanelVideoRenderer', queueRenderers);
    songs.addAll(queueRenderers
        .map(_parsePlaylistPanelSong)
        .whereType<YouTubeMusicTrack>());
    if (songs.isEmpty) {
      final ytVideos = <Map<String, dynamic>>[];
      _collectObjects(
          root, 'playlistVideoRenderer', ytVideos);
      songs.addAll(ytVideos
          .map(_parsePlaylistVideoRenderer)
          .whereType<YouTubeMusicTrack>());
    }
    final seen = <String>{};
    return songs.where((s) => seen.add(s.videoId)).toList();
  }
  String? _directWatchVideoId(Map<String, dynamic> r) {
    String? watchId(Map? m) =>
        (m?['watchEndpoint'] as Map?)?['videoId']?.toString();
    final playlistItem = r['playlistItemData'];
    if (playlistItem is Map &&
        playlistItem['videoId']?.toString().isNotEmpty == true) {
      return playlistItem['videoId'].toString();
    }
    final nav = r['navigationEndpoint'];
    if (nav is Map) {
      final id = watchId(nav);
      if (id != null && id.isNotEmpty) return id;
    }
    final overlay = r['thumbnailOverlay'];
    if (overlay is Map) {
      final content = (overlay[
              'musicItemThumbnailOverlayRenderer'] as Map?)?[
          'content'];
      if (content is Map) {
        final play = (content['musicPlayButtonRenderer']
            as Map?)?['playNavigationEndpoint'];
        if (play is Map) {
          final id = watchId(play);
          if (id != null && id.isNotEmpty) return id;
        }
      }
    }
    return null;
  }

  YouTubeMusicTrack? _parsePlaylistVideoRenderer(
      Map<String, dynamic> r) {
    final videoId = r['videoId']?.toString();
    if (videoId == null || videoId.isEmpty) return null;
    final titleObj = r['title'];
    String? title;
    if (titleObj is Map) {
      final runs = titleObj['runs'];
      if (runs is List) {
        title = runs
            .whereType<Map>()
            .map((e) => e['text']?.toString() ?? '')
            .join();
      }
      title ??= titleObj['simpleText']?.toString();
    }
    if (title == null || title.isEmpty) return null;
    final byline = r['shortBylineText'];
    String artist = 'Unknown artist';
    if (byline is Map && byline['runs'] is List) {
      final runs = (byline['runs'] as List).whereType<Map>();
      if (runs.isNotEmpty) {
        artist = runs.first['text']?.toString() ?? artist;
      }
    }
    final duration =
        int.tryParse(r['lengthSeconds']?.toString() ?? '') ?? 0;
    String artworkUrl = '';
    final thumbs = r['thumbnail'];
    if (thumbs is Map && thumbs['thumbnails'] is List) {
      final list =
          (thumbs['thumbnails'] as List).whereType<Map>();
      if (list.isNotEmpty) {
        artworkUrl = highResolutionArtwork(
            list.last['url']?.toString() ?? '');
      }
    }
    return YouTubeMusicTrack(
      videoId: videoId,
      title: title,
      artist: artist,
      artworkUrl: artworkUrl,
      durationSeconds: duration,
    );
  }

  YouTubeMusicTrack? _parsePlaylistPanelSong(
      Map<String, dynamic> r) {
    if (r.containsKey('unplayableText')) return null;
    final videoId = r['videoId']?.toString() ??
        ((r['navigationEndpoint']
                as Map?)?['watchEndpoint']
            as Map?)?['videoId']
            ?.toString();
    if (videoId == null || videoId.isEmpty) return null;
    final titleObj = r['title'];
    String title = '';
    if (titleObj is Map) {
      final runs = titleObj['runs'];
      if (runs is List) {
        title = runs
            .whereType<Map>()
            .map((e) => e['text']?.toString() ?? '')
            .join()
            .trim();
      }
      if (title.isEmpty) {
        title =
            titleObj['simpleText']?.toString().trim() ?? '';
      }
    }
    if (title.isEmpty) return null;
    final byline = (r['longBylineText'] ?? r['shortBylineText']);
    final details = byline is Map && byline['runs'] is List
        ? (byline['runs'] as List).whereType<Map>().toList()
        : <Map<String, dynamic>>[];
    String artist = '';
    for (final run in details) {
      final browseId = ((run['navigationEndpoint']
              as Map?)?['browseEndpoint']
          as Map?)?['browseId']
          ?.toString();
      if (browseId != null && browseId.startsWith('UC')) {
        artist = run['text']?.toString() ?? '';
        break;
      }
    }
    if (artist.isEmpty) {
      artist = details
          .map((e) => e['text']?.toString() ?? '')
          .firstWhere(_isLikelyArtistDetail,
              orElse: () => '');
    }
    if (artist.isEmpty) artist = 'Unknown artist';
    String album = '';
    for (final run in details) {
      final browseId = ((run['navigationEndpoint']
              as Map?)?['browseEndpoint']
          as Map?)?['browseId']
          ?.toString();
      if (browseId != null && browseId.startsWith('MPRE')) {
        album = run['text']?.toString() ?? '';
        break;
      }
    }
    var duration = 0;
    if (r['lengthText'] is Map) {
      final runs = (r['lengthText'] as Map)['runs'];
      if (runs is List) {
        for (final e in runs.whereType<Map>()) {
          final d =
              parseDuration(e['text']?.toString() ?? '');
          if (d != null) {
            duration = d;
            break;
          }
        }
      }
    }
    return YouTubeMusicTrack(
      videoId: videoId,
      title: title,
      artist: artist,
      album: album,
      artworkUrl: _rendererArtwork(r),
      durationSeconds: duration,
    );
  }

  YouTubeMusicTrack? _parseSong(Map<String, dynamic> r) {
    String? videoId =
        _directWatchVideoId(r) ?? _findString(r, 'videoId');
    if (videoId == null || videoId.isEmpty) return null;
    final columns =
        r['flexColumns'] is List ? r['flexColumns'] as List : null;
    Map? colText(int i) {
      if (columns == null || i >= columns.length) return null;
      final col = columns[i];
      if (col is! Map) return null;
      return (col['musicResponsiveListItemFlexColumnRenderer']
          as Map?)?['text'] as Map?;
    }

    final titleRuns = colText(0)?['runs'];
    String title = '';
    if (titleRuns is List) {
      title = titleRuns
          .whereType<Map>()
          .map((e) => e['text']?.toString() ?? '')
          .join()
          .trim();
    }
    if (title.isEmpty) return null;
    final detailRuns = colText(1)?['runs'];
    final details = detailRuns is List
        ? detailRuns.whereType<Map>().toList()
        : <Map<String, dynamic>>[];
    String artist = '';
    for (final run in details) {
      final browseId = ((run['navigationEndpoint']
              as Map?)?['browseEndpoint']
          as Map?)?['browseId']
          ?.toString();
      if (browseId != null && browseId.startsWith('UC')) {
        artist = run['text']?.toString() ?? '';
        break;
      }
    }
    if (artist.isEmpty) {
      artist = details
          .map((e) => e['text']?.toString() ?? '')
          .firstWhere(
              (t) => _isUsefulDetail(t) && parseDuration(t) == null,
              orElse: () => '');
    }
    if (artist.isEmpty) artist = 'Unknown artist';
    String album = '';
    for (final run in details) {
      final browseId = ((run['navigationEndpoint']
              as Map?)?['browseEndpoint']
          as Map?)?['browseId']
          ?.toString();
      if (browseId != null && browseId.startsWith('MPRE')) {
        album = run['text']?.toString() ?? '';
        break;
      }
    }
    return YouTubeMusicTrack(
      videoId: videoId,
      title: title,
      artist: artist,
      album: album,
      artworkUrl: _rendererArtwork(r),
      durationSeconds: _durationFromRenderer(r),
    );
  }

  /// Duration lives in different places depending on the page:
  /// search rows often use `text.simpleText` on a flex/fixed column,
  /// album pages use `runs` on `fixedColumns`, queue panels use
  /// `lengthText`. Any `m:ss` / `h:mm:ss` token wins.
  int _durationFromRenderer(Map<String, dynamic> r) {
    final lengthSeconds =
        int.tryParse(r['lengthSeconds']?.toString() ?? '') ?? 0;
    if (lengthSeconds > 0 && lengthSeconds <= 24 * 3600) {
      return lengthSeconds;
    }
    int? fromText(Object? text) {
      if (text is String) return parseDuration(text);
      if (text is! Map) return null;
      final simple = text['simpleText']?.toString();
      if (simple != null) {
        final d = parseDuration(simple);
        if (d != null) return d;
      }
      final runs = text['runs'];
      if (runs is List) {
        for (final run in runs.whereType<Map>()) {
          final d = parseDuration(run['text']?.toString() ?? '');
          if (d != null) return d;
        }
      }
      return null;
    }

    for (final key in const ['flexColumns', 'fixedColumns']) {
      final cols = r[key];
      if (cols is! List) continue;
      for (final col in cols.whereType<Map>()) {
        for (final renderer in col.values) {
          if (renderer is! Map) continue;
          final d = fromText(renderer['text']);
          if (d != null) return d;
        }
      }
    }
    final length = fromText(r['lengthText']);
    if (length != null) return length;
    final overlays = <Map<String, dynamic>>[];
    _collectObjects(r, 'thumbnailOverlayTimeStatusRenderer', overlays);
    for (final o in overlays) {
      final d = fromText(o['text']);
      if (d != null) return d;
    }
    return 0;
  }

  List<YouTubeMusicEntity> _parseEntityRenderers(
      Object? root, YouTubeEntityKind kind) {
    final renderers = <Map<String, dynamic>>[];
    _collectObjects(
        root, 'musicResponsiveListItemRenderer', renderers);
    final seen = <String>{};
    final out = <YouTubeMusicEntity>[];
    for (final r in renderers) {
      final e = _parseEntity(r, kind);
      if (e != null && seen.add(e.browseId)) out.add(e);
    }
    return out;
  }

  YouTubeMusicEntity? _parseEntity(
      Map<String, dynamic> r, YouTubeEntityKind kind) {
    final nav = r['navigationEndpoint'];
    final browse = nav is Map ? nav['browseEndpoint'] : null;
    if (browse is! Map) return null;
    final browseId = browse['browseId']?.toString() ?? '';
    if (browseId.isEmpty) return null;
    if (kind == YouTubeEntityKind.artist &&
        !browseId.startsWith('UC')) {
      return null;
    }
    if (kind == YouTubeEntityKind.album &&
        !browseId.startsWith('MPRE')) {
      return null;
    }
    final columns =
        r['flexColumns'] is List ? r['flexColumns'] as List : null;
    String name = '';
    if (columns != null && columns.isNotEmpty) {
      final col0 = columns[0];
      if (col0 is Map) {
        final text = (col0[
                'musicResponsiveListItemFlexColumnRenderer']
            as Map?)?['text'];
        if (text is Map && text['runs'] is List) {
          name = (text['runs'] as List)
              .whereType<Map>()
              .map((e) => e['text']?.toString() ?? '')
              .join()
              .trim();
        }
      }
    }
    if (name.isEmpty) return null;
    List<Map<String, dynamic>> details = const [];
    if (columns != null && columns.length > 1) {
      final col1 = columns[1];
      if (col1 is Map) {
        final text = (col1[
                'musicResponsiveListItemFlexColumnRenderer']
            as Map?)?['text'];
        if (text is Map && text['runs'] is List) {
          details = (text['runs'] as List)
              .whereType<Map<String, dynamic>>()
              .toList();
        }
      }
    }
    String artist = '';
    if (kind == YouTubeEntityKind.album) {
      for (final run in details) {
        final bid = ((run['navigationEndpoint']
                as Map?)?['browseEndpoint']
            as Map?)?['browseId']
            ?.toString();
        if (bid != null && bid.startsWith('UC')) {
          artist = run['text']?.toString() ?? '';
          break;
        }
      }
    }
    const skip = {'â€¢', 'Â·', 'Artist', 'Album', 'EP', 'Single'};
    final subtitle = details
        .map((e) => e['text']?.toString().trim() ?? '')
        .where((t) => t.isNotEmpty && !skip.contains(t))
        .join(' Â· ')
        .trim();
    return YouTubeMusicEntity(
      kind: kind,
      name: name,
      artist: artist,
      subtitle: subtitle,
      browseId: browseId,
      playlistId: _findString(r, 'playlistId') ?? '',
      artworkUrl: _rendererArtwork(r),
    );
  }

  List<YouTubePlaylistSummary> _parsePlaylistRenderers(
      Object? root) {
    final renderers = <Map<String, dynamic>>[];
    for (final k in [
      'musicResponsiveListItemRenderer',
      'musicTwoRowItemRenderer',
      'gridPlaylistRenderer',
      'musicGridItemRenderer',
      'playlistRenderer',
    ]) {
      _collectObjects(root, k, renderers);
    }
    final seen = <String>{};
    final out = <YouTubePlaylistSummary>[];
    for (final r in renderers) {
      final s = _parsePlaylistSummary(r);
      if (s != null && seen.add(s.id)) out.add(s);
    }
    return out;
  }

  YouTubePlaylistSummary? _parsePlaylistSummary(
      Map<String, dynamic> r) {
    Map? nav = (r['navigationEndpoint'] as Map?)?[
        'browseEndpoint'] as Map?;
    nav ??= () {
      final title = r['title'];
      if (title is Map && title['runs'] is List) {
        final runs =
            (title['runs'] as List).whereType<Map>();
        if (runs.isNotEmpty) {
          return (runs.first['navigationEndpoint']
              as Map?)?['browseEndpoint'] as Map?;
        }
      }
      return null;
    }();
    nav ??= () {
      final overlay = r['thumbnailOverlay'];
      if (overlay is! Map) return null;
      final content = (overlay[
              'musicItemThumbnailOverlayRenderer']
          as Map?)?['content'];
      if (content is! Map) return null;
      final play = (content['musicPlayButtonRenderer']
          as Map?)?['playNavigationEndpoint'];
      return play is Map
          ? play['watchEndpoint'] as Map?
          : null;
    }();
    if (nav == null) {
      final onTap = r['onTap'];
      nav = onTap is Map
          ? onTap['browseEndpoint'] as Map?
          : null;
    }
    if (nav == null) return null;
    final browseId = nav['browseId']?.toString() ??
        nav['playlistId']?.toString() ??
        '';
    if (browseId.isEmpty) return null;
    final playlistId = browseId.startsWith('VL')
        ? browseId.substring(2)
        : browseId;
    String? title;
    final flex = r['flexColumns'];
    if (flex is List && flex.isNotEmpty) {
      final col0 = flex[0];
      if (col0 is Map) {
        final text = (col0[
                'musicResponsiveListItemFlexColumnRenderer']
            as Map?)?['text'];
        if (text is Map && text['runs'] is List) {
          title = (text['runs'] as List)
              .whereType<Map>()
              .map((e) => e['text']?.toString() ?? '')
              .join();
        }
      }
    }
    title ??= () {
      final t = r['title'];
      if (t is Map) {
        if (t['runs'] is List) {
          return (t['runs'] as List)
              .whereType<Map>()
              .map((e) => e['text']?.toString() ?? '')
              .join();
        }
        return t['simpleText']?.toString();
      }
      return null;
    }();
    if (title == null || title.isEmpty) return null;
    List? subtitleRuns;
    if (flex is List && flex.length > 1) {
      final col1 = flex[1];
      if (col1 is Map) {
        final text = (col1[
                'musicResponsiveListItemFlexColumnRenderer']
            as Map?)?['text'];
        if (text is Map && text['runs'] is List) {
          subtitleRuns = text['runs'] as List;
        }
      }
    }
    subtitleRuns ??= () {
      final s = r['subtitle'];
      return s is Map && s['runs'] is List
          ? s['runs'] as List
          : null;
    }();
    String author = '';
    String trackCountText = '';
    if (subtitleRuns != null) {
      for (final e in subtitleRuns.whereType<Map>()) {
        final bid = ((e['navigationEndpoint']
                as Map?)?['browseEndpoint']
            as Map?)?['browseId']
            ?.toString();
        if (bid != null && bid.startsWith('UC')) {
          author = e['text']?.toString() ?? '';
          break;
        }
      }
      if (author.isEmpty && subtitleRuns.isNotEmpty) {
        final first =
            (subtitleRuns.first as Map?)?['text']?.toString() ?? '';
        if (first.toLowerCase() != 'playlist') author = first;
      }
      for (final e in subtitleRuns.whereType<Map>()) {
        final text =
            e['text']?.toString().toLowerCase() ?? '';
        if (text.contains('song') ||
            text.contains('track')) {
          trackCountText = e['text']?.toString() ?? '';
          break;
        }
      }
    }
    return YouTubePlaylistSummary(
      id: playlistId,
      title: title.trim(),
      author: author.trim(),
      trackCountText: trackCountText,
      artworkUrl: _extractThumbnailsUrl(r) ?? '',
    );
  }

  String _rendererArtwork(Map<String, dynamic> r) {
    final thumb = r['thumbnail'];
    if (thumb is Map) {
      final inner = thumb['musicThumbnailRenderer'];
      if (inner is Map) {
        final t = inner['thumbnail'];
        if (t is Map && t['thumbnails'] is List) {
          final list =
              (t['thumbnails'] as List).whereType<Map>();
          if (list.isNotEmpty) {
            return highResolutionArtwork(
                list.last['url']?.toString() ?? '');
          }
        }
      }
      if (thumb['thumbnails'] is List) {
        final list =
            (thumb['thumbnails'] as List).whereType<Map>();
        if (list.isNotEmpty) {
          return highResolutionArtwork(
              list.last['url']?.toString() ?? '');
        }
      }
    }
    return '';
  }

  String? _extractThumbnailsUrl(Object? renderer) {
    final arrays = <List>[];
    void find(Object? el) {
      if (el is Map<String, dynamic>) {
        final th = el['thumbnails'];
        if (th is List && th.isNotEmpty) arrays.add(th);
        for (final v in el.values) {
          find(v);
        }
      } else if (el is List) {
        for (final v in el) {
          find(v);
        }
      }
    }

    Object? node = renderer;
    if (renderer is Map<String, dynamic>) {
      node = renderer['thumbnail'] ??
          renderer['thumbnailRenderer'] ??
          renderer;
    }
    find(node);
    if (arrays.isEmpty) return null;
    final arr = arrays.first;
    String? url;
    for (final e in arr.reversed) {
      if (e is Map && e['url']?.toString().isNotEmpty == true) {
        url = e['url'].toString();
        break;
      }
    }
    url ??= () {
      for (final e in arr) {
        if (e is Map && e['url']?.toString().isNotEmpty == true) {
          return e['url'].toString();
        }
      }
      return null;
    }();
    if (url == null || url.isEmpty) return null;
    return highResolutionArtwork(url);
  }

  void _collectObjects(
      Object? element, String key, List<Map<String, dynamic>> out) {
    if (element is Map<String, dynamic>) {
      element.forEach((name, child) {
        if (name == key && child is Map<String, dynamic>) {
          out.add(child);
        }
        _collectObjects(child, key, out);
      });
    } else if (element is List) {
      for (final child in element) {
        _collectObjects(child, key, out);
      }
    }
  }

  String? _findString(Object? element, String key) {
    if (element is Map<String, dynamic>) {
      final direct = element[key];
      if (direct is String) return direct;
      for (final v in element.values) {
        final found = _findString(v, key);
        if (found != null) return found;
      }
    } else if (element is List) {
      for (final v in element) {
        final found = _findString(v, key);
        if (found != null) return found;
      }
    }
    return null;
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
}

class _Candidate {
  final ResolvedStream stream;
  final bool adaptive;
  final int bitrate;
  final int itag;
  _Candidate({
    required this.stream,
    required this.adaptive,
    required this.bitrate,
    required this.itag,
  });
}

class _ResolvedRef {
  final String clientProfile;
  final String authScope;
  const _ResolvedRef(this.clientProfile, this.authScope);
}

class _BrowsePages {
  final List<YouTubeMusicTrack> tracks;
  final bool isComplete;
  const _BrowsePages(this.tracks, this.isComplete);
}

class _PlaylistRoot {
  final _Map root;
  final bool authenticated;
  const _PlaylistRoot(this.root, this.authenticated);
}

typedef _Map = Map<String, dynamic>;

final innerTubeProvider = Provider<InnerTubeMusicApi>((ref) {
  final dio = DioFactory.create();
  final api = InnerTubeMusicApi(
    dio,
    ref.watch(secureStoreProvider),
    ref.watch(poTokenEngineProvider),
  );
  api.loadPersistedConnection();
  // Persistent disk cache only. BotGuard is LAZY (see
  // _resolveAudioStreamInternal.ensureAux): direct-URL clients never
  // mint poTokens, so most sessions open zero WebViews.
  try {
    api.attachDiskCache(ref.watch(databaseProvider));
  } catch (_) {}
  return api;
});
