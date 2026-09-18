import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import '../../core/audio/stream_models.dart';
import '../../core/env/app_env.dart';
import '../../core/network/dio_factory.dart';

/// Tidal catalog client for a HiFi-API-compatible proxy.
///
/// Search: `GET /search/?s=` (and `?i=` for ISRC).
/// Stream: `GET /track/?id=&quality=` which returns a backend-decrypted
/// `OriginalTrackUrl` and/or a BTS / MPEG-DASH manifest. Encrypted
/// Widevine `.mpd` is never passed to libmpv — only a direct audio URL.
class TidalApi {
  TidalApi([Dio? dio])
      : _dio = dio ??
            DioFactory.create()
              ..options.connectTimeout = const Duration(seconds: 10);

  final Dio _dio;

  static const _hiRes = 'HI_RES_LOSSLESS';
  static const _cd = 'LOSSLESS';

  bool get isConfigured => AppEnv.hasTidalBackend;

  String get _base => AppEnv.tidalBackendUrl;

  Map<String, String> get _headers => {
        if (AppEnv.tidalApiKey.isNotEmpty) 'X-API-Key': AppEnv.tidalApiKey,
      };

  /// CD FLAC first (BTS progressive URL). Hi-res DASH is slower and
  /// often encrypted; asking for it first delayed playback into Opus.
  static List<String> qualitiesFor(int preferred) {
    if (preferred == 5) return const [_cd];
    if (preferred == 6) return const [_cd, _hiRes];
    return const [_cd, _hiRes];
  }

  Future<List<Map<String, dynamic>>> searchTracks(String query) async {
    if (!isConfigured || query.trim().isEmpty) return const [];
    final res = await _dio.get<dynamic>(
      '$_base/search/',
      queryParameters: {'s': query.trim()},
      options: Options(
        headers: _headers,
        validateStatus: (c) => c != null && c < 500,
      ),
    );
    if (res.statusCode != 200) return const [];
    return TidalPlayback.searchItems(res.data);
  }

  Future<ResolvedStream?> fetchPlayable(
    String trackId,
    int preferredQuality, {
    String artworkUrl = '',
    String albumTitle = '',
  }) async {
    if (!isConfigured || trackId.isEmpty) return null;
    for (final quality in qualitiesFor(preferredQuality)) {
      final stream = await _fetchQuality(
        trackId,
        quality,
        artworkUrl: artworkUrl,
        albumTitle: albumTitle,
      );
      if (stream != null) return stream;
    }
    return null;
  }

  Future<ResolvedStream?> _fetchQuality(
    String trackId,
    String quality, {
    required String artworkUrl,
    required String albumTitle,
  }) async {
    final attempts = <({String path, Map<String, dynamic> query})>[
      (path: '/track/', query: {'id': trackId, 'quality': quality}),
      (path: '/track', query: {'id': trackId, 'quality': quality}),
      (path: '/song/', query: {'id': trackId, 'quality': quality}),
    ];
    for (final attempt in attempts) {
      try {
        final res = await _dio.get<dynamic>(
          '$_base${attempt.path}',
          queryParameters: attempt.query,
          options: Options(
            headers: _headers,
            sendTimeout: const Duration(seconds: 45),
            receiveTimeout: const Duration(seconds: 45),
            validateStatus: (c) => c != null && c < 500,
          ),
        );
        if (res.statusCode != 200) continue;
        final parsed = TidalPlayback.parse(res.data);
        var url = parsed?.playableUrl;
        if ((url == null || url.isEmpty) &&
            parsed != null &&
            parsed.dashXml.isNotEmpty &&
            !parsed.encrypted) {
          url = await TidalMpd.assembleToFile(
            xml: parsed.dashXml,
            trackId: trackId,
            quality: quality,
            dio: _dio,
          );
        }
        if (url == null || url.isEmpty) continue;
        return _streamFromUrl(
          url,
          trackId: trackId,
          quality: quality,
          parsed: parsed!,
          artworkUrl: artworkUrl,
          albumTitle: albumTitle,
        );
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  ResolvedStream _streamFromUrl(
    String url, {
    required String trackId,
    required String quality,
    required TidalPlayback parsed,
    required String artworkUrl,
    required String albumTitle,
  }) {
    final hiRes = quality == _hiRes || parsed.bitDepth >= 24;
    final sampling = parsed.sampleRateHz > 0
        ? parsed.sampleRateHz / 1000.0
        : (hiRes ? 96.0 : 44.1);
    final depth = parsed.bitDepth > 0 ? parsed.bitDepth : (hiRes ? 24 : 16);
    return ResolvedStream(
      url: url,
      mimeType: url.startsWith('file:') ? 'audio/mp4' : parsed.mimeType.isNotEmpty
          ? parsed.mimeType
          : 'audio/flac',
      bitrateKbps: hiRes ? (depth * sampling * 2).toInt() : 1411,
      audioCodec: hiRes ? 'HI-RES FLAC' : 'LOSSLESS',
      cacheKey: 'tidal:$trackId:$quality',
      isLossless: true,
      bitDepth: depth,
      samplingRateKhz: sampling,
      artworkUrl: artworkUrl,
      albumTitle: albumTitle,
      expiresAt: DateTime.now().add(const Duration(minutes: 20)),
    );
  }
}

/// Parsed Tidal playback payload after the backend MPD/BTS decrypter.
class TidalPlayback {
  final String directUrl;
  final String mimeType;
  final int bitDepth;
  final int sampleRateHz;
  final bool encrypted;
  final String dashXml;

  const TidalPlayback({
    this.directUrl = '',
    this.mimeType = 'audio/flac',
    this.bitDepth = 0,
    this.sampleRateHz = 0,
    this.encrypted = false,
    this.dashXml = '',
  });

  String? get playableUrl {
    if (encrypted) return null;
    if (directUrl.isEmpty) return null;
    if (!TidalMpd.isDirectAudioUrl(directUrl)) return null;
    return directUrl;
  }

  static List<Map<String, dynamic>> searchItems(dynamic body) {
    final items = <Map<String, dynamic>>[];
    void collect(dynamic value) {
      if (value is List) {
        for (final e in value) {
          collect(e);
        }
        return;
      }
      if (value is! Map) return;
      final map = Map<String, dynamic>.from(value);
      final nested = map['items'] ??
          map['tracks'] ??
          (map['data'] is Map
              ? (map['data'] as Map)['items'] ??
                  (map['data'] as Map)['tracks']
              : map['data']);
      if (nested != null && nested != map['id'] && nested is! num) {
        collect(nested);
      }
      final id = map['id'] ?? map['trackId'];
      final title = map['title']?.toString() ?? '';
      final looksLikeTrack = map.containsKey('duration') &&
          (map.containsKey('audioQuality') ||
              map['artist'] != null ||
              map['artists'] != null);
      if (id != null && title.isNotEmpty && looksLikeTrack) {
        items.add(map);
      }
    }

    collect(body);
    final unique = <String, Map<String, dynamic>>{};
    for (final item in items) {
      final id = item['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      unique.putIfAbsent(id, () => item);
    }
    return unique.values.toList();
  }

  static TidalPlayback? parse(dynamic body) {
    if (body is String) {
      final url = body.trim();
      if (TidalMpd.isDirectAudioUrl(url)) {
        return TidalPlayback(directUrl: url);
      }
    }
    final merged = _mergePayload(body);
    if (merged.isEmpty) return null;
    final original = _firstHttp(merged, const [
      'OriginalTrackUrl',
      'originalTrackUrl',
      'original_track_url',
      'streamUrl',
      'downloadUrl',
    ]);
    final mimeType = merged['manifestMimeType']?.toString() ??
        merged['mimeType']?.toString() ??
        '';
    final manifest = merged['manifest']?.toString() ?? '';
    final fromManifest = TidalMpd.playableUrl(
      manifest: manifest,
      mimeType: mimeType,
    );
    final url = original ?? fromManifest ?? '';
    final encrypted = TidalMpd.isEncryptedManifest(manifest) && url.isEmpty;
    final decoded = TidalMpd.decodeManifest(manifest);
    final dashXml = decoded.contains('<MPD') || decoded.contains('<mpd')
        ? decoded
        : '';
    return TidalPlayback(
      directUrl: url,
      mimeType: _audioMime(mimeType, url),
      bitDepth: _asInt(merged['bitDepth'] ?? merged['bit_depth']),
      sampleRateHz: _asInt(merged['sampleRate'] ?? merged['sampling_rate']),
      encrypted: encrypted,
      dashXml: dashXml,
    );
  }

  static Map<String, dynamic> _mergePayload(dynamic body) {
    final out = <String, dynamic>{};
    void collect(dynamic value) {
      if (value is String && TidalMpd.isDirectAudioUrl(value)) {
        out.putIfAbsent('OriginalTrackUrl', () => value);
        return;
      }
      if (value is List) {
        for (final e in value) {
          collect(e);
        }
        return;
      }
      if (value is! Map) return;
      final map = Map<String, dynamic>.from(value);
      for (final entry in map.entries) {
        if (entry.value == null) continue;
        if (entry.value is String && (entry.value as String).isEmpty) continue;
        out[entry.key] = entry.value;
      }
      collect(map['data']);
      collect(map['track']);
      collect(map['Track Info']);
      collect(map['trackInfo']);
      collect(map['Song Info']);
    }

    collect(body);
    return out;
  }

  static String? _firstHttp(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      for (final entry in map.entries) {
        if (entry.key.toString().toLowerCase() != key.toLowerCase()) {
          continue;
        }
        final value = entry.value?.toString() ?? '';
        if (TidalMpd.isDirectAudioUrl(value)) return value;
      }
    }
    return null;
  }

  static String _audioMime(String manifestMime, String url) {
    final lower = url.toLowerCase();
    if (lower.contains('.mp3')) return 'audio/mpeg';
    if (lower.contains('.m4a') || lower.contains('.mp4')) return 'audio/mp4';
    if (manifestMime.contains('flac') || lower.contains('.flac')) {
      return 'audio/flac';
    }
    return 'audio/flac';
  }

  static int _asInt(Object? raw) {
    if (raw is num) return raw.toInt();
    return int.tryParse(raw?.toString() ?? '') ?? 0;
  }
}

/// Turns Tidal BTS JSON and unencrypted MPEG-DASH into a direct audio URL.
/// Encrypted Widevine MPD is rejected — decryption stays on the backend.
class TidalMpd {
  static bool isManifestUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('.mpd') ||
        lower.contains('mpeg-dash') ||
        lower.contains('dash+xml');
  }

  /// Catalog pages like `http://www.tidal.com/track/123` are not audio.
  static bool isCatalogPage(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return false;
    final host = uri.host.toLowerCase();
    return host == 'tidal.com' ||
        host == 'www.tidal.com' ||
        host == 'listen.tidal.com' ||
        host.endsWith('.tidal.com') && !host.contains('audio');
  }

  static bool isDirectAudioUrl(String url) {
    if (!url.startsWith('http')) return false;
    if (isManifestUrl(url) || isCatalogPage(url)) return false;
    return true;
  }

  static bool isEncryptedManifest(String manifest) {
    final xml = _decodeMaybeBase64(manifest);
    if (xml.isEmpty) return false;
    final lower = xml.toLowerCase();
    return lower.contains('contentprotection') ||
        lower.contains('cenc:pssh') ||
        lower.contains('widevine') ||
        lower.contains('encryptiontype":"') &&
            !lower.contains('encryptiontype":"none"');
  }

  static String? playableUrl({
    required String manifest,
    required String mimeType,
  }) {
    if (manifest.trim().isEmpty) return null;
    final decoded = _decodeMaybeBase64(manifest);
    final mime = mimeType.toLowerCase();
    if (mime.contains('bts') || mime.contains('json') || decoded.startsWith('{')) {
      return _btsUrl(decoded);
    }
    if (mime.contains('dash') ||
        decoded.contains('<MPD') ||
        decoded.contains('<mpd')) {
      return _unencryptedMpdUrl(decoded);
    }
    return null;
  }

  static String? _btsUrl(String jsonText) {
    try {
      final data = jsonDecode(jsonText);
      if (data is! Map) return null;
      final encryption = data['encryptionType']?.toString().toUpperCase() ?? 'NONE';
      if (encryption.isNotEmpty && encryption != 'NONE') return null;
      final urls = data['urls'];
      if (urls is List) {
        for (final item in urls) {
          final url = item?.toString() ?? '';
          if (url.startsWith('http') && isDirectAudioUrl(url)) return url;
        }
      }
      final url = data['url']?.toString() ?? '';
      if (url.startsWith('http') && isDirectAudioUrl(url)) return url;
    } catch (_) {}
    return null;
  }

  static String? _unencryptedMpdUrl(String xml) {
    if (isEncryptedManifest(xml)) return null;
    if (RegExp(r'\$Number\$|\$Time\$').hasMatch(xml)) {
      return null;
    }
    final base = RegExp(r'<BaseURL>([^<]+)</BaseURL>', caseSensitive: false)
        .firstMatch(xml)
        ?.group(1)
        ?.trim();
    if (base != null && isDirectAudioUrl(unescapeXml(base))) {
      return unescapeXml(base);
    }
    return null;
  }

  /// Download unencrypted DASH FLAC segments and stitch them into a
  /// local fMP4 file. Does not implement Widevine — encrypted MPDs
  /// are skipped.
  static Future<String?> assembleToFile({
    required String xml,
    required String trackId,
    required String quality,
    required Dio dio,
  }) async {
    if (xml.isEmpty || isEncryptedManifest(xml)) return null;
    final init = unescapeXml(_attr(xml, 'initialization') ?? '');
    final media = unescapeXml(_attr(xml, 'media') ?? '');
    if (!init.startsWith('http') || !media.contains(r'$Number$')) return null;
    final start = int.tryParse(_attr(xml, 'startNumber') ?? '1') ?? 1;
    final count = segmentCount(xml);
    if (count <= 0 || count > 400) return null;

    final dir = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}lastwave_tidal',
    );
    await dir.create(recursive: true);
    final safeId = trackId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final out = File(
      '${dir.path}${Platform.pathSeparator}${safeId}_$quality.m4a',
    );
    if (out.existsSync() && out.lengthSync() > 2048) {
      return Uri.file(out.path).toString();
    }

    final urls = <String>[
      init,
      for (var n = start; n < start + count; n++)
        media.replaceAll(r'$Number$', '$n'),
    ];
    try {
      final chunks = await _downloadAll(dio, urls);
      final sink = out.openWrite();
      try {
        for (final chunk in chunks) {
          sink.add(chunk);
        }
      } finally {
        await sink.close();
      }
      if (!out.existsSync() || out.lengthSync() < 2048) {
        if (out.existsSync()) out.deleteSync();
        return null;
      }
      return Uri.file(out.path).toString();
    } catch (_) {
      if (out.existsSync()) {
        try {
          out.deleteSync();
        } catch (_) {}
      }
      return null;
    }
  }

  static int segmentCount(String xml) {
    var total = 0;
    final re = RegExp(r'<S\b([^>]*)/?>', caseSensitive: false);
    for (final match in re.allMatches(xml)) {
      final attrs = match.group(1) ?? '';
      final repeat = int.tryParse(
            RegExp(r'\br="(\d+)"').firstMatch(attrs)?.group(1) ?? '',
          ) ??
          0;
      total += repeat + 1;
    }
    return total;
  }

  static String unescapeXml(String value) => value
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'");

  static String? _attr(String xml, String name) =>
      RegExp('$name="([^"]+)"', caseSensitive: false)
          .firstMatch(xml)
          ?.group(1);

  static Future<List<List<int>>> _downloadAll(Dio dio, List<String> urls) async {
    final out = List<List<int>?>.filled(urls.length, null);
    final pending = List<int>.generate(urls.length, (i) => i);
    Future<void> worker() async {
      while (pending.isNotEmpty) {
        final index = pending.removeLast();
        out[index] = await _getBytes(dio, urls[index]);
      }
    }

    await Future.wait([
      for (var i = 0; i < 4; i++) worker(),
    ]);
    return [
      for (final chunk in out)
        if (chunk != null) chunk else throw StateError('dash segment missing'),
    ];
  }

  static Future<List<int>> _getBytes(Dio dio, String url) async {
    final res = await dio.get<List<int>>(
      url,
      options: Options(
        responseType: ResponseType.bytes,
        followRedirects: true,
        receiveTimeout: const Duration(seconds: 45),
        headers: const {'Accept': '*/*'},
        validateStatus: (c) => c == 200,
      ),
    );
    return res.data ?? const [];
  }

  static String decodeManifest(String raw) => _decodeMaybeBase64(raw);

  static String _decodeMaybeBase64(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.startsWith('{') || trimmed.startsWith('<')) return trimmed;
    try {
      final decoded = utf8.decode(base64.decode(trimmed));
      if (decoded.startsWith('{') || decoded.startsWith('<')) return decoded;
    } catch (_) {}
    return trimmed;
  }
}

/// Map a Tidal search hit onto the shared lossless candidate fields.
Map<String, dynamic> tidalHitToCandidateJson(Map<String, dynamic> json) {
  final artist = json['artist'];
  final artists = json['artists'];
  final names = <String>[];
  if (artist is Map) {
    final name = artist['name']?.toString() ?? '';
    if (name.isNotEmpty) names.add(name);
  } else if (artist is String && artist.isNotEmpty) {
    names.add(artist);
  }
  if (artists is List) {
    for (final item in artists) {
      if (item is Map) {
        final name = item['name']?.toString() ?? '';
        if (name.isNotEmpty && !names.contains(name)) names.add(name);
      }
    }
  }
  final album = json['album'];
  String cover = '';
  String albumTitle = '';
  if (album is Map) {
    albumTitle = album['title']?.toString() ?? '';
    cover = _tidalCoverUrl(album['cover']?.toString() ??
        album['image']?.toString() ??
        '');
  }
  return {
    'id': json['id']?.toString() ?? '',
    'title': json['title']?.toString() ?? '',
    'version': json['version']?.toString() ?? '',
    'duration': json['duration'],
    'performer': names.isNotEmpty ? {'name': names.first} : '',
    'performers': [
      for (final name in names) {'name': name},
    ],
    'album': {
      'title': albumTitle,
      'cover': cover,
      'artist': names.isNotEmpty ? {'name': names.first} : '',
    },
  };
}

String _tidalCoverUrl(String cover) {
  if (cover.isEmpty) return '';
  if (cover.startsWith('http')) return cover;
  final path = cover.replaceAll('-', '/');
  return 'https://resources.tidal.com/images/$path/1280x1280.jpg';
}
