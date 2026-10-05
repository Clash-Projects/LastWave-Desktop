import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/stream_models.dart';
import '../../core/env/app_env.dart';
import '../../core/network/dio_factory.dart';
import '../../core/storage/prefs.dart';
import '../lossless/lossless_source.dart';
import 'local_media_server.dart';

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

  /// Searches one addon base. [quality] is the tier's primary knob
  /// (`hi_res` for 27/7, `lossless` for 6, `high` for 5 — Android
  /// parity: `LosslessMusicApi` searches with the tier, not hardcoded
  /// `lossless`). The server filters by it, so a hardcoded value hides
  /// entries tagged only for other tiers (e.g. a hi_res-only original
  /// invisible at the default tier 27). Tier fallback still happens at
  /// fetch time via [serverQualitiesForTier].
  Future<List<AddonTrack>> searchTracks(String query,
      {int limit = 15, String quality = 'lossless'}) async {
    for (final root in bases) {
      try {
        final path = '${Uri.parse(root).path}search';
        final res = await _dio.get<Map<String, dynamic>>(
          '${root}search',
          queryParameters: {
            'q': query,
            'quality': quality,
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

  /// Bracketed feature clause, e.g. "Dracula (feat. JENNIE)" / "[ft. X]" /
  /// "(with JENNIE)". Bracketed "with" is near-always a feature credit
  /// (unlike a bare trailing "with", which would eat titles like
  /// "Dance With Somebody"). Mirrors InnerTube `_featuringClause`
  /// (comparison only, never queries).
  static final RegExp _featClause = RegExp(
      r'[\(\[]\s*(feat(?:uring)?|ft|with)\.?\s+[^\)\]]*[\)\]]',
      caseSensitive: false);

  /// Bracketed version noise, e.g. "(Explicit)" / "[Remastered 2011]".
  /// Mirrors InnerTube `_versionClause`.
  static final RegExp _versionClause = RegExp(
      r'[\(\[][^\)\]]*(live|remix|acoustic|demo|edit|remaster(?:ed)?|mono|stereo|explicit|clean|slowed|sped up|nightcore)[^\)\]]*[\)\]]',
      caseSensitive: false);

  /// Bare trailing version tags without brackets ("Starboy Explicit",
  /// "Song Single Version", "Track - Radio Edit"). Anchored at the end
  /// so "Live Forever" keeps its leading "live".
  static final RegExp _trailingVersion = RegExp(
      r'\s+(?:-\s+)?(?:explicit|clean|single version|single|radio edit|radio|edit|live|acoustic|demo|remaster(?:ed)?(?: \d{4})?|mono|stereo|slowed|sped up|nightcore)\s*$',
      caseSensitive: false);

  /// Bare trailing "feat. X" without brackets ("Dracula feat JENNIE").
  static final RegExp _trailingFeat = RegExp(
      r'\s+(?:feat(?:uring)?|ft)\.?\s+.+$',
      caseSensitive: false);

  /// Raw feature-credit substring from a title ("JENNIE" from both
  /// "Dracula (feat. JENNIE)" and "Dracula feat JENNIE"), cleaned.
  /// Empty when the title carries no feature credit.
  static String _featPart(String title) {
    final m1 = _featClause.firstMatch(title);
    if (m1 != null) {
      var inner = m1.group(0)!;
      inner = inner.replaceAll(RegExp(r'^[\(\[]\s*'), '');
      inner = inner.replaceAll(RegExp(r'[\)\]]\s*$'), '');
      inner = inner.replaceAll(
          RegExp(r'^(?:feat(?:uring)?|ft|with)\.?\s+',
              caseSensitive: false),
          '');
      return _clean(inner);
    }
    final m2 = _trailingFeat.firstMatch(title);
    if (m2 != null) {
      var tail = m2.group(0)!;
      tail = tail.replaceAll(
          RegExp(r'^\s+(?:feat(?:uring)?|ft)\.?\s+',
              caseSensitive: false),
          '');
      return _clean(tail);
    }
    return '';
  }

  /// Feature fidelity bonus: distinguishes the remix from the original
  /// when stripping equates them ("dracula" == "dracula (feat jennie)").
  /// Wanted-feat must match candidate-feat; otherwise the player serves
  /// the original when the user queued the remix (or vice versa).
  /// A *different* featured artist ranks lowest: it is a different
  /// recording, while the base song is the more faithful fallback.
  static int _featBonus(String candidateTitle, String wantedTitle) {
    final c = _featPart(candidateTitle);
    final w = _featPart(wantedTitle);
    if (w.isEmpty && c.isEmpty) return 2;
    if (w.isNotEmpty && c.isNotEmpty) {
      if (c == w) return 3;
      final ct = c.split(' ').toSet();
      final wt = w.split(' ').toSet();
      if (ct.intersection(wt).isNotEmpty) return 1;
      return -3; // different featured artists (1nonly vs JENNIE)
    }
    if (w.isNotEmpty) return -2; // wanted remix, got original
    return -1; // wanted original, got remix
  }
  /// Comparison-only stripped title: "Dracula (feat. JENNIE)" → "dracula",
  /// "Starboy [Explicit]" → "starboy". Queries still use [_clean].
  static String _strippedTitle(String s) {
    var v = s.replaceAll(_featClause, ' ');
    v = v.replaceAll(_versionClause, ' ');
    v = v.replaceAll(_trailingFeat, ' ');
    var prev = '';
    v = _clean(v);
    // Repeat trailing-version strip: "Song Single Version Explicit".
    while (v != prev) {
      prev = v;
      v = _clean(v.replaceAll(_trailingVersion, ' '));
    }
    return v;
  }

  /// First billed artist for collab billing ("A; B; C" → "A",
  /// "Tame Impala feat. JENNIE" → "Tame Impala"). Mirrors InnerTube
  /// `primaryArtistForMatch` so the addon tier retries like playback.
  static String primaryArtistForMatch(String artist) {
    var s = artist.split(';').first.trim();
    if (s.isEmpty) return '';
    s = s
        .split(RegExp(
          r'\s+[(\[]?(?:feat\.?|ft\.?|featuring)\b',
          caseSensitive: false,
        ))
        .first
        .trim();
    if (s.isEmpty) return '';
    if (RegExp(r',\s*(the|and)\b', caseSensitive: false).hasMatch(s) &&
        !s.contains(' & ')) {
      return s;
    }
    final lower = s.toLowerCase();
    if (lower == 'unknown artist' ||
        lower == 'various artists' ||
        lower == 'unknown') {
      return '';
    }
    return s.split(RegExp(r'\s*[,&]\s*')).first.trim();
  }

  /// Verified match: title dice ≥ 90 on raw OR stripped comparison
  /// (stripped-exact always passes), artist token-compatible (with
  /// primary-artist retry + title feature-credit fallback), duration
  /// within 8s when both known. Ranking is (title, feat fidelity, raw,
  /// album): the JENNIE remix beats the original when the queue asked
  /// for the remix, and vice versa. Strict — a wrong track is worse
  /// than falling through to YouTube — but feat/version noise no
  /// longer counts as a different song.
  static AddonTrack? bestMatch(
    List<AddonTrack> candidates, {
    required String title,
    required String artist,
    int expectedDurationSeconds = 0,
    String album = '',
  }) {
    final ranked = bestMatches(
      candidates,
      title: title,
      artist: artist,
      expectedDurationSeconds: expectedDurationSeconds,
      album: album,
    );
    return ranked.isEmpty ? null : ranked.first;
  }

  /// All passing candidates, best first under the same ranking.
  /// The resolver walks this list so a server-side stream failure
  /// (HTTP 502 minting one entry, as seen on a `swap_`-prefixed
  /// Starboy composite) falls through to the next-best version
  /// instead of dropping to YouTube.
  static List<AddonTrack> bestMatches(
    List<AddonTrack> candidates, {
    required String title,
    required String artist,
    int expectedDurationSeconds = 0,
    String album = '',
  }) {
    final scored = <({AddonTrack track, int title, int feat, int raw, int album})>[];
    final wantStripped = _strippedTitle(title);
    final wantAlbum = _clean(album);
    for (final c in candidates) {
      final rawScore = dice(_clean(c.title), _clean(title));
      final candStripped = _strippedTitle(c.title);
      final s1 = dice(_clean(c.title), wantStripped);
      final s2 = dice(candStripped, wantStripped);
      final strippedScore = s1 > s2 ? s1 : s2;
      // Exact-after-strip ("dracula" == "dracula (feat jennie)")
      // passes even though raw dice is ~50 on short bases.
      final strippedExact = _strippedTitle(c.title) == wantStripped &&
          wantStripped.isNotEmpty;
      final titleScore = rawScore > strippedScore ? rawScore : strippedScore;
      if (!strippedExact && titleScore < 90) continue;
      if (!_artistOkFeatAware(
        cTitle: c.title,
        cArtist: c.artist,
        wantTitle: title,
        wantArtist: artist,
      )) {
        continue;
      }
      if (expectedDurationSeconds > 0 && c.durationSeconds > 0) {
        if ((c.durationSeconds - expectedDurationSeconds).abs() > 8) {
          continue;
        }
      }
      final feat = _featBonus(c.title, title);
      var albumBonus = 0;
      if (wantAlbum.isNotEmpty && c.album.isNotEmpty) {
        final cal = _clean(c.album);
        if (cal == wantAlbum) {
          albumBonus = 2;
        } else if (cal.contains(wantAlbum) || wantAlbum.contains(cal)) {
          albumBonus = 1;
        }
      }
      scored.add(
          (track: c, title: titleScore, feat: feat, raw: rawScore, album: albumBonus));
    }
    scored.sort((a, b) {
      if (a.title != b.title) return b.title.compareTo(a.title);
      if (a.feat != b.feat) return b.feat.compareTo(a.feat);
      if (a.raw != b.raw) return b.raw.compareTo(a.raw);
      return b.album.compareTo(a.album);
    });
    if (kDebugMode && scored.isEmpty && candidates.isNotEmpty) {
      // Show why the gate rejected everything: top-3 by raw score
      // with candidate artist/album/duration and the reject stage.
      final byRaw = candidates
          .map((c) => MapEntry(
              c, dice(_clean(c.title), _clean(title))))
          .toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final top = byRaw.take(3).map((e) {
        final c = e.key;
        final rawScore = dice(_clean(c.title), _clean(title));
        final candStripped = _strippedTitle(c.title);
        final s1 = dice(_clean(c.title), wantStripped);
        final s2 = dice(candStripped, wantStripped);
        final strippedScore = s1 > s2 ? s1 : s2;
        final strippedExact = candStripped == wantStripped &&
            wantStripped.isNotEmpty;
        final titleScore =
            rawScore > strippedScore ? rawScore : strippedScore;
        String reason;
        if (!strippedExact && titleScore < 90) {
          reason = 'title';
        } else if (!_artistOkFeatAware(
            cTitle: c.title,
            cArtist: c.artist,
            wantTitle: title,
            wantArtist: artist)) {
          reason = 'artist';
        } else if (expectedDurationSeconds > 0 &&
            c.durationSeconds > 0 &&
            (c.durationSeconds - expectedDurationSeconds).abs() > 8) {
          reason = 'duration';
        } else {
          reason = 'unknown';
        }
        return '"${c.title}" by "${c.artist}" '
            '(raw=$rawScore reason=$reason)';
      }).join(', ');
      debugPrint('LastWaveAddon stage=match-miss title="$title" '
          'artist="$artist" top=[$top]');
    }
    return scored.map((e) => e.track).toList();
  }

  /// Artist check with primary-artist retry plus title feature-credit
  /// fallback: the catalog may bill "Dracula feat JENNIE" with
  /// artist="Tame Impala" while the queue has artist="Tame Impala"
  /// and the credit only in the title (or vice versa — artist="JENNIE"
  /// with the credit only in the catalog title). Expanding both sides
  /// with their title credits closes that gap; plain mismatches
  /// (1nonly vs JENNIE) still fail.
  static bool _artistOkFeatAware({
    required String cTitle,
    required String cArtist,
    required String wantTitle,
    required String wantArtist,
  }) {
    if (_artistOkWithPrimary(cArtist, wantArtist)) return true;
    final cFeat = _featPart(cTitle);
    final wFeat = _featPart(wantTitle);
    final expC = cFeat.isNotEmpty ? '$cArtist $cFeat' : cArtist;
    final expW = wFeat.isNotEmpty ? '$wantArtist $wFeat' : wantArtist;
    if (_clean(expC) != _clean(cArtist) ||
        _clean(expW) != _clean(wantArtist)) {
      if (_artistOkWithPrimary(expC, expW)) return true;
    }
    return false;
  }

  /// Artist check with primary-artist retry: "The Weeknd; Daft Punk"
  /// and "Tame Impala feat. JENNIE" both match the catalog primary.
  static bool _artistOkWithPrimary(String candidate, String target) {
    if (_artistOk(candidate, target)) return true;
    final primary = primaryArtistForMatch(target);
    if (primary.isNotEmpty && _clean(primary) != _clean(target)) {
      if (_artistOk(candidate, primary)) return true;
    }
    final candidatePrimary = primaryArtistForMatch(candidate);
    if (candidatePrimary.isNotEmpty &&
        _clean(candidatePrimary) != _clean(candidate)) {
      if (_artistOk(candidatePrimary, target)) return true;
    }
    return false;
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
    Map<String, dynamic>? data;
    // One retry on transient mint failures (network blip, slow
    // server): cold first plays otherwise fall back to Opus for no
    // reason and only succeed on manual replay. 429/quota is
    // definitive and never retries.
    for (var attempt = 0; attempt < 2; attempt++) {
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
        break;
      } on DioException catch (e) {
        _recordQuota(root, e.response?.headers);
        if (e.response?.statusCode == 429) {
          throw AddonQuotaException.fromResponse(e.response);
        }
        if (attempt == 0) {
          await Future.delayed(const Duration(milliseconds: 600));
          continue;
        }
        return null;
      } catch (_) {
        if (attempt == 0) {
          await Future.delayed(const Duration(milliseconds: 600));
          continue;
        }
        return null;
      }
    }
    final resolved = data;
    if (resolved == null) return null;
    return _toResolvedStream(
      root,
      trackId,
      serverQuality,
      resolved,
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
    // Payload-shape breadcrumb (keys only, never values): tells us
    // whether the server offers a progressive URL next to the
    // manifest. Windows libmpv 0.36 cannot open a second DASH
    // manifest per process, so progressive (when present) wins.
    try {
      const keys = [
        'url',
        'dataUrl',
        'directUrl',
        'streamUrl',
        'downloadUrl',
        'mediaUrl',
        'manifestXml',
      ];
      final present = [
        for (final k in keys)
          if ((data[k]?.toString() ?? '').isNotEmpty) k,
      ];
      if (kDebugMode) {
        debugPrint(
            'LastWave-Addon: stream fields($trackId): ${present.join(',')}');
      }
    } catch (_) {}

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
    // Prefer a progressive `.flac` URL when the payload offers one
    // alongside a DASH manifest: native FLAC needs no transmux and
    // downloads land as `.flac` directly. Only for lossless tiers —
    // `high` (MP3) must never steal a FLAC URL meant for another tier.
    if (!mp3) {
      for (final u in urls) {
        if (u.startsWith('data:')) continue;
        if (u.split('?').first.toLowerCase().endsWith('.flac')) {
          return ResolvedStream(
            url: u,
            mimeType: 'audio/flac',
            bitrateKbps: bitrateKbps,
            audioCodec: codec,
            cacheKey: cacheKey,
            isLossless: true,
            bitDepth: bitDepth,
            samplingRateKhz: sampleRate,
            expiresAt: expiresAt,
          );
        }
      }
    }
    if (inlineManifest != null && inlineManifest.contains('<MPD')) {
      // Windows libmpv 0.36 dies on its second DASH manifest per
      // process, and full pre-assembly stalls first audio for tens
      // of seconds — so mpv streams the assembly live from loopback
      // while the same bytes tee to disk. Null only when the
      // manifest can't be served at all (callers fall through).
      final uri = await LocalMediaServer.instance.urlFor(
        manifestXml: inlineManifest,
        cacheName:
            '${Uri.tryParse(root)?.host ?? 'addon'}_${trackId}_$serverQuality',
      );
      if (uri == null) return null;
      return ResolvedStream(
        url: uri.toString(),
        mimeType: 'audio/mp4',
        bitrateKbps: bitrateKbps,
        audioCodec: codec,
        cacheKey: cacheKey,
        isLossless: !mp3,
        bitDepth: bitDepth,
        samplingRateKhz: sampleRate,
        // The file doesn't expire (signatures only gate minting);
        // the disk cache is the durable layer, memory follows along.
        expiresAt: DateTime.now().add(const Duration(hours: 24)),
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
    if (isMpd) {
      // Same rule as inline manifests: stream the assembly from
      // loopback, never hand mpv an MPD.
      final xmlText = await _manifestText(direct);
      final uri = xmlText != null
          ? await LocalMediaServer.instance.urlFor(
              manifestXml: xmlText,
              cacheName:
                  '${Uri.tryParse(root)?.host ?? 'addon'}_${trackId}_$serverQuality',
            )
          : null;
      if (uri == null) return null;
      return ResolvedStream(
        url: uri.toString(),
        mimeType: 'audio/mp4',
        bitrateKbps: bitrateKbps,
        audioCodec: codec,
        cacheKey: cacheKey,
        isLossless: !mp3,
        bitDepth: bitDepth,
        samplingRateKhz: sampleRate,
        expiresAt: DateTime.now().add(const Duration(hours: 24)),
      );
    }
    final mime = lower.endsWith('.mp3')
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

  /// Fetch a remote manifest document (plain text). Null unless it
  /// parses as an MPD — callers assemble it or fall through.
  Future<String?> _manifestText(String url) async {
    try {
      final res = await _dio
          .get<String>(url,
              options: Options(responseType: ResponseType.plain))
          .timeout(const Duration(seconds: 15));
      final text = res.data ?? '';
      return text.contains('<MPD') ? text : null;
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
    // Three queries, highest solo-hit-rate first: six concurrent
    // requests still shared the host throttle (~2.3s slowest), while
    // the dropped permutations (primary-artist, stripped-only,
    // title-only, title+album) almost never win the pooled ranking —
    // bestMatches re-ranks the union anyway, so recall is preserved.
    final queries = {
      if (cleanA.isNotEmpty && cleanT.isNotEmpty) '$cleanA $cleanT',
      if (cleanA.isNotEmpty && cleanT.isNotEmpty) '$cleanT $cleanA',
      '$title $artist',
    }.where((q) => q.trim().isNotEmpty).take(3);
    // Pool candidates across ALL queries, then rank once: per-query
    // winners with stripped-only scoring re-introduce the exact bug
    // being fixed (original beats remix). bestMatch already ranks by
    // (title, feat fidelity, raw, album), so one call over the pool
    // picks the right version and survives 30-item page burial.
    final pool = <AddonTrack>[];
    final seenIds = <String>{};
    var queriesOk = 0;
    // Search with the tier's primary knob (Android parity): entries
    // tagged only for other tiers are server-filtered otherwise.
    final searchQuality =
        serverQualitiesForTier(preferredQuality).first;
    final searchSw = Stopwatch()..start();
    // Fan out all queries concurrently: sequential round-trips were the
    // whole first-play delay (~4s of search). Results merge in query
    // order so the ranking input is identical to the old sequential
    // version; per-query failures still contribute nothing, and a quota
    // rejection still aborts the resolve like before.
    final queryList = queries.toList();
    final searched = await Future.wait(
      queryList.map((q) async {
        try {
          final items =
              await searchTracks(q, limit: 30, quality: searchQuality);
          return (true, items);
        } on AddonQuotaException {
          rethrow;
        } catch (_) {
          return (false, const <AddonTrack>[]);
        }
      }),
    );
    for (final (ok, items) in searched) {
      if (!ok) continue;
      queriesOk++;
      for (final item in items) {
        if (seenIds.add(item.id)) {
          pool.add(item);
        }
      }
    }
    searchSw.stop();
    final searchMs = searchSw.elapsedMilliseconds;
    if (kDebugMode && pool.isEmpty) {
      // No candidates at all: search failed/empty, not a gate reject
      // (bestMatch stays silent on empty input by design).
      debugPrint('LastWaveAddon stage=empty-pool title="$title" '
          'artist="$artist" queriesOk=$queriesOk search_ms=$searchMs');
      debugPrint('LastWave-Timing addon title="$title" '
          'search_ms=$searchMs fetch_ms=0 result=empty-pool');
      return null;
    }
    // Bound the worst case: each match fans out over qualities ×
    // bases with 15s timeouts, so only the top few are worth trying
    // before YouTube (which is instant from cache) wins on latency.
    final matches = bestMatches(
      pool,
      title: title,
      artist: artist,
      album: album,
      expectedDurationSeconds: expectedDurationSeconds,
    ).take(3).toList();
    if (matches.isEmpty) {
      if (kDebugMode) {
        debugPrint('LastWave-Timing addon title="$title" '
            'search_ms=$searchMs fetch_ms=0 result=no-match');
      }
      return null;
    }
    var fetchAttempts = 0;
    final fetchSw = Stopwatch()..start();
    for (final match in matches) {
      for (final serverQuality in serverQualitiesForTier(preferredQuality)) {
        for (final root in bases) {
          try {
            fetchAttempts++;
            final stream = await _fetchTrack(
              root,
              match.id,
              serverQuality,
              title: title,
              artist: artist,
            );
            if (stream != null) {
              fetchSw.stop();
              if (kDebugMode) {
                debugPrint('LastWave-Timing addon title="$title" '
                    'search_ms=$searchMs fetch_ms=${fetchSw.elapsedMilliseconds} '
                    'attempts=$fetchAttempts result=hit');
              }
              return stream;
            }
          } on AddonQuotaException {
            rethrow;
          } catch (_) {
            continue;
          }
        }
      }
      if (kDebugMode) {
        // One entry's mint failed on every tier (e.g. HTTP 502 on a
        // `swap_` composite) — the loop tries the next-best version
        // rather than dropping straight to YouTube.
        debugPrint('LastWaveAddon stage=fetch-fail id="${match.id}" '
            'title="${match.title}" attempts=$fetchAttempts');
      }
    }
    fetchSw.stop();
    if (kDebugMode) {
      debugPrint('LastWave-Timing addon title="$title" '
          'search_ms=$searchMs fetch_ms=${fetchSw.elapsedMilliseconds} '
          'attempts=$fetchAttempts result=miss');
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
