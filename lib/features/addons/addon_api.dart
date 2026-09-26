import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/stream_models.dart';
import '../../core/env/app_env.dart';
import '../../core/network/dio_factory.dart';
import '../../core/storage/prefs.dart';
import '../lossless/lossless_source.dart';

/// Personal addon source (LastWave addon protocol).
///
/// A user-pasted `{base}/a/<token>/` URL plus the app-embedded client
/// key unlocks manifest/search/stream on a compatible server.
/// [losslessApiProvider] hands it to playback instead.
///
/// Protocol notes (mirrors the server's compat contract):
/// - every manifest/search/stream call carries `X-LW-TS` (unix sec) +
///   `X-LW-Sign` = hex HMAC-SHA256(secret, "ts\nMETHOD\npath\ntoken");
///   path excludes the query string. Timestamps outside ±120s fail.
/// - failures are deliberately ambiguous: bad URL, revoked URL, dead
///   URL and bad proof ALL answer 404. Unsigned calls answer 200 with
///   a prank-MP3 honeypot instead of an error — those URLs must NEVER
///   play ([_isDecoy]).
/// - the audio player fetches headerless, so `/stream` mints media
///   links with their own 10-minute expiring signature. Only an
///   authenticated `/stream` call can mint one.
/// - quota: only successful plays count (500/day/account, UTC reset);
///   exhaustion answers 429 + `Retry-After` (+ `X-Quota-*` headers).
class AddonApi implements LosslessSource {
  final List<String> bases;
  final Dio _dio;
  final ResolvedStreamCache _streamCache = ResolvedStreamCache(maxEntries: 16);
  final Map<String, Future<ResolvedStream?>> _inflight = {};
  final Map<String, ({AddonManifest manifest, DateTime at})> _manifests = {};

  /// Last-known quota per addon root (from stream-response headers).
  /// Read by the Sources settings page; unknown until first playback.
  final Map<String, AddonQuota> quotaByBase = {};

  AddonApi(List<String> rawBases, [Dio? dio])
      : bases = [
          for (final b in rawBases)
            if (parseAddonUrl(b) != null)
              parseAddonUrl(b)!.root,
        ],
        _dio = dio ??
            (DioFactory.create()
              ..options.connectTimeout =
                  const Duration(seconds: 10));

  String get _secret => AppEnv.addonClientSecret;

  @override
  bool get isConfigured =>
      bases.isNotEmpty && _secret.isNotEmpty;

  // -- URL parsing ------------------------------------------------------------

  /// Accepts a full addon root (trailing slash optional), a manifest
  /// URL, or a deeper addon URL (stream/…). Bare domains and
  /// non-hex tokens are rejected (the server would 404 them anyway).
  static ({String root, String token})? parseAddonUrl(
      String raw) {
    var v = raw.trim().replaceAll(RegExp(r'/+$'), '');
    if (v.isEmpty) return null;
    v = v.replaceAll(RegExp(r'/manifest(\.json)?$'), '');
    final m =
        RegExp(r'^(https?://[^/?#]+)/a/([^/?#]+)').firstMatch(v);
    if (m == null) return null;
    final token = m.group(2)!;
    if (!RegExp(r'^[0-9a-fA-F]{16,}$').hasMatch(token)) {
      return null;
    }
    return (root: '${m.group(1)}/a/$token/', token: token);
  }

  // -- request signing (one-way lock) ------------------------------------------

  /// Pure signer (unit-tested): `ts` injected so vectors are stable.
  /// `path` is the exact request path the server sees (no query).
  static Map<String, String> signFor({
    required String secret,
    required String method,
    required String path,
    required String token,
    required String ts,
  }) {
    final payload = '$ts\n${method.toUpperCase()}\n$path\n$token';
    final mac = Hmac(sha256, utf8.encode(secret));
    final sign = mac.convert(utf8.encode(payload)).toString();
    return {
      'X-LW-TS': ts,
      'X-LW-Sign': sign,
      'X-LW-Intent': 'stream',
      'User-Agent': 'LastWave-Player/1.0',
    };
  }

  static String tokenOfRoot(String root) {
    final v = root.trim().replaceAll(RegExp(r'/+$'), '');
    final m = RegExp(r'/a/([^/?#]+)$').firstMatch(v);
    return m?.group(1) ?? '';
  }

  Map<String, String> _signHeaders(
      String method, String root, String path) {
    final ts =
        (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
    return signFor(
        secret: _secret,
        method: method,
        path: path,
        token: tokenOfRoot(root),
        ts: ts);
  }

  /// Char-bigram Dice similarity 0–100 (local copy — keeps this
  /// client decoupled from the InnerTube matcher).
  static int dice(String a, String b) {
    if (a == b) return 100;
    if (a.isEmpty || b.isEmpty) return 0;
    Set<String> grams(String s) {
      final g = <String>{};
      for (var i = 0; i + 1 < s.length; i++) {
        g.add(s.substring(i, i + 2));
      }
      return g;
    }

    final ga = grams(a);
    final gb = grams(b);
    if (ga.isEmpty || gb.isEmpty) return 0;
    return (200 * ga.intersection(gb).length) ~/
        (ga.length + gb.length);
  }

  // -- manifest -----------------------------------------------------------------

  /// Validates an addon root (name + search/stream resources).
  /// Cached 10 minutes; throws on unreachable/invalid.
  Future<AddonManifest> manifestFor(String root) async {
    final cached = _manifests[root];
    if (cached != null &&
        DateTime.now().difference(cached.at) <
            const Duration(minutes: 10)) {
      return cached.manifest;
    }
    final path = '${Uri.parse(root).path}manifest.json';
    final res = await _dio.get<Map<String, dynamic>>(
      '${root}manifest.json',
      options: Options(headers: _signHeaders('GET', root, path)),
    ).timeout(const Duration(seconds: 12));
    final manifest = AddonManifest.fromJson(res.data ?? const {});
    if (!manifest.isUsable) {
      throw const FormatException('Not a usable addon (manifest)');
    }
    _manifests[root] = (manifest: manifest, at: DateTime.now());
    return manifest;
  }

  // -- search ---------------------------------------------------------------------

  Future<List<AddonTrack>> searchTracks(String query,
      {int limit = 15}) async {
    for (final root in bases) {
      try {
        final path = '${Uri.parse(root).path}search';
        final res = await _dio.get<Map<String, dynamic>>(
          '${root}search',
          queryParameters: {
            'q': query,
            'quality': 'lossless',
            'atmos': 'none',
          },
          options: Options(headers: _signHeaders('GET', root, path)),
        ).timeout(const Duration(seconds: 12));
        final data = res.data ?? const {};
        final tracks = data['tracks'];
        if (tracks is! List) continue;
        final out = tracks
            .whereType<Map<String, dynamic>>()
            .map(AddonTrack.fromJson)
            .where((t) => t.id.isNotEmpty && t.title.isNotEmpty)
            .take(limit)
            .toList();
        if (out.isNotEmpty) return out;
      } on DioException catch (e) {
        if (e.response?.statusCode == 429) rethrow;
        continue;
      } catch (_) {
        continue;
      }
    }
    return const [];
  }

  static String _clean(String s) {
    var v = s.toLowerCase();
    v = v.replaceAll(RegExp(r"['’`]"), '');
    v = v.replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ');
    return v.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// Verified match: title dice ≥ 90, artist token-compatible, duration
  /// within 8s when both known. Strict — a wrong track is worse than
  /// falling through to YouTube.
  static AddonTrack? bestMatch(
    List<AddonTrack> candidates, {
    required String title,
    required String artist,
    int expectedDurationSeconds = 0,
  }) {
    AddonTrack? best;
    var bestScore = -1;
    for (final c in candidates) {
      final titleScore =
          dice(_clean(c.title), _clean(title));
      if (titleScore < 90) continue;
      if (!_artistOk(c.artist, artist)) continue;
      if (expectedDurationSeconds > 0 && c.durationSeconds > 0) {
        if ((c.durationSeconds - expectedDurationSeconds).abs() > 8) {
          continue;
        }
      }
      if (titleScore > bestScore) {
        bestScore = titleScore;
        best = c;
      }
    }
    return best;
  }

  static bool _artistOk(String candidate, String target) {
    final a = _clean(candidate);
    final b = _clean(target);
    if (a.isEmpty || b.isEmpty) return false;
    if (a == b) return true;
    const stop = {
      'the', 'and', 'feat', 'ft', 'featuring', 'with', 'x', '&'
    };
    Set<String> toks(String s) =>
        s.split(' ').where((t) => t.isNotEmpty && !stop.contains(t)).toSet();
    final ta = toks(a);
    final tb = toks(b);
    return ta.isNotEmpty &&
        tb.isNotEmpty &&
        (tb.containsAll(ta) || ta.containsAll(tb));
  }

  // -- stream URL ------------------------------------------------------------------

  /// Server quality knob per desktop tier (atmos never requested).
  static List<String> serverQualitiesForTier(int tier) {
    switch (tier) {
      case 27:
      case 7:
        return const ['hi_res', 'lossless', 'high'];
      case 6:
        return const ['lossless', 'hi_res', 'high'];
      case 5:
        return const ['high', 'lossless'];
      default:
        return const ['hi_res', 'lossless', 'high'];
    }
  }

  /// Server `sampleRate` is Hz (44100/48000/96000…); normalize to the
  /// kHz the [ResolvedStream] model (and the output sheet) expects.
  /// Missing values fall back per tier. Pure for unit tests.
  static double khzFromServerSampleRate(Object? raw,
      {required bool hiRes}) {
    final hz = raw is num
        ? raw.toDouble()
        : double.tryParse(raw?.toString() ?? '') ??
            (hiRes ? 96000.0 : 44100.0);
    final khz = hz > 1000 ? hz / 1000 : hz;
    // Sanity clamp: drop absurd values back to tier defaults rather
    // than showing "0 kHz" or "192000 kHz" downstream.
    if (khz < 8 || khz > 768) return hiRes ? 96.0 : 44.1;
    // Round to one decimal so 44.056-style upstream values render clean.
    return (khz * 10).roundToDouble() / 10;
  }

  /// Decoy honeypot URLs must never play: an unsigned or mis-signed
  /// call answers 200 with a prank MP3 instead of an error.
  static bool isDecoyUrl(String url) {
    final v = url.toLowerCase();
    return v.contains('pranks-cdn') || v.contains('definatelynagato');
  }

  Future<ResolvedStream?> _fetchTrack(
    String root,
    String trackId,
    String serverQuality, {
    required String title,
    required String artist,
  }) async {
    final path = '${Uri.parse(root).path}stream/$trackId';
    late final Map<String, dynamic> data;
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        '${root}stream/$trackId',
        queryParameters: {
          'quality': serverQuality,
          'atmos': 'none',
        },
        options: Options(headers: _signHeaders('GET', root, path)),
      ).timeout(const Duration(seconds: 15));
      _recordQuota(root, res.headers);
      data = res.data ?? const {};
    } on DioException catch (e) {
      _recordQuota(root, e.response?.headers);
      if (e.response?.statusCode == 429) {
        throw AddonQuotaException.fromResponse(e.response);
      }
      return null;
    } catch (_) {
      return null;
    }
    return _toResolvedStream(
      root,
      trackId,
      serverQuality,
      data,
      title: title,
      artist: artist,
    );
  }

  void _recordQuota(String root, Headers? headers) {
    // Quota state arrives on stream responses; refreshed opportunistically.
    if (headers == null) return;
    int? num(String k) {
      final v = headers.value(k);
      return v == null ? null : int.tryParse(v);
    }

    final limit = num('x-quota-limit');
    final used = num('x-quota-used');
    final remaining = num('x-quota-remaining');
    if (limit != null || used != null || remaining != null) {
      quotaByBase[root] = AddonQuota(
        limit: limit ?? 500,
        used: used ?? 0,
        remaining: remaining ?? 0,
      );
    }
  }

  /// Map a stream payload onto [ResolvedStream]. Returns null when
  /// unplayable (miss payload, decoy, empty). Never throws.
  Future<ResolvedStream?> _toResolvedStream(
    String root,
    String trackId,
    String serverQuality,
    Map<String, dynamic> data, {
    required String title,
    required String artist,
  }) async {
    final urls = [
      data['url'],
      data['dataUrl'],
      data['directUrl'],
      data['streamUrl'],
      data['downloadUrl'],
      data['mediaUrl'],
    ].map((e) => e?.toString() ?? '').where((e) => e.isNotEmpty).toList();
    if (urls.any(isDecoyUrl)) return null;
    final manifestXml = data['manifestXml']?.toString() ?? '';
    if (manifestXml.contains('pranks-cdn') ||
        manifestXml.contains('definatelynagato')) {
      return null;
    }

    final hiRes = serverQuality == 'hi_res';
    final mp3 = serverQuality == 'high';
    final bitDepth =
        (data['bitDepth'] as num?)?.toInt() ?? (hiRes ? 24 : 16);
    // Server speaks Hz (e.g. 48000); the model is kHz. Anything above
    // 1000 must be Hz — without this the sheet shows "48000.0 kHz"
    // and the bitrate explodes by the same 1000× (depth×rate×2).
    final sampleRate =
        khzFromServerSampleRate(data['sampleRate'], hiRes: hiRes);
    final bitrateKbps = mp3
        ? 320
        : hiRes
            ? (bitDepth * sampleRate * 2).toInt()
            : 1411;
    final codec = mp3 ? 'MP3 320k' : hiRes ? 'HI-RES FLAC' : 'LOSSLESS';
    final host = Uri.tryParse(root)?.host ?? 'addon';
    final cacheKey = 'addon:$host:$trackId:$serverQuality';
    final expiresAt =
        DateTime.now().add(const Duration(minutes: 10));

    // Inline DASH manifest (manifestXml / data: URI) can't be handed
    // to libmpv directly — materialize it like the Tidal assembler.
    String? inlineManifest = manifestXml.isNotEmpty ? manifestXml : null;
    inlineManifest ??= () {
      for (final u in urls) {
        if (u.startsWith('data:')) {
          final comma = u.indexOf(',');
          if (comma < 0) continue;
          try {
            return utf8.decode(base64Decode(u.substring(comma + 1)));
          } catch (_) {
            continue;
          }
        }
      }
      return null;
    }();
    if (inlineManifest != null && inlineManifest.contains('<MPD')) {
      final file = await _writeManifestFile(trackId, inlineManifest);
      if (file == null) return null;
      return ResolvedStream(
        url: file,
        mimeType: 'application/dash+xml',
        bitrateKbps: bitrateKbps,
        audioCodec: codec,
        cacheKey: cacheKey,
        isLossless: !mp3,
        bitDepth: bitDepth,
        samplingRateKhz: sampleRate,
        expiresAt: expiresAt,
      );
    }

    final direct = urls.firstWhere(
      (u) => !u.startsWith('data:'),
      orElse: () => '',
    );
    if (direct.isEmpty) return null;
    // Remote .mpd goes straight to libmpv (signed, headerless per
    // protocol); progressive files likewise.
    final lower = direct.split('?').first.toLowerCase();
    final isMpd = lower.endsWith('.mpd');
    final mime = isMpd
        ? 'application/dash+xml'
        : lower.endsWith('.mp3')
            ? 'audio/mpeg'
            : (lower.endsWith('.m4a') || lower.endsWith('.mp4'))
                ? 'audio/mp4'
                : 'audio/flac';
    return ResolvedStream(
      url: direct,
      mimeType: mime,
      bitrateKbps: bitrateKbps,
      audioCodec: codec,
      cacheKey: cacheKey,
      isLossless: !mp3,
      bitDepth: bitDepth,
      samplingRateKhz: sampleRate,
      expiresAt: expiresAt,
    );
  }

  Future<String?> _writeManifestFile(
      String trackId, String xml) async {
    try {
      final safeId =
          trackId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      final dir = Directory(
          '${Directory.systemTemp.path}${Platform.pathSeparator}lastwave_addon');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final file = File(
          '${dir.path}${Platform.pathSeparator}$safeId.mpd');
      await file.writeAsString(xml, flush: true);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  // -- LosslessSource ---------------------------------------------------------------

  String _streamCacheKey(String title, String artist, int tier) =>
      'addon:${_clean(title)}|${_clean(artist)}|$tier';

  @override
  void invalidateStream(
      {required String title, required String artist}) {
    final prefix = 'addon:${_clean(title)}|${_clean(artist)}|';
    _streamCache.invalidateWhere((key) => key.startsWith(prefix));
  }

  @override
  void clearStreamCache() => _streamCache.clear();

  @override
  Future<ResolvedStream?> resolveStream({
    required String title,
    required String artist,
    String album = '',
    int expectedDurationSeconds = 0,
    int preferredQuality = 27,
  }) async {
    if (!isConfigured) return null;
    if (preferredQuality == -1) return null;
    if (title.trim().isEmpty || artist.trim().isEmpty) return null;
    final cacheKey =
        _streamCacheKey(title, artist, preferredQuality);
    final cached = _streamCache.get(cacheKey);
    if (cached != null) return cached;
    final pending = _inflight[cacheKey];
    if (pending != null) return pending;
    final future = _resolveStreamUncached(
      title: title,
      artist: artist,
      album: album,
      expectedDurationSeconds: expectedDurationSeconds,
      preferredQuality: preferredQuality,
    );
    _inflight[cacheKey] = future;
    try {
      final stream = await future;
      if (stream != null) _streamCache.put(cacheKey, stream);
      return stream;
    } finally {
      _inflight.remove(cacheKey);
    }
  }

  Future<ResolvedStream?> _resolveStreamUncached({
    required String title,
    required String artist,
    required String album,
    required int expectedDurationSeconds,
    required int preferredQuality,
  }) async {
    final cleanT = _clean(title);
    final cleanA = _clean(artist);
    final queries = {
      if (cleanA.isNotEmpty && cleanT.isNotEmpty) '$cleanA $cleanT',
      if (cleanA.isNotEmpty && cleanT.isNotEmpty) '$cleanT $cleanA',
      if (cleanT.isNotEmpty) cleanT,
      '$title $artist',
    }.where((q) => q.trim().isNotEmpty).take(4);
    for (final q in queries) {
      List<AddonTrack> items;
      try {
        items = await searchTracks(q);
      } on AddonQuotaException {
        rethrow;
      } catch (_) {
        continue;
      }
      final match = bestMatch(
        items,
        title: title,
        artist: artist,
        expectedDurationSeconds: expectedDurationSeconds,
      );
      if (match == null) continue;
      for (final serverQuality
          in serverQualitiesForTier(preferredQuality)) {
        for (final root in bases) {
          try {
            final stream = await _fetchTrack(
              root,
              match.id,
              serverQuality,
              title: title,
              artist: artist,
            );
            if (stream != null) return stream;
          } on AddonQuotaException {
            rethrow;
          } catch (_) {
            continue;
          }
        }
      }
      return null;
    }
    return null;
  }
}

/// Validated addon identity document.
class AddonManifest {
  final String id;
  final String name;
  final String version;
  final List<String> resources;

  const AddonManifest({
    required this.id,
    required this.name,
    required this.version,
    this.resources = const [],
  });

  factory AddonManifest.fromJson(Map<String, dynamic> json) {
    final resources = json['resources'];
    return AddonManifest(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      version: json['version']?.toString() ?? '',
      resources: resources is List
          ? resources.map((e) => e.toString()).toList()
          : const [],
    );
  }

  bool get isUsable {
    if (id.isEmpty || name.isEmpty) return false;
    final lower = resources.map((r) => r.toLowerCase()).toSet();
    return lower.contains('search') && lower.contains('stream');
  }
}

/// One catalog track from addon search.
class AddonTrack {
  final String id;
  final String title;
  final String artist;
  final String album;
  final int durationSeconds;
  final String format;
  final String audioQuality;

  const AddonTrack({
    required this.id,
    required this.title,
    this.artist = '',
    this.album = '',
    this.durationSeconds = 0,
    this.format = '',
    this.audioQuality = '',
  });

  factory AddonTrack.fromJson(Map<String, dynamic> json) {
    final duration = json['duration'];
    return AddonTrack(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      artist: json['artist']?.toString() ?? '',
      album: json['album']?.toString() ?? '',
      durationSeconds: duration is num
          ? duration.toInt()
          : (double.tryParse(duration?.toString() ?? '') ?? 0)
              .toInt(),
      format: json['format']?.toString() ?? '',
      audioQuality: json['audioQuality']?.toString() ?? '',
    );
  }
}

/// Quota snapshot from stream-response headers.
class AddonQuota {
  final int limit;
  final int used;
  final int remaining;

  const AddonQuota({
    this.limit = 500,
    this.used = 0,
    this.remaining = 0,
  });
}

/// Thrown when the daily addon quota is exhausted. Callers fall
/// through to YouTube AND surface the notice (never hard-fail).
class AddonQuotaException implements Exception {
  final int retryAfterSeconds;
  final int remaining;
  final String message;

  const AddonQuotaException({
    required this.retryAfterSeconds,
    required this.remaining,
    required this.message,
  });

  factory AddonQuotaException.fromResponse(Response? res) {
    int retry = 0;
    final raw = res?.headers.value('retry-after') ?? '';
    retry = int.tryParse(raw) ?? 0;
    int remaining = 0;
    final remRaw = res?.headers.value('x-quota-remaining');
    if (remRaw != null) remaining = int.tryParse(remRaw) ?? 0;
    var message = 'Daily addon quota reached — resets at UTC midnight.';
    try {
      final data = res?.data;
      final decoded = data is String ? jsonDecode(data) : data;
      final err = decoded is Map ? decoded['error']?.toString() : null;
      if (err != null && err.isNotEmpty) message = err;
    } catch (_) {}
    return AddonQuotaException(
      retryAfterSeconds: retry,
      remaining: remaining,
      message: message,
    );
  }
}

/// One-shot quota notice for the InfoBar host. Set by playback on
/// [AddonQuotaException], cleared on dismiss.
final addonNoticeProvider = StateProvider<String?>((_) => null);

/// The lossless tier. Addon URLs (Settings → Sources) are the only
/// lossless catalog — the baked-in Qobuz/Tidal backend was removed.
/// With no URLs configured this still constructs (unconfigured), so
/// every consumer falls through to YouTube without branching.
final losslessApiProvider = Provider<LosslessSource>((ref) {
  return AddonApi(ref.watch(prefsProvider).addonUrls);
});

/// Validated manifest per addon root (null = unreachable/invalid).
/// Always a throwaway client (manifest fetches are user-triggered
/// and rare; this also keeps this module free of the provider in
/// `lossless_api.dart`, which would be an import cycle).
final addonManifestProvider =
    FutureProvider.family<AddonManifest?, String>((ref, base) async {
  try {
    return await AddonApi([base]).manifestFor(base);
  } catch (_) {
    return null;
  }
});
