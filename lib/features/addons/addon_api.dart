import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/stream_models.dart';
import '../../core/diagnostics/trace_crumb.dart';
import '../../core/env/app_env.dart';
import '../../core/matching/match_vocab.dart';
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

  /// Tracks whose lossless chain completed without a stream. That chain
  /// is the most expensive thing in a cold start — search plus up to six
  /// mints at ~1.4s each (measured 5-12s) — and the outcome is stable
  /// for minutes, so replaying the track must not re-pay it. Misses are
  /// not permanent: [invalidateStream] (player failure / manual retry)
  /// clears them, and the TTL bounds a transient backend outage.
  final Map<String, DateTime> _misses = {};
  static const Duration _missTtl = Duration(minutes: 10);
  static const int _maxMisses = 64;

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
  bool get isConfigured => bases.isNotEmpty;

  // -- URL parsing ------------------------------------------------------------

  /// Accepts a full addon root (trailing slash optional), a manifest
  /// URL, or a deeper addon URL (stream/…). Supports tokenized addon
  /// roots (`{base}/a/<token>/`) and standalone/worker addon roots
  /// (`https://host/`).
  static ({String root, String token})? parseAddonUrl(
      String raw) {
    var v = raw.trim();
    if (v.isEmpty) return null;

    final uri = Uri.tryParse(v);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return null;
    }

    v = v.replaceAll(RegExp(r'/+$'), '');
    v = v.replaceAll(RegExp(r'/manifest(\.json)?$', caseSensitive: false), '');

    final m =
        RegExp(r'^(https?://[^/?#]+)/a/([^/?#]+)').firstMatch(v);
    if (m != null) {
      final token = m.group(2)!;
      if (!RegExp(r'^[0-9a-fA-F]{16,}$').hasMatch(token)) {
        return null;
      }
      return (root: '${m.group(1)}/a/$token/', token: token);
    }

    // Malformed /a/ paths without a valid token are rejected.
    if (RegExp(r'^(https?://[^/?#]+)/a(/.*)?$').hasMatch(v)) {
      return null;
    }

    var cleanPath = uri.path.replaceAll(RegExp(r'/+$'), '');
    cleanPath = cleanPath.replaceAll(
        RegExp(r'/manifest(\.json)?$', caseSensitive: false), '');
    cleanPath = cleanPath.replaceAll(
        RegExp(r'/(stream|search)(/.*)?$', caseSensitive: false), '');

    final origin =
        '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
    final root = cleanPath.isEmpty || cleanPath == '/'
        ? '$origin/'
        : '$origin$cleanPath/';

    return (root: root, token: '');
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
    final token = tokenOfRoot(root);
    if (_secret.isEmpty || token.isEmpty) {
      return {
        'User-Agent': 'LastWave-Player/1.0',
      };
    }
    final ts =
        (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
    return signFor(
        secret: _secret,
        method: method,
        path: path,
        token: token,
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
      {int limit = 15, String quality = 'lossless', bool atmos = false}) async {
    for (final root in bases) {
      try {
        final path = '${Uri.parse(root).path}search';
        final res = await _dio.get<Map<String, dynamic>>(
          '${root}search',
          queryParameters: {
            'q': query,
            'quality': quality,
            'atmos': atmos ? 'auto' : 'none',
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
    v = v.replaceAll(RegExp(r'\$(?=\d)'), '');
    v = v.replaceAll(r'$', 's');
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

  /// Soundtrack-source billing: `(From "Desi Boyz")`,
  /// `[From the movie X]`, `(Music From ...)`, trailing `- From "X"`.
  /// It names the film the song belongs to, never a different
  /// recording, so it must not push a canonical catalog entry below
  /// the title gate ("Subha Hone Na De (From "Desi Boyz")" used to
  /// score 87 against the request and lose to a mashup).
  static final RegExp _fromClause = RegExp(
      r'''(?:[\(\[]\s*(?:music |songs |original motion picture soundtrack |original soundtrack )?from\b[^\)\]]*[\)\]]|\s+-\s+from\b.*$)''',
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

  /// Film/series name from a soundtrack billing clause ("desi boyz" from
  /// `Subha Hone Na De (From "Desi Boyz")`). Empty when the title carries
  /// none. Used to identify composer-billed soundtrack rows whose catalog
  /// entry credits the performers instead.
  static String _fromPart(String title) {
    final m = _fromClause.firstMatch(title);
    if (m == null) return '';
    var inner = m.group(0)!;
    inner = inner.replaceAll(RegExp(r'^[\(\[]\s*'), '');
    inner = inner.replaceAll(RegExp(r'[\)\]]\s*$'), '');
    inner = inner.replaceAll(RegExp(r'^\s*-\s*'), '');
    inner = inner.replaceAll(
        RegExp(
            r'^\s*(?:music|songs|original motion picture soundtrack|original soundtrack)?\s*from\s+',
            caseSensitive: false),
        '');
    return _clean(inner);
  }

  /// Feature fidelity bonus: distinguishes the remix from the original.
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
  /// Label filler that never distinguishes recordings: parental tags,
  /// upload labels and the bare feat keywords left over after the credit
  /// itself is removed. Real version billing (remix/live/acoustic/edit/
  /// …, remixer names, extra vocalists) is NOT here.
  static const Set<String> _versionNeutralWords =
      MatchVocab.neutralWords;

  /// Dash-separated title forms for bilingual billing
  /// ("よあけのうた - Yoake no uta" → whole + each half): the catalog
  /// may hold either script, so every half scores as its own form.
  /// Android parity (`LosslessMusicApi.parseTitle` keeps the non-artist
  /// tail as the core); the artist gate still rejects true mismatches.
  /// Halves without a letter are skipped ("10:15" must not match "10").
  /// `/` never splits (`AC/DC`).
  static List<String> _titleForms(String title) {
    final forms = <String>[title];
    final seen = <String>{title.toLowerCase()};
    for (final half in title.split(_titleHalfSeparator)) {
      final h = half.trim();
      if (h.length < 2 || !seen.add(h.toLowerCase())) continue;
      if (!RegExp(r'\p{L}', unicode: true).hasMatch(h)) continue;
      forms.add(h);
    }
    return forms;
  }

  static final RegExp _titleHalfSeparator =
      RegExp(r'\s*[-–—:|]+\s*');

  /// Title comparison over all bilingual forms: max raw/stripped dice
  /// plus stripped-exact across whole×whole, halves×whole and
  /// whole×halves. Short-script halves ("Yoake no uta") match a
  /// romaji catalog entry exactly even when the request carries kana.
  static ({int raw, int stripped, bool exact}) _titleScore(
      String candidateTitle, String wantedTitle) {
    final wantForms = _titleForms(wantedTitle);
    final compositeRequest = wantForms.length > 1;
    final candForms = _titleForms(candidateTitle);
    bool isLatin(String s) => RegExp(r'[A-Za-z]').hasMatch(s);
    // A candidate half is a bilingual device: it may stand in when the
    // other half is written in a different script ("kana - Yoake no
    // uta"). When the remaining billing is Latin it is another song
    // title instead, and the composite is a mashup — serving "Sooraj
    // Dooba Hain-Subha Hone Na De" for "Subha Hone Na De" is exactly
    // the wrong recording this guards against. A composite request
    // (both halves queued) keeps splitting on both sides.
    bool halfMayStandIn(String cf) {
      if (compositeRequest || cf == candidateTitle) return true;
      return candForms
          .where((h) => h != candidateTitle && h != cf)
          .every((h) => !isLatin(h));
    }

    final wantStrippedForms = wantForms.map(_strippedTitle).toList();
    var raw = 0;
    var stripped = 0;
    var exact = false;
    for (final wf in wantForms) {
      final cleanW = _clean(wf);
      for (final cf in candForms) {
        if (!halfMayStandIn(cf)) continue;
        final cleanC = _clean(cf);
        raw = max(raw, dice(cleanC, cleanW));
        final strippedC = _strippedTitle(cf);
        for (final ws in wantStrippedForms) {
          stripped = max(
              stripped, max(dice(cleanC, ws), dice(strippedC, ws)));
          if (strippedC == ws && ws.isNotEmpty) exact = true;
        }
      }
    }
    return (raw: raw, stripped: stripped, exact: exact);
  }

  /// Tokens that make a title a different recording: the feat credit
  /// plus leftover version billing, minus artist-name echoes (catalog
  /// `swap_` composites echo "title feat artist artist") and label
  /// filler. A candidate is a faithful version of a request when its
  /// set is a subset of the request's: "… [Explicit]" and bare/bracket
  /// feat spellings pass, a remix with an extra vocalist does not —
  /// even though [bestMatches] ranks the remix below the original,
  /// the resolver used to *serve* it once the top entry's fetch 502'd.
  static Set<String> _distinguishingTokens(
      String title, Set<String> artistTokens) {
    final feat = _featPart(title)
        .split(' ')
        .where((t) => t.isNotEmpty)
        .toSet();
    final stripped = _strippedTitle(title)
        .split(' ')
        .where((t) => t.isNotEmpty)
        .toSet();
    final cleanToks = _clean(title)
        .split(' ')
        .where((t) => t.isNotEmpty)
        .toSet();
    // Soundtrack billing is stripped from the comparison title, so its
    // tokens would otherwise land in the residual and make the canonical
    // entry ("Subha Hone Na De (From "Desi Boyz")") look like a
    // different recording. It names the film, never a version.
    final fromToks = <String>{
      for (final m in _fromClause.allMatches(title))
        ..._clean(m.group(0)!).split(' ').where((t) => t.isNotEmpty)
    };
    final residual = cleanToks
        .difference(stripped)
        .difference(feat)
        .difference(_versionNeutralWords)
        .difference(fromToks);
    // Bracket-independent version billing: the strip regexes only catch
    // bracketed/bare-tail spellings, so a bare "Song Remix" or
    // "Song Slowed + Reverb" would otherwise leave zero residual and
    // look faithful. Any shared-vocab version word is distinguishing
    // unless the request names it (subset check below).
    final versionToks = cleanToks
        .intersection(MatchVocab.versionWords)
        .difference(MatchVocab.neutralWords);
    return feat.union(residual).union(versionToks).difference(artistTokens);
  }

  /// Whether [candidateTitle] is the requested recording (not just the
  /// same song): it must add no feat credit or version billing beyond
  /// the request, in ANY bilingual form (either script alone may carry
  /// the match). The stream resolver serves only faithful versions —
  /// anything else falls through to YouTube's match instead of playing
  /// the wrong recording in lossless.
  static bool isFaithfulVersion(String candidateTitle,
      {required String title,
      required String artist,
      bool allowAtmos = false}) {
    final artistTokens = _clean(artist)
        .split(' ')
        .where((t) => t.isNotEmpty)
        .toSet();
    final wantDists = _titleForms(title)
        .map((f) => _distinguishingTokens(f, artistTokens))
        .toList();
    const atmosTokens = {'atmos', 'dolby', 'spatial'};
    for (final cf in _titleForms(candidateTitle)) {
      final cd = _distinguishingTokens(cf, artistTokens);
      if (wantDists.any((wd) {
        final diff = cd.difference(wd);
        if (diff.isEmpty) return true;
        if (allowAtmos && diff.difference(atmosTokens).isEmpty) return true;
        return false;
      })) {
        return true;
      }
    }
    return false;
  }
  /// Comparison-only stripped title: "Dracula (feat. JENNIE)" → "dracula",
  /// "Starboy [Explicit]" → "starboy". Queries still use [_clean].
  static String _strippedTitle(String s) {
    var v = s.replaceAll(_featClause, ' ');
    v = v.replaceAll(_versionClause, ' ');
    v = v.replaceAll(_fromClause, ' ');
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
  /// within 8s when both known. Ranking is (title, feat fidelity,
  /// duration, raw, album): the JENNIE remix beats the original when the
  /// queue asked for the remix, and vice versa. Strict — a wrong track is
  /// worse than falling through to YouTube — but feat/version noise no
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
  /// The resolver walks the same-version head of this list so a
  /// server-side stream failure (HTTP 502 minting one entry, as seen on
  /// a `swap_`-prefixed Starboy composite) falls through to another
  /// entry of the SAME recording instead of dropping to YouTube —
  /// while a different version (remix/feat-variant) is never attempted,
  /// so a fetch failure degrades to YouTube's correct match.
  static List<AddonTrack> bestMatches(
    List<AddonTrack> candidates, {
    required String title,
    required String artist,
    int expectedDurationSeconds = 0,
    String album = '',
  }) {
    final scored = <({AddonTrack track, int title, int feat, int raw, int album})>[];
    final wantAlbum = _clean(album);
    for (final c in candidates) {
      // Bilingual-aware: any dash-separated half may carry the match
      // ("よあけのうた - Yoake no uta" vs a romaji catalog entry).
      // Exact-after-strip ("dracula" == "dracula (feat jennie)")
      // passes even though raw dice is ~50 on short bases.
      final ts = _titleScore(c.title, title);
      final rawScore = ts.raw;
      final titleScore =
          rawScore > ts.stripped ? rawScore : ts.stripped;
      if (!ts.exact && titleScore < 90) continue;
      final feat = _featBonus(c.title, title);
      var albumBonus = 0;
      if (wantAlbum.isNotEmpty) {
        final cal = _clean(c.album);
        final fromTitle = _fromPart(c.title);
        if (cal == wantAlbum || fromTitle == wantAlbum) {
          albumBonus = 2;
        } else if (cal.isNotEmpty &&
            (cal.contains(wantAlbum) || wantAlbum.contains(cal))) {
          albumBonus = 1;
        }
      }
      // Soundtrack rows are often billed to the film's composer
      // ("Subha Hone Na De" / Pritam, album "Desi Boyz") while the
      // catalog entry credits the performers (Mika Singh, Shefali
      // Alvares), so the artist gate can never pass. The film is then
      // the identity - but only on an exact album match: the title gate
      // still rejects other songs from it, and the version gate still
      // rejects a remix of this one.
      final artistOk = _artistOkFeatAware(
        cTitle: c.title,
        cArtist: c.artist,
        wantTitle: title,
        wantArtist: artist,
      );
      if (!artistOk && albumBonus < 2) continue;
      if (expectedDurationSeconds > 0 && c.durationSeconds > 0) {
        if ((c.durationSeconds - expectedDurationSeconds).abs() > 8) {
          continue;
        }
      }
      scored.add(
          (track: c, title: titleScore, feat: feat, raw: rawScore, album: albumBonus));
    }
    // Duration proximity. With a known length it separates the album
    // cut from the radio edit. Without one, trust catalog consensus:
    // the canonical master is the length most entries agree on, so a
    // lone 158s entry in a pool of 289s entries (Besharmi Ki Height)
    // loses instead of winning by pool order. Ranked after feat
    // fidelity and before the raw score, so it can never beat a better
    // title match.
    final knownDurations = [
      for (final e in scored)
        if (e.track.durationSeconds > 0) e.track.durationSeconds
    ]..sort();
    final durTarget = expectedDurationSeconds > 0
        ? expectedDurationSeconds
        : (knownDurations.isEmpty
            ? 0
            : knownDurations[knownDurations.length ~/ 2]);
    int durScore(AddonTrack t) {
      if (durTarget <= 0) return 0;
      if (t.durationSeconds <= 0) return -600;
      return -(t.durationSeconds - durTarget).abs();
    }

    scored.sort((a, b) {
      if (a.title != b.title) return b.title.compareTo(a.title);
      if (a.feat != b.feat) return b.feat.compareTo(a.feat);
      final ad = durScore(a.track);
      final bd = durScore(b.track);
      if (ad != bd) return bd.compareTo(ad);
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
        final cts = _titleScore(c.title, title);
        final rawScore = cts.raw;
        final titleScore =
            rawScore > cts.stripped ? rawScore : cts.stripped;
        String reason;
        if (!cts.exact && titleScore < 90) {
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

  /// Server quality knob per desktop tier.
  /// Tier 28 (Dolby Atmos) requests atmos first and steps down:
  /// atmos -> hi_res -> lossless -> high (matches Android).
  /// Stereo tiers (27, 7, 6, 5) never request atmos.
  static List<String> serverQualitiesForTier(int tier) {
    switch (tier) {
      case 28:
        return const ['atmos', 'hi_res', 'lossless', 'high'];
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

  /// True for E-AC-3 spatial codec labels. Pure; safe to unit-test.
  static bool isAtmosCodec(String? codec) {
    final c = (codec ?? '').trim().toLowerCase();
    return c.startsWith('ec-3') ||
        c.startsWith('eac3') ||
        c.startsWith('ac-3') ||
        c.contains('atmos');
  }

  /// True when the stream URL points to E-AC-3 spatial bytes.
  static bool isAtmosStreamUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('atmos') ||
        lower.contains('eac3') ||
        lower.contains('ec-3');
  }

  /// True for an Atmos/Spatial candidate track by backend flag, audio mode,
  /// or title billing (mirrors mobile LosslessMusicApi.isAtmosCandidate).
  static bool isAtmosCandidate(AddonTrack item) {
    if (item.isDolbyAtmos) return true;
    final modes = item.audioModes.map((m) => m.toLowerCase()).toList();
    if (modes.any((m) =>
        m.contains('360') ||
        m.contains('spatial') ||
        m.contains('atmos') ||
        m.contains('dolby'))) {
      return true;
    }
    final lowerTitle = item.title.toLowerCase();
    return lowerTitle.contains('atmos') || lowerTitle.contains('dolby');
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

  /// A mint that has not answered by now is treated as a miss. The host
  /// normally answers in 0.5-0.9s; the measured cold-path outliers
  /// (6.1s and 10.1s on 2026-10-23) held the whole resolve chain and the
  /// prefetcher for the price of an Opus fallback. The miss memo retries
  /// the mint on a later play.
  static const Duration _mintTimeout = Duration(seconds: 4);

  /// Ceiling for all mint attempts of one resolve (every tier, candidate
  /// and base). Without it a host that stalls once stalls again on the
  /// next tier, and the matrix stacks 4s waits (`_mintTimeout` is per
  /// request, the loop walks up to 3 tiers x 2 candidates). YouTube
  /// answers from cache in ~0.7s, so a spent budget ends the search.
  static const Duration _mintBudget = Duration(seconds: 6);

  Future<ResolvedStream?> _fetchTrack(
    String root,
    String trackId,
    String serverQuality, {
    required bool wantAtmos,
    required bool isAtmosPreferred,
    required String title,
    required String artist,
    Duration timeout = _mintTimeout,
  }) async {
    final path = '${Uri.parse(root).path}stream/$trackId';
    Map<String, dynamic>? data;
    // One retry on transient mint failures (network blip, slow
    // server): cold first plays otherwise fall back to Opus for no
    // reason and only succeed on manual replay. 429/quota is
    // definitive and never retries; a timeout already burned the whole
    // budget and never retries.
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final res = await _dio.get<Map<String, dynamic>>(
          '${root}stream/$trackId',
          queryParameters: {
            'quality': serverQuality,
            'atmos': wantAtmos ? 'auto' : 'none',
          },
          options: Options(headers: _signHeaders('GET', root, path)),
        ).timeout(timeout);
        _recordQuota(root, res.headers);
        data = res.data ?? const {};
        break;
      } on TimeoutException {
        TraceCrumb.write('resolve stage=stream-timeout tier=$serverQuality '
            'budget_ms=${timeout.inMilliseconds}');
        return null;
      } on DioException catch (e) {
        _recordQuota(root, e.response?.headers);
        if (e.response?.statusCode == 429) {
          throw AddonQuotaException.fromResponse(e.response);
        }
        if (attempt == 0) {
          // One quick retry: a transient mint failure clears on the
          // second request, and the host answers in ~0.5s. The old
          // fixed 600ms wait was pure dead time on the cold path.
          TraceCrumb.write('resolve stage=stream-retry tier=$serverQuality '
              'after_ms=150');
          await Future.delayed(const Duration(milliseconds: 150));
          continue;
        }
        return null;
      } catch (_) {
        if (attempt == 0) {
          TraceCrumb.write('resolve stage=stream-retry tier=$serverQuality '
              'after_ms=150');
          await Future.delayed(const Duration(milliseconds: 150));
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
      wantAtmos: wantAtmos,
      isAtmosPreferred: isAtmosPreferred,
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
    required bool wantAtmos,
    required bool isAtmosPreferred,
    required String title,
    required String artist,
  }) async {
    final mlabel = 'key=${_clean(title)}|${_clean(artist)} '
        'server=$serverQuality';
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

    final isStreamAtmos = (data['atmos'] == true) ||
        (data['audioMode']?.toString().toUpperCase().contains('ATMOS') == true) ||
        (data['quality']?.toString().toUpperCase().contains('ATMOS') == true) ||
        isAtmosCodec(data['codec']?.toString()) ||
        urls.any(isAtmosStreamUrl);

    // Atmos isolation: a hi-res/CD/320 request must never come home as Dolby
    // (matches Android: "Atmos plays only when explicitly selected").
    if (!isAtmosPreferred && isStreamAtmos) {
      if (kDebugMode) {
        debugPrint(
            'LastWaveAddon: skipping spatial stream for track $trackId (stereo tier requested)');
      }
      return null;
    }
    if (!wantAtmos && urls.any(isAtmosStreamUrl)) {
      return null;
    }

    final hiRes = serverQuality == 'hi_res';
    final mp3 = serverQuality == 'high';
    final bitDepth = isStreamAtmos
        ? 16
        : ((data['bitDepth'] as num?)?.toInt() ?? (hiRes ? 24 : 16));
    // Server speaks Hz (e.g. 48000); the model is kHz. Anything above
    // 1000 must be Hz — without this the sheet shows "48000.0 kHz"
    // and the bitrate explodes by the same 1000× (depth×rate×2).
    final sampleRate = isStreamAtmos
        ? 48.0
        : khzFromServerSampleRate(data['sampleRate'], hiRes: hiRes);
    final bitrateKbps = isStreamAtmos
        ? ((data['bitrate'] as num?)?.toInt() ?? 768)
        : mp3
            ? 320
            : hiRes
                ? (bitDepth * sampleRate * 2).toInt()
                : 1411;
    final codec = isStreamAtmos
        ? 'DOLBY ATMOS'
        : mp3
            ? 'MP3 320k'
            : hiRes
                ? 'HI-RES FLAC'
                : 'LOSSLESS';
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
    if (!mp3 && !isStreamAtmos) {
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
      TraceCrumb.write('resolve stage=manifest $mlabel '
          'inline=true bytes=${inlineManifest.length}');
      final serverSw = Stopwatch()..start();
      final uri = await LocalMediaServer.instance.urlFor(
        manifestXml: inlineManifest,
        cacheName:
            '${Uri.tryParse(root)?.host ?? 'addon'}_${trackId}_$serverQuality',
      );
      serverSw.stop();
      TraceCrumb.write('resolve stage=server $mlabel '
          'ms=${serverSw.elapsedMilliseconds} hit=${uri != null}');
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
      final manifestSw = Stopwatch()..start();
      final xmlText = await _manifestText(direct);
      manifestSw.stop();
      // No inline XML in the payload → this is a second round-trip
      // after the mint. That hop is often the hidden cost of a cold
      // resolve (the addon returns a `.mpd` URL instead of the body).
      TraceCrumb.write('resolve stage=manifest $mlabel '
          'inline=false ms=${manifestSw.elapsedMilliseconds} '
          'hit=${xmlText != null}');
      final serverSw = Stopwatch()..start();
      final uri = xmlText != null
          ? await LocalMediaServer.instance.urlFor(
              manifestXml: xmlText,
              cacheName:
                  '${Uri.tryParse(root)?.host ?? 'addon'}_${trackId}_$serverQuality',
            )
          : null;
      serverSw.stop();
      TraceCrumb.write('resolve stage=server $mlabel '
          'ms=${serverSw.elapsedMilliseconds} hit=${uri != null}');
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
    final mime = isStreamAtmos
        ? 'audio/mp4'
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

  // v3: the album is part of the identity for composer-billed soundtrack
  // rows (same title+artist resolves differently with and without the
  // film), and pre-v3 rows could memoize a different recording version
  // (remix/mashup served for an original) under the same key. Old keys
  // miss and re-resolve through the same-version gate.
  String _streamCacheKey(String title, String artist, int tier,
          [String album = '']) =>
      'addon:v3:${_clean(title)}|${_clean(artist)}|$tier|${_clean(album)}';

  @override
  void invalidateStream(
      {required String title, required String artist}) {
    final prefix = 'addon:v3:${_clean(title)}|${_clean(artist)}|';
    _streamCache.invalidateWhere((key) => key.startsWith(prefix));
    _misses.removeWhere((key, _) => key.startsWith(prefix));
  }

  @override
  void clearStreamCache() {
    _streamCache.clear();
    _misses.clear();
  }

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
        _streamCacheKey(title, artist, preferredQuality, album);
    // Latency trail: the resolve chain (search → stream → manifest) is
    // the whole cold-start cost, and these lines are the only way to
    // see where it goes after the fact (`<temp>/lastwave/mpv-ops.log`).
    final label = 'key=${_clean(title)}|${_clean(artist)} '
        'q=$preferredQuality';
    final cached = _streamCache.get(cacheKey);
    if (cached != null) {
      TraceCrumb.write('resolve $label cache=hit');
      return cached;
    }
    final missedAt = _misses[cacheKey];
    if (missedAt != null) {
      if (DateTime.now().difference(missedAt) < _missTtl) {
        // Known miss: skip the 5-12s chain and let YouTube answer.
        TraceCrumb.write('resolve $label cache=negative');
        return null;
      }
      _misses.remove(cacheKey);
    }
    final pending = _inflight[cacheKey];
    if (pending != null) {
      TraceCrumb.write('resolve $label cache=inflight');
      return pending;
    }
    TraceCrumb.write('resolve $label cache=miss');
    final totalSw = Stopwatch()..start();
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
      if (stream != null) {
        _streamCache.put(cacheKey, stream);
        _misses.remove(cacheKey);
      } else {
        _rememberMiss(cacheKey);
      }
      TraceCrumb.write('resolve $label '
          'result=${stream == null ? 'miss' : 'hit'} '
          'total_ms=${totalSw.elapsedMilliseconds}');
      return stream;
    } finally {
      _inflight.remove(cacheKey);
    }
  }

  void _rememberMiss(String key) {
    try {
      _misses.remove(key);
      _misses[key] = DateTime.now();
      while (_misses.length > _maxMisses) {
        _misses.remove(_misses.keys.first);
      }
    } catch (_) {}
  }

  /// Search queries for a resolve: the two cleaned orders plus the raw
  /// billing, then bilingual dash-halves (tail first — Android keeps the
  /// non-artist tail as the core, so "よあけのうた - Yoake no uta" also
  /// searches pure romaji). Capped so the concurrent fan-out stays
  /// bounded; the pool is re-ranked once, so order only breaks ties.
  static List<String> searchQueries(String title, String artist) {
    final cleanT = _clean(title);
    final cleanA = _clean(artist);
    final out = <String>[];
    void add(String q) {
      final t = q.trim();
      if (t.isNotEmpty && !out.contains(t)) out.add(t);
    }

    if (cleanA.isNotEmpty && cleanT.isNotEmpty) {
      add('$cleanA $cleanT');
      add('$cleanT $cleanA');
    }
    final halves = _titleForms(title);
    if (halves.length > 1 && cleanA.isNotEmpty) {
      for (var i = halves.length - 1; i >= 1; i--) {
        final h = _clean(halves[i]);
        if (h.isNotEmpty && h != cleanT) add('$h $cleanA');
      }
    }
    add('$title $artist');
    return out.take(4).toList();
  }

  Future<ResolvedStream?> _resolveStreamUncached({
    required String title,
    required String artist,
    required String album,
    required int expectedDurationSeconds,
    required int preferredQuality,
  }) async {
    // Same key shape the player logs, so the two trails join up.
    final label = 'key=${_clean(title)}|${_clean(artist)} '
        'q=$preferredQuality';
    final totalSw = Stopwatch()..start();
    // One query first. The addon host serializes per token, so 3-4
    // queries issued concurrently still cost 3-4 round trips (measured
    // 1.5-2.0s at ~530ms each) and search ends up ~60% of a successful
    // cold resolve. The cleaned "artist title" pairing carries the
    // right recording in nearly every resolve; the remaining queries
    // (reversed billing, bilingual halves, raw) are a recall fallback
    // that only runs when the first pass yields no faithful version.
    final queries = searchQueries(title, artist);
    // Pool candidates across every query that ran, then rank once:
    // per-query winners with stripped-only scoring re-introduce the
    // exact bug being fixed (original beats remix). bestMatches ranks
    // by (title, feat fidelity, raw, album), so one call over the pool
    // picks the right version and survives 30-item page burial.
    final pool = <AddonTrack>[];
    final seenIds = <String>{};
    var queriesOk = 0;
    // Search with the tier's primary knob (Android parity): entries
    // tagged only for other tiers are server-filtered otherwise.
    final isAtmosPreferred =
        preferredQuality == AudioQualityTiers.dolbyAtmos;
    final searchQuality = isAtmosPreferred
        ? 'lossless'
        : serverQualitiesForTier(preferredQuality).first;
    final searchSw = Stopwatch()..start();

    // Runs [batch] concurrently and merges into the pool in query order.
    // Per-query failures contribute nothing; a quota rejection still
    // aborts the resolve. Returns how many queries answered.
    Future<int> searchAll(Iterable<String> batch) async {
      final list = batch.toList();
      if (list.isEmpty) return 0;
      final searched = await Future.wait(
        list.map((q) async {
          try {
            final items = await searchTracks(q,
                limit: 30,
                quality: searchQuality,
                atmos: isAtmosPreferred);
            return (true, items);
          } on AddonQuotaException {
            rethrow;
          } catch (_) {
            return (false, const <AddonTrack>[]);
          }
        }),
      );
      var ok = 0;
      for (final (good, items) in searched) {
        if (!good) continue;
        ok++;
        for (final item in items) {
          if (seenIds.add(item.id)) pool.add(item);
        }
      }
      return ok;
    }

    List<AddonTrack> rankedPool() => bestMatches(
          pool,
          title: title,
          artist: artist,
          album: album,
          expectedDurationSeconds: expectedDurationSeconds,
        ).toList();

    List<AddonTrack> faithfulOf(List<AddonTrack> ranked) => ranked
        .where((c) => isFaithfulVersion(c.title,
            title: title, artist: artist, allowAtmos: isAtmosPreferred))
        .take(isAtmosPreferred ? 4 : 3)
        .toList();

    queriesOk += await searchAll(queries.take(1));
    var ranked = rankedPool();
    var matches = faithfulOf(ranked);
    if (matches.isEmpty && queries.length > 1) {
      // Recall fallback: fan out the rest, then re-rank the union once
      // (exactly the old all-at-once semantics). Costs one extra round
      // trip only on tracks the addon does not carry.
      queriesOk += await searchAll(queries.skip(1));
      ranked = rankedPool();
      matches = faithfulOf(ranked);
      TraceCrumb.write('resolve stage=search-fallback $label '
          'queries=${queries.length} ok=$queriesOk '
          'kept=${matches.length}');
    }
    searchSw.stop();
    final searchMs = searchSw.elapsedMilliseconds;
    // Search is a fan-out at one throttled host: `queries` vs `ms` is
    // the number that says whether the fan-out is the cold-start cost.
    TraceCrumb.write('resolve stage=search $label ms=$searchMs '
        'queries=${queries.length} ok=$queriesOk '
        'pool=${pool.length} bases=${bases.length}');
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
    // Only faithful versions are attempted: entries that add a feat
    // credit or version billing the request never named (remix/live/
    // cover, a different vocalist) are skipped; serving them plays the
    // wrong song, while a miss falls through to YouTube's (correct) match.
    // This is the actual "Don’t Let Me Down" bug: the top
    // `swap_` entry 502’d and the walk degraded into a remix.
    if (ranked.isEmpty) {
      if (kDebugMode) {
        debugPrint('LastWave-Timing addon title="$title" '
            'search_ms=$searchMs fetch_ms=0 result=no-match');
      }
      return null;
    }
    final top = ranked.first;
    if (matches.isEmpty) {
      if (kDebugMode) {
        debugPrint('LastWaveAddon stage=version-skip title="$title" '
            'top="${top.title}" reason=no-faithful-version');
        debugPrint('LastWave-Timing addon title="$title" '
            'search_ms=$searchMs fetch_ms=0 result=version-skip');
      }
      return null;
    }
    if (kDebugMode && matches.length < ranked.length) {
      debugPrint('LastWaveAddon stage=version-skip title="$title" '
          'top="${top.title}" kept=${matches.length}/${ranked.length}');
    }

    // When Atmos is preferred, prioritize Atmos candidate tracks first;
    // for stereo tiers, prioritize stereo candidate tracks first.
    final orderedMatches = isAtmosPreferred
        ? [
            ...matches.where(isAtmosCandidate),
            ...matches.where((m) => !isAtmosCandidate(m)),
          ]
        : [
            ...matches.where((m) => !isAtmosCandidate(m)),
            ...matches.where(isAtmosCandidate),
          ];

    TraceCrumb.write('resolve stage=match $label pool=${pool.length} '
        'ranked=${ranked.length} kept=${matches.length} '
        'at_ms=${totalSw.elapsedMilliseconds}');
    var fetchAttempts = 0;
    final fetchSw = Stopwatch()..start();
    // All mint attempts of this resolve share one budget; each request
    // gets whatever is left, so a stalling host costs one wait, not a
    // matrix of them.
    final mintSw = Stopwatch()..start();
    for (final serverQuality in serverQualitiesForTier(preferredQuality)) {
      final wantAtmos = serverQuality == 'atmos';
      final targetCandidates = wantAtmos
          ? (orderedMatches.where(isAtmosCandidate).isNotEmpty
              ? orderedMatches.where(isAtmosCandidate).toList()
              : orderedMatches)
          : (orderedMatches.where((m) => !isAtmosCandidate(m)).isNotEmpty
              ? orderedMatches.where((m) => !isAtmosCandidate(m)).toList()
              : orderedMatches);

      for (final match in targetCandidates.take(wantAtmos ? 3 : 2)) {
        for (final root in bases) {
          try {
            final remaining = _mintBudget - mintSw.elapsed;
            if (remaining <= const Duration(milliseconds: 400)) {
              TraceCrumb.write('resolve stage=stream-budget $label '
                  'spent_ms=${mintSw.elapsedMilliseconds} '
                  'attempts=$fetchAttempts result=exhausted');
              return null;
            }
            final timeout =
                remaining < _mintTimeout ? remaining : _mintTimeout;
            fetchAttempts++;
            final fetchOneSw = Stopwatch()..start();
            final stream = await _fetchTrack(
              root,
              match.id,
              serverQuality,
              wantAtmos: wantAtmos,
              isAtmosPreferred: isAtmosPreferred,
              title: title,
              artist: artist,
              timeout: timeout,
            );
            fetchOneSw.stop();
            // One line per mint: which tier, how many attempts, how
            // long, and whether it produced a playable stream.
            TraceCrumb.write('resolve stage=stream $label '
                'tier=$serverQuality attempt=$fetchAttempts '
                'ms=${fetchOneSw.elapsedMilliseconds} '
                'result=${stream == null ? 'miss' : 'hit'}');
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
            TraceCrumb.write('resolve stage=stream $label '
                'tier=$serverQuality result=quota');
            rethrow;
          } catch (_) {
            TraceCrumb.write('resolve stage=stream $label '
                'tier=$serverQuality attempt=$fetchAttempts result=error');
            continue;
          }
        }
      }
      if (kDebugMode) {
        // One entry's mint failed on every tier (e.g. HTTP 502 on a
        // `swap_` composite) — the loop tries the next entry of the
        // SAME version rather than degrading into a remix.
        debugPrint('LastWaveAddon stage=fetch-fail '
            'tier=$serverQuality attempts=$fetchAttempts');
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
  final bool atmos;
  final String audioMode;
  final List<String> audioModes;
  final String quality;

  const AddonTrack({
    required this.id,
    required this.title,
    this.artist = '',
    this.album = '',
    this.durationSeconds = 0,
    this.format = '',
    this.audioQuality = '',
    this.atmos = false,
    this.audioMode = '',
    this.audioModes = const [],
    this.quality = '',
  });

  factory AddonTrack.fromJson(Map<String, dynamic> json) {
    final duration = json['duration'];
    final modes = json['audioModes'];
    return AddonTrack(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      artist: json['artist']?.toString() ?? '',
      album: json['album']?.toString() ?? '',
      durationSeconds: duration is num
          ? duration.toInt()
          : (double.tryParse(duration?.toString() ?? '') ?? 0).toInt(),
      format: json['format']?.toString() ?? '',
      audioQuality: json['audioQuality']?.toString() ??
          json['audio_quality']?.toString() ??
          json['quality']?.toString() ??
          '',
      atmos: json['atmos'] == true,
      audioMode: json['audioMode']?.toString() ?? '',
      audioModes: modes is List
          ? modes.map((e) => e.toString()).toList()
          : const [],
      quality: json['quality']?.toString() ?? '',
    );
  }

  bool get isDolbyAtmos =>
      atmos ||
      audioMode.toUpperCase().contains('ATMOS') ||
      audioMode.toUpperCase().contains('DOLBY') ||
      audioModes.any((m) =>
          m.toUpperCase().contains('ATMOS') ||
          m.toUpperCase().contains('DOLBY')) ||
      RegExp(r'atmos|dolby|eac3[_-]?joc|ec-?3', caseSensitive: false).hasMatch(
        '$audioQuality $quality $format $audioMode ${audioModes.join(" ")}',
      );
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
