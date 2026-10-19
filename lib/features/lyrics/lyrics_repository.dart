import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../../core/network/dio_factory.dart';
import '../innertube/innertube_api.dart';
import 'lyrics_models.dart';
import 'lyrics_providers.dart';

final _diacriticsRegex = RegExp(r'\p{M}+', unicode: true);

/// Lyrics orchestrator with Apple Music lyrics via Lyrically.
///
/// Ported from LastWave-native `LyricsRepository.kt`:
/// - in-memory cache (word-synced entries preferred)
/// - always fetch Apple Music via lyrics.paxsenix.org (Lyrically) so
///   the correct lyrics win even when karaoke word-by-word is off;
///   `wordByWord` only controls syllable timings vs line display
/// - LRCLIB is the fallback when Lyrically has no match
/// - LRCLIB tiers: instrumental → synced LRC → plain → empty
String cleanSongTitle(String title) {
  var t = title;
  t = t.replaceAll(
      RegExp(
          r'\s*\([^)]*(?:official|video|audio|remaster|feat\b|ft\.?|featuring\b|live|version|edit|visualizer|lyrics?|hd|hq|4k|1080p|mv|m/v|full\s*song|full\s*video|full\s*audio|explicit|clean|deluxe|bonus|with|prod)[^)]*\)',
          caseSensitive: false),
      '');
  t = t.replaceAll(
      RegExp(
          r'\s*\[[^\]]*(?:official|video|audio|remaster|feat\b|ft\.?|featuring\b|live|version|edit|visualizer|lyrics?|hd|hq|4k|1080p|mv|m/v|full\s*song|full\s*video|full\s*audio|explicit|clean|deluxe|bonus|with|prod)[^\]]*\]',
          caseSensitive: false),
      '');
  t = t.replaceAll(
      RegExp(
          r'\s*[-–—|/:]\s*(?:official|video|audio|remaster|live|remastered|lyrics?|hd|hq|4k|1080p|mv|m/v|deluxe|bonus|visualizer|music\s*video|lyric\s*video|full\s*(?:song|video|audio)|prod).*$',
          caseSensitive: false),
      '');
  t = t.replaceAll(
      RegExp(r'\s+(?:feat\.?|ft\.?|featuring)\b.*$', caseSensitive: false),
      '');
  t = t.replaceAll(RegExp(r'[\s\-–—|/:]+$'), '').trim();
  return t.isNotEmpty ? t : title;
}

String cleanSongArtist(String artist) {
  var a = artist;
  a = a.replaceAll(RegExp(r'\s*-\s*Topic$', caseSensitive: false), '');
  a = a.replaceAll(
      RegExp(r'\s*[\(\[]\s*(?:feat\.?|ft\.?|featuring\b|with\b|prod\.?|produced by\b)[^\)\]]*[\)\]]', caseSensitive: false),
      '');
  a = a.replaceAll(
      RegExp(r'\s*(?:feat\.?|ft\.?|featuring\b|with\b).*$', caseSensitive: false),
      '');
  return a.trim().isNotEmpty ? a.trim() : artist;
}

/// Drop featuring clauses, bracketed noise, and punctuation so "ALL CAPS"
/// and "All Caps [Official Audio]" compare equal.
String normalizeLyricsTitle(String s) {
  var t = s
      .replaceAll(RegExp(r"[\u2018\u2019\u201A\u201B`']"), '')
      .replaceAll(RegExp(r'[\u201C\u201D\u201E\u201F"]'), ' ')
      .replaceAll(RegExp(r'[\u2013\u2014\u2212-]'), ' ');
  t = unorm.nfd(t.toLowerCase());
  t = t.replaceAll(_diacriticsRegex, '');
  t = t.replaceAll(RegExp(r'\$(?=\d)'), '');
  t = t.replaceAll(r'$', 's');
  t = t.replaceAll(RegExp(r'\[[^\]]*\]'), ' ');
  t = t.replaceAll(RegExp(r'\b(?:feat\.?|ft\.?|featuring)\b.*$'), ' ');
  t = t.replaceAll(RegExp(r'\(\s*\)'), ' ');
  t = t.replaceAll(RegExp(r'[\(\[]\s*$'), ' ');
  t = t.replaceAll(RegExp(r"[^\w\s()&]"), ' ');
  t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
  return t;
}

String _lyricsCoreTitle(String normalized) {
  return normalized
      .replaceAll(RegExp(r'\s*[\(\[].*?[\)\]]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// True only when [query] and [candidate] are the same song title.
/// Substring matches ("All Caps" ⊂ "Scene Three"? no; "All" ⊂ "All Caps"?
/// also no) are rejected so a different track cannot steal lyrics.
bool lyricsTitlesMatch(String query, String candidate) {
  // Version gate: recording versions (live, remix, acoustic, cover, interlude, etc.) must agree.
  // Gated first so cleaning packaging never causes alternate cuts to compare equal.
  if (!lyricsSameVersion(query, candidate)) return false;

  final cleanQ = cleanSongTitle(query);
  final cleanC = cleanSongTitle(candidate);
  var q = normalizeLyricsTitle(cleanQ);
  var c = normalizeLyricsTitle(cleanC);
  if (q.isEmpty || c.isEmpty) return false;
  if (q == c) return true;

  var qCore = _lyricsCoreTitle(q);
  var cCore = _lyricsCoreTitle(c);
  if (qCore.isEmpty || cCore.isEmpty || qCore != cCore) {
    final qStrip = normalizeLyricsTitle(stripLeadingArtistPrefix(cleanQ));
    final cStrip = normalizeLyricsTitle(stripLeadingArtistPrefix(cleanC));
    if (qStrip != q || cStrip != c) {
      final qStripCore = _lyricsCoreTitle(qStrip);
      final cStripCore = _lyricsCoreTitle(cStrip);
      if (qStripCore.isNotEmpty && qStripCore == cStripCore) {
        q = qStrip;
        c = cStrip;
        qCore = qStripCore;
        cCore = cStripCore;
      } else {
        return false;
      }
    } else {
      return false;
    }
  }

  String stripPackaging(String s) {
    var v = s.toLowerCase();
    v = v.replaceAll(
      RegExp(r'\b(official|video|audio|remaster(?:ed)?|feat|ft|featuring|with|prod|live|version|edit|visualizer|lyrics?|hd|hq|4k|mv|deluxe|bonus|clean|explicit|album|single|original)\b', caseSensitive: false),
      ' ',
    );
    return v.replaceAll(RegExp(r"[^\w]"), '').trim();
  }

  final qExtra = stripPackaging(q.replaceAll(qCore, ''));
  final cExtra = stripPackaging(c.replaceAll(cCore, ''));
  if (qExtra.isNotEmpty && cExtra.isEmpty) return false;
  if (qExtra.isEmpty && cExtra.isNotEmpty) return false;
  if (qExtra.isNotEmpty && cExtra.isNotEmpty && qExtra != cExtra) {
    return false;
  }
  return true;
}

String _normalizeLyricsArtist(String s) {
  var v = s
      .replaceAll(RegExp(r"[\u2018\u2019\u201A\u201B`']"), '')
      .replaceAll(RegExp(r'[\u201C\u201D\u201E\u201F"]'), ' ')
      .replaceAll(RegExp(r'[\u2013\u2014\u2212-]'), ' ');
  v = unorm.nfd(v.toLowerCase());
  v = v.replaceAll(_diacriticsRegex, '');
  v = v.replaceAll(RegExp(r'\$(?=\d)'), '');
  v = v.replaceAll(r'$', 's');
  return v;
}

Set<String> _extractArtistEntities(String rawArtist) {
  final cleaned = cleanSongArtist(rawArtist);
  final normalized = _normalizeLyricsArtist(cleaned).trim();
  final entities = <String>{};
  if (normalized.isNotEmpty) entities.add(normalized);
  final parts = normalized.split(
    RegExp(r'\s*[,/;&+]\s*|\s+(?:feat\.?|ft\.?|featuring|with|vs\.?|x)\s+',
        caseSensitive: false),
  );
  for (final p in parts) {
    final t = p.trim();
    if (t.isNotEmpty) entities.add(t);
  }
  return entities;
}

/// Artists match when equal, or collaborating entities match across delimiters
/// (&, /, ,, +, with, feat, vs, x) while preventing false positives.
bool lyricsArtistsMatch(String query, String candidate) {
  final q = _normalizeLyricsArtist(cleanSongArtist(query)).trim();
  final c = _normalizeLyricsArtist(cleanSongArtist(candidate)).trim();
  if (q.isEmpty || c.isEmpty) return false;
  if (q == c) return true;

  final qEntities = _extractArtistEntities(query);
  final cEntities = _extractArtistEntities(candidate);

  for (final qe in qEntities) {
    if (qe.length < 2) continue;
    for (final ce in cEntities) {
      if (ce.length < 2) continue;
      if (qe == ce) return true;
    }
  }

  final shorter = q.length <= c.length ? q : c;
  final longer = q.length <= c.length ? c : q;
  if (shorter.length >= 2) {
    final pattern =
        r'(^|(?:\s*[,&/;+]\s*|\s+(?:with|feat\.?|ft\.?|featuring|vs\.?|x)\s+))' +
        RegExp.escape(shorter) +
        r'($|(?:\s*[,&/;+]\s*|\s+(?:with|feat\.?|ft\.?|featuring|vs\.?|x)\s+))';
    if (RegExp(pattern, caseSensitive: false).hasMatch(longer)) {
      return true;
    }
  }
  return false;
}

bool lyricsIsAlternateRecording(String title, {String album = ''}) {
  final blob = '${title.toLowerCase()} ${album.toLowerCase()}';
  const alt = [
    'instrumental',
    'karaoke',
    'a cappella',
    'acapella',
    'minus one',
    'backing track',
  ];
  return alt.any(blob.contains);
}

bool lyricsDurationPlausible(int? querySeconds, num? candidateSeconds) {
  if (querySeconds == null || querySeconds <= 0) return true;
  if (candidateSeconds == null) return true;
  final candidate = candidateSeconds.round();
  if (candidate <= 0) return true;
  final diff = (candidate - querySeconds).abs();
  if (diff <= 25) return true;
  return diff <= 45 && (diff / querySeconds <= 0.18);
}

int lyricsUniqueLineCount(LyricsResult result) {
  final seen = <String>{};
  void add(String raw) {
    final n = normalizeLyricsTitle(raw);
    if (n.isNotEmpty) seen.add(n);
  }

  for (final line in result.lines) {
    add(line.text);
  }
  if (seen.isEmpty) {
    for (final line in result.plainLyrics.split('\n')) {
      add(line);
    }
  }
  return seen.length;
}

int _lyricsNonEmptyLineCount(LyricsResult result) {
  final fromLines =
      result.lines.where((l) => l.text.trim().isNotEmpty).length;
  if (fromLines > 0) return fromLines;
  return result.plainLyrics
      .split('\n')
      .where((l) => l.trim().isNotEmpty)
      .length;
}

/// Sample-hook / beat-only transcripts loop the same 4–8 lines. Real verses
/// do not. Used so "Overdue" does not keep Annie's "Anthonio" sample.
bool lyricsLooksLikeThinLoop(LyricsResult result) {
  if (result.isInstrumental) return false;
  final unique = lyricsUniqueLineCount(result);
  final total = _lyricsNonEmptyLineCount(result);
  if (total < 10) return false;
  return unique <= 8 && unique / total <= 0.45;
}

bool lyricsLooksLikePlaceholder(LyricsResult result) {
  final texts = <String>[
    for (final line in result.lines)
      if (line.text.trim().isNotEmpty) line.text.trim().toLowerCase(),
  ];
  if (texts.isEmpty) {
    texts.addAll(
      result.plainLyrics
          .split('\n')
          .map((l) => l.trim().toLowerCase())
          .where((l) => l.isNotEmpty),
    );
  }
  if (texts.isEmpty) return false;
  bool marker(String t) =>
      t == 'instrumental' ||
      t == '[instrumental]' ||
      t == '(instrumental)' ||
      t == '♪' ||
      t == '♫';
  return texts.every(marker);
}

/// True when a distinctive title actually appears in the lyric text.
/// Short/generic titles are skipped so they cannot veto a real match.
bool lyricsMentionsTitle(String title, LyricsResult result) {
  final core = _lyricsCoreTitle(normalizeLyricsTitle(cleanSongTitle(title)));
  if (core.length < 6) return false;
  if (RegExp(r'^(intro|outro|interlude|untitled|instrumental)$')
      .hasMatch(core)) {
    return false;
  }
  final blob = normalizeLyricsTitle(
    '${result.lines.map((l) => l.text).join(' ')} ${result.plainLyrics}',
  );
  return blob.contains(core);
}

/// Keep Lyrically/Apple text when word-by-word karaoke is off; drop
/// per-syllable timings so the UI stays line-synced.
LyricsResult lyricsForDisplayMode(
  LyricsResult result, {
  required bool wordByWord,
}) {
  if (wordByWord || !result.isWordSynced) return result;
  return LyricsResult(
    lines: [
      for (final line in result.lines)
        LyricLine(
          timeMs: line.timeMs,
          durationMs: line.durationMs,
          text: line.text,
          transliteration: line.transliteration,
        ),
    ],
    isSynced: result.isSynced,
    isWordSynced: false,
    plainLyrics: result.plainLyrics,
    isInstrumental: result.isInstrumental,
    source: result.source,
  );
}

class LyricsRepository {
  final Dio _dio;
  final InnerTubeMusicApi? _tube;

  /// Bounded LRU (insertion-ordered map): one entry per unique track
  /// incl. full karaoke syllable trees, so an unbounded map leaks
  /// across long sessions. 50 covers current + recent history;
  /// evicted tracks re-fetch on demand.
  static const _maxCacheEntries = 50;
  final Map<String, LyricsResult> _cache = {};

  /// Race tuning (constructor-injectable for tests; production uses the
  /// native-parity defaults: 4s preferred head start, 12s total race).
  final Duration preferredHeadStart;
  final Duration raceTotal;

  LyricsRepository([
    Dio? dio,
    this.preferredHeadStart = const Duration(seconds: 4),
    this.raceTotal = const Duration(seconds: 12),
    InnerTubeMusicApi? tube,
  ])  : _dio = dio ?? DioFactory.create(),
        _tube = tube;

  void _store(String key, LyricsResult value, {String queryTitle = ''}) {
    if (value.isEmpty) return;
    final existing = _cache[key];
    if (existing != null && !existing.isEmpty) {
      if (isBetterCandidate(existing, value, queryTitle: queryTitle)) {
        return;
      }
    }
    _cache
      ..remove(key)
      ..[key] = value;
    while (_cache.length > _maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
  }

  LyricsResult? _lookup(String key) {
    final hit = _cache.remove(key);
    if (hit == null) return null;
    // Refresh recency.
    _cache[key] = hit;
    return hit;
  }

  String _key(String title, String artist, [String album = '']) =>
      '${title.toLowerCase()}|${artist.toLowerCase()}|${album.toLowerCase()}';

  Future<LyricsResult> getLyrics({
    required String title,
    required String artist,
    String album = '',
    int? durationSeconds,
    bool forceRefresh = false,
    bool wordByWord = true,
    String? videoId,
    String preferredProviderId = 'auto',
    Set<String> excludeProviderIds = const {},
    void Function(LyricsResult partial)? onPartialResult,
  }) async {
    final preferred = LyricsProviderId.fromId(preferredProviderId);
    final excludes = excludeProviderIds.toSet();
    final sortedExcludes = excludes.toList()..sort();
    final key =
        '${_key(title, artist, album)}|${durationSeconds ?? 0}|$wordByWord|${preferred.id}|${sortedExcludes.join(',')}';
    if (!forceRefresh) {
      final cached = _lookup(key);
      // Empty results are never stored, so any cache hit is usable.
      // If word-by-word was requested, only return from cache immediately
      // if the cached entry is word-synced (or instrumental).
      // If the cached entry is only line-synced, stream it as an immediate
      // partial so the UI has lyrics instantly, but allow the race below
      // to seek a true word-synced version.
      if (cached != null) {
        if (!wordByWord || cached.isWordSynced || cached.isInstrumental) {
          onPartialResult?.call(cached);
          return lyricsForDisplayMode(cached, wordByWord: wordByWord);
        } else {
          onPartialResult?.call(lyricsForDisplayMode(cached, wordByWord: wordByWord));
        }
      }
    }

    LyricsResult? lineFallback;
    final wantsAlt = lyricsIsAlternateRecording(title, album: album);

    LyricsResult? normalize(LyricsResult? result) {
      if (result == null || result.isEmpty) return null;
      try {
        return normalizeKaraokeTimings(result);
      } catch (_) {
        // Never drop lyrics over a normalization edge: fall back to
        // the un-normalized result.
        return result;
      }
    }

    bool plausible(LyricsResult result) =>
        result.isInstrumental ||
        lyricsPlausibleDuration(result.lines, durationSeconds);

    LyricsResult display(LyricsResult result) =>
        lyricsForDisplayMode(result, wordByWord: wordByWord);

    Future<LyricsResult?> attempt(String providerId) {
      if (excludes.contains(providerId)) return Future.value(null);
      return fetchFromProvider(
        providerId,
        title: title,
        artist: artist,
        album: album,
        durationSeconds: durationSeconds,
        videoId: videoId,
      )
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => null,
          )
          .then<LyricsResult?>(
            (result) => normalize(result),
            onError: (_) => null,
          );
    }

    // Preferred non-word provider (LRCLIB, Musixmatch, Megalobiz, YouTube, Genius)
    // goes first so explicit choice is honored. A word-sync hit from anywhere later
    // can still supersede unless line mode was requested.
    var lrclibAttempted = false;
    LyricsResult? preferredFallback;
    if (preferred != LyricsProviderId.auto &&
        !preferred.isWordProvider &&
        !excludes.contains(preferred.id)) {
      if (preferred == LyricsProviderId.lrclib) lrclibAttempted = true;
      final first = normalize(await attempt(preferred.id));
      if (first != null) {
        if (first.isWordSynced || first.isSynced || (first.isInstrumental && wantsAlt) || !wordByWord) {
          _store(key, first, queryTitle: title);
          return display(first);
        }
        if (plausible(first)) {
          preferredFallback = first;
          lineFallback = first;
          onPartialResult?.call(display(first));
        }
      }
    }

    // Preferred word provider gets a bounded head start in both modes.
    // Word mode short-circuits on word-sync; line mode keeps the hit
    // as the top fallback (display strips it to lines). A matching
    // instrumental wins everywhere; anything plausible is stashed.
    if (preferred.isWordProvider && !excludes.contains(preferred.id)) {
      LyricsResult? single;
      try {
        single = normalize(await fetchFromProvider(
          preferred.id,
          title: title,
          artist: artist,
          album: album,
          durationSeconds: durationSeconds,
          videoId: videoId,
        ).timeout(preferredHeadStart));
      } on TimeoutException {
        single = null;
      } catch (_) {
        single = null;
      }
      if (single != null && plausible(single)) {
        if ((single.isWordSynced && wordByWord) ||
            (single.isSynced && !wordByWord) ||
            (single.isInstrumental && wantsAlt)) {
          _store(key, single, queryTitle: title);
          return display(single);
        }
        preferredFallback = single;
        lineFallback = single;
        onPartialResult?.call(display(single));
      }
    }

    Future<void> drainRace(List<Future<LyricsResult?>> pending) async {
      await for (final result in Stream.fromFutures(pending)) {
        if (result == null || result.isEmpty) continue;
        if (!plausible(result)) continue;
        if (result.isInstrumental && !wantsAlt) continue;
        final currentFallback = lineFallback;
        if (currentFallback == null ||
            isBetterCandidate(result, currentFallback,
                queryTitle: title)) {
          lineFallback = result;
          onPartialResult?.call(display(result));
        }
      }
    }

    if (wordByWord) {
      // Word race: fastest plausible word-sync wins; the first
      // plausible line result streams as a partial under the deadline.
      LyricsResult? raceWord;
      final pending = <Future<LyricsResult?>>[
        for (final id in const [
          'lastwave',
          'lrc_red',
          'apple_music',
          'better_lyrics',
          'better_lyrics_portato',
          'bini_lyrics',
          'lyrics_plus',
          'unison',
          'kugou',
          'simp_music',
          'lrclib',
        ])
          if (id != 'simp_music' || (videoId?.isNotEmpty ?? false))
            if (id != 'lrclib' || !lrclibAttempted)
              attempt(id),
      ];
      if (!lrclibAttempted) lrclibAttempted = true;
      Future<void> runRace() async {
        await for (final result in Stream.fromFutures(pending)) {
          if (result == null || result.isEmpty) continue;
          if (raceWord != null) continue;
          if (result.isWordSynced && plausible(result)) {
            if (!lyricsLooksLikePlaceholder(result) &&
                !lyricsLooksLikeThinLoop(result)) {
              raceWord = result;
              return;
            }
          }
          if (!plausible(result)) continue;
          if (result.isInstrumental && !wantsAlt) continue;
          final currentFallback = lineFallback;
          if (currentFallback == null ||
              isBetterCandidate(result, currentFallback,
                  queryTitle: title)) {
            lineFallback = result;
            onPartialResult?.call(display(result));
          }
        }
      }

      try {
        await runRace().timeout(raceTotal);
      } on TimeoutException {
        // Collected partials still count below.
      }
      final won = raceWord;
      if (won != null) {
        _store(key, won, queryTitle: title);
        return display(won);
      }
    } else {
      // Line mode: race all candidate providers for line sources under the deadline.
      final pending = <Future<LyricsResult?>>[
        for (final id in const [
          'lastwave',
          'lrc_red',
          'apple_music',
          'better_lyrics',
          'better_lyrics_portato',
          'bini_lyrics',
          'lyrics_plus',
          'unison',
          'kugou',
          'simp_music',
          'lrclib',
        ])
          if (id != 'simp_music' || (videoId?.isNotEmpty ?? false))
            if (id != 'lrclib' || !lrclibAttempted)
              attempt(id),
      ];
      if (!lrclibAttempted) lrclibAttempted = true;
      try {
        await drainRace(pending).timeout(raceTotal);
      } on TimeoutException {
        // Collected partials still count below.
      }
    }

    // Explicit choice outranks any other line-sync source.
    final preferredSettled = preferredFallback;
    if (preferredSettled != null) {
      _store(key, preferredSettled, queryTitle: title);
      return display(preferredSettled);
    }
    final lineSettled = lineFallback;
    if (lineSettled != null && lineSettled.isSynced) {
      _store(key, lineSettled, queryTitle: title);
      return display(lineSettled);
    }
    // Extra line-sync & plain catalogue after the race.
    final mxm = normalize(await attempt('musixmatch'));
    if (mxm != null && mxm.isSynced && plausible(mxm)) {
      _store(key, mxm, queryTitle: title);
      return display(mxm);
    }

    final mb = normalize(await attempt('megalobiz'));
    if (mb != null && mb.isSynced && plausible(mb)) {
      _store(key, mb, queryTitle: title);
      return display(mb);
    }

    if (videoId?.isNotEmpty ?? false) {
      final captions = normalize(await attempt('youtube_captions'));
      if (captions != null && captions.isSynced && plausible(captions)) {
        _store(key, captions, queryTitle: title);
        return display(captions);
      }
    }

    // LRCLIB line fallback (skipped when already tried as preferred).
    if (!lrclibAttempted) {
      final lrc = normalize(await attempt('lrclib'));
      if (lrc != null && lrc.isSynced && plausible(lrc)) {
        _store(key, lrc, queryTitle: title);
        return display(lrc);
      }
    }

    // Unsynced fallback if any provider returned unsynced/plain text earlier.
    if (lineSettled != null && !lineSettled.isEmpty) {
      _store(key, lineSettled, queryTitle: title);
      return display(lineSettled);
    }

    if (videoId?.isNotEmpty ?? false) {
      final ytm = normalize(await attempt('youtube_music'));
      if (ytm != null && plausible(ytm)) {
        _store(key, ytm, queryTitle: title);
        return display(ytm);
      }
    }

    // Genius static text fallback.
    final gn = normalize(await attempt('genius'));
    if (gn != null && plausible(gn)) {
      _store(key, gn, queryTitle: title);
      return display(gn);
    }

    // Nothing usable: return empty WITHOUT caching it, so a later
    // retry (or the next rebuild) actually refetches instead of
    // replaying this miss.
    return const LyricsResult.empty();
  }

  /// Single-provider dispatch. Subclasses (tests) override this one seam
  /// to stub providers without touching the network.
  Future<LyricsResult?> fetchFromProvider(
    String providerId, {
    required String title,
    required String artist,
    String album = '',
    int? durationSeconds,
    String? videoId,
  }) async {
    try {
      switch (providerId) {
        case 'lastwave':
          return await fetchLastWaveLyrics(
            _dio,
            title: title,
            artist: artist,
            album: album,
            durationSeconds: durationSeconds,
          );
        case 'lrc_red':
          return await fetchLrcRed(
            _dio,
            title: title,
            artist: artist,
            album: album,
            durationSeconds: durationSeconds,
          );
        case 'apple_music':
          return await _fetchAppleWordByWord(
              title, artist, album, durationSeconds);
        case 'better_lyrics':
          return await fetchBetterLyrics(
            _dio,
            title: title,
            artist: artist,
            album: album,
            durationSeconds: durationSeconds,
          );
        case 'better_lyrics_portato':
          return await fetchPortatoLyrics(
            _dio,
            title: title,
            artist: artist,
            album: album,
            durationSeconds: durationSeconds,
          );
        case 'bini_lyrics':
          return await fetchBiniLyrics(
            _dio,
            title: title,
            artist: artist,
            album: album,
            durationSeconds: durationSeconds,
          );
        case 'lyrics_plus':
          return await fetchLyricsPlus(
            _dio,
            title: title,
            artist: artist,
            album: album,
            durationSeconds: durationSeconds,
          );
        case 'unison':
          return await fetchUnisonLyrics(
            _dio,
            title: title,
            artist: artist,
            album: album,
            durationSeconds: durationSeconds,
          );
        case 'kugou':
          return await fetchKugou(
            _dio,
            title: title,
            artist: artist,
            durationSeconds: durationSeconds,
          );
        case 'simp_music':
          final fetched = await fetchSimpMusic(
            _dio,
            videoId: videoId,
            durationSeconds: durationSeconds,
          );
          final lines = fetched?.lines;
          if (lines == null || lines.isEmpty) return null;
          if (!lyricsPlausibleDuration(lines, durationSeconds)) return null;
          final wordSynced = fetched!.wordSynced;
          return LyricsResult(
            lines: lines,
            isSynced: true,
            isWordSynced: wordSynced,
            plainLyrics: lines.map((l) => l.text).join('\n'),
            source: wordSynced
                ? 'Video-Match (Word-Sync)'
                : 'Video-Match (Line-Sync)',
          );
        case 'youtube_captions':
          if (videoId == null || videoId.isEmpty || _tube == null) return null;
          final cues = await _tube.fetchTranscriptCues(videoId);
          if (cues == null || cues.isEmpty) return null;
          final lines = [
            for (final c in cues)
              LyricLine(
                timeMs: c.timeMs,
                text: c.text,
              ),
          ];
          if (!lyricsPlausibleDuration(lines, durationSeconds)) return null;
          return LyricsResult(
            lines: lines,
            isSynced: true,
            isWordSynced: false,
            plainLyrics: lines.map((l) => l.text).join('\n'),
            source: 'YouTube Captions',
          );
        case 'youtube_music':
          if (videoId == null || videoId.isEmpty || _tube == null) return null;
          final text = await _tube.fetchLyricsTabText(videoId);
          if (text == null || text.trim().isEmpty) return null;
          final rawLines = text
              .split('\n')
              .map((l) => l.trim())
              .where((l) => l.isNotEmpty)
              .toList();
          return LyricsResult(
            lines: [
              for (final line in rawLines)
                LyricLine(timeMs: 0, text: line),
            ],
            isSynced: false,
            isWordSynced: false,
            plainLyrics: text.trim(),
            source: 'YouTube Music',
          );
        case 'musixmatch':
          return await fetchMusixmatch(
            _dio,
            title: title,
            artist: artist,
            durationSeconds: durationSeconds,
          );
        case 'megalobiz':
          return await fetchMegalobizLyrics(
            _dio,
            title: title,
            artist: artist,
            durationSeconds: durationSeconds,
          );
        case 'genius':
          return await fetchGeniusLyrics(
            _dio,
            title: title,
            artist: artist,
          );
        case 'lrclib':
          return await _fetchLrclib(title, artist, album, durationSeconds);
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  /// Compares two lyrics candidates to decide if [newRes] should supersede [current].
  static bool isBetterCandidate(
    LyricsResult newRes,
    LyricsResult current, {
    String queryTitle = '',
  }) {
    // 1. True word-synced always beats non-word-synced
    if (newRes.isWordSynced && !current.isWordSynced) return true;
    if (!newRes.isWordSynced && current.isWordSynced) return false;

    // 2. Placeholder "Instrumental" / ♪ lines lose to real text
    final newPlaceholder = lyricsLooksLikePlaceholder(newRes);
    final curPlaceholder = lyricsLooksLikePlaceholder(current);
    if (!newPlaceholder && curPlaceholder) return true;
    if (newPlaceholder && !curPlaceholder) return false;

    // 3. Timed lyrics always beat static text: static lines can never
    // highlight or follow, no matter how complete or title-matched.
    if (newRes.isSynced && !current.isSynced) return true;
    if (!newRes.isSynced && current.isSynced) return false;

    // 4. Sample-hook loops lose to real verses (Overdue / Anthonio)
    final newThin = lyricsLooksLikeThinLoop(newRes);
    final curThin = lyricsLooksLikeThinLoop(current);
    if (!newThin && curThin) return true;
    if (newThin && !curThin) return false;

    // 5. Distinctive title mentioned in the lyric body
    if (queryTitle.trim().isNotEmpty) {
      final newMentions = lyricsMentionsTitle(queryTitle, newRes);
      final curMentions = lyricsMentionsTitle(queryTitle, current);
      if (newMentions && !curMentions) return true;
      if (!newMentions && curMentions) return false;
    }

    // 6. Complete text beats a shorter cut of the same sync kind
    final newLen = lyricsBodyLength(newRes);
    final curLen = lyricsBodyLength(current);
    if (newLen >= (curLen * 1.25).round() && newLen - curLen >= 120) {
      return true;
    }
    if (curLen >= (newLen * 1.25).round() && curLen - newLen >= 120) {
      return false;
    }

    // 7. Unique-line richness beats a padded loop with the same raw count
    final newUnique = lyricsUniqueLineCount(newRes);
    final curUnique = lyricsUniqueLineCount(current);
    if (newUnique >= (curUnique * 1.5).round() && newUnique - curUnique >= 4) {
      return true;
    }
    if (curUnique >= (newUnique * 1.5).round() && curUnique - newUnique >= 4) {
      return false;
    }

    // 8. Official curated sources (Apple Music) beat crowdsourced
    // user submissions (lrclib)
    final newIsCurated = newRes.source.toLowerCase().contains('apple');
    final curIsCurated = current.source.toLowerCase().contains('apple');
    if (newIsCurated && !curIsCurated) return true;
    if (!newIsCurated && curIsCurated) return false;

    // 9. Line count: substantially richer lyrics beat short transcripts
    if (newRes.lines.length >= (current.lines.length * 1.3).round()) {
      return true;
    }

    return false;
  }

  // -- LRCLIB ---------------------------------------------------------------

  Future<LyricsResult?> _fetchLrclib(
    String title,
    String artist,
    String album,
    int? durationSeconds,
  ) async {
    final cleanT = cleanSongTitle(title);
    final cleanA = cleanSongArtist(artist);
    final records = <String, Map<String, dynamic>>{};

    void addRecord(Map<String, dynamic> data) {
      final recTitle =
          (data['trackName'] ?? data['name'])?.toString() ?? '';
      final recArtist = data['artistName']?.toString() ?? '';
      if (!lyricsTitlesMatch(cleanT, recTitle) &&
          !lyricsTitlesMatch(title, recTitle)) {
        return;
      }
      if (!lyricsArtistsMatch(cleanA, recArtist) &&
          !lyricsArtistsMatch(artist, recArtist)) {
        return;
      }
      if (!lyricsDurationPlausible(
          durationSeconds, data['duration'] as num?)) {
        return;
      }
      if (!cleanT.toLowerCase().contains('instrumental') &&
          lyricsIsAlternateRecording(recTitle,
              album: data['albumName']?.toString() ?? '')) {
        return;
      }
      final id = data['id']?.toString() ??
          '${recTitle.toLowerCase()}|${recArtist.toLowerCase()}|${data['albumName'] ?? ''}';
      records.putIfAbsent(id, () => data);
    }

    final attempts = [
      {'track_name': cleanT, 'artist_name': cleanA, 'album_name': album},
      {'track_name': cleanT, 'artist_name': cleanA},
      if (cleanT != title || cleanA != artist) ...[
        {'track_name': title, 'artist_name': artist, 'album_name': album},
        {'track_name': title, 'artist_name': artist},
      ],
      if (cleanA.contains(r'$')) ...[
        {'track_name': cleanT, 'artist_name': cleanA.replaceAll(r'$', 's'), 'album_name': album},
        {'track_name': cleanT, 'artist_name': cleanA.replaceAll(r'$', 's')},
      ],
    ];
    for (final params in attempts) {
      final qp = Map<String, String>.fromEntries(
        params.entries
            .where((e) => e.value.trim().isNotEmpty)
            .map((e) => MapEntry(e.key, e.value)),
      );
      if (durationSeconds != null && durationSeconds > 0) {
        qp['duration'] = '$durationSeconds';
      }
      try {
        final res = await _dio.get<Map<String, dynamic>>(
          'https://lrclib.net/api/get',
          queryParameters: qp,
          options: Options(headers: {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
          }),
        );
        if (res.statusCode == 200 && res.data != null) {
          addRecord(res.data!);
        }
      } on DioException catch (e) {
        if (e.response?.statusCode != 404) rethrow;
      }
    }
    for (final hit in await _lrclibSearchHits(cleanT, cleanA, durationSeconds)) {
      addRecord(hit);
    }
    if (cleanT != title || cleanA != artist) {
      for (final hit in await _lrclibSearchHits(title, artist, durationSeconds)) {
        addRecord(hit);
      }
    }
    final primaryA = _extractArtistEntities(cleanA).firstOrNull;
    if (primaryA != null && primaryA != cleanA && records.isEmpty) {
      for (final hit in await _lrclibSearchHits(cleanT, primaryA, durationSeconds)) {
        addRecord(hit);
      }
    }

    LyricsResult? best;
    for (final record in records.values) {
      final parsed = _lrclibRecordToResult(record, queryTitle: cleanT);
      if (parsed == null || parsed.isEmpty) continue;
      if (best == null ||
          isBetterCandidate(parsed, best, queryTitle: cleanT)) {
        best = parsed;
      }
    }
    return best;
  }

  LyricsResult? _lrclibRecordToResult(
    Map<String, dynamic> record, {
    required String queryTitle,
  }) {
    final recordName =
        (record['trackName'] ?? record['name'])?.toString() ?? '';
    final isInstrumentalRecord = record['instrumental'] == true ||
        recordName.toLowerCase().contains('(instrumental)') ||
        recordName.toLowerCase().contains('[instrumental]');
    if (isInstrumentalRecord) {
      if (!queryTitle.toLowerCase().contains('instrumental')) {
        return null;
      }
      return const LyricsResult(isInstrumental: true, source: 'lrclib');
    }
    final synced = record['syncedLyrics']?.toString() ?? '';
    LyricsResult? parsed;
    if (synced.isNotEmpty) {
      final lines = parseLrc(synced);
      if (lines.isNotEmpty) {
        // Word-sync only for real inline word stamps (enhanced LRC):
        // parseLrc interpolates display syllables into every line,
        // which must never count as word timing.
        final wordSynced = parseEnhancedLrc(synced).isNotEmpty;
        parsed = LyricsResult(
          lines: lines,
          isSynced: true,
          isWordSynced: wordSynced,
          plainLyrics: record['plainLyrics']?.toString() ?? '',
          source: 'lrclib',
        );
      }
    }
    if (parsed == null) {
      final plain = record['plainLyrics']?.toString() ?? '';
      if (plain.isNotEmpty) {
        parsed = LyricsResult(
          lines: plain
              .split('\n')
              .map((l) => LyricLine(timeMs: 0, text: l.trim()))
              .where((l) => l.text.isNotEmpty)
              .toList(),
          plainLyrics: plain,
          source: 'lrclib',
        );
      }
    }
    if (parsed == null || parsed.isEmpty) return null;
    if (lyricsLooksLikePlaceholder(parsed) &&
        !queryTitle.toLowerCase().contains('instrumental')) {
      return null;
    }
    if (!parsed.isSynced && !parsed.isWordSynced) {
      final unpacked = expandPackedLyricLines(parsed.lines);
      if (unpacked.length > parsed.lines.length) {
        return LyricsResult(
          lines: unpacked,
          isSynced: false,
          isWordSynced: false,
          plainLyrics: parsed.plainLyrics,
          source: parsed.source,
        );
      }
    }
    return parsed;
  }

  Future<List<Map<String, dynamic>>> _lrclibSearchHits(
    String title,
    String artist, [
    int? durationSeconds,
  ]) async {
    try {
      final res = await _dio.get<List<dynamic>>(
        'https://lrclib.net/api/search',
        queryParameters: {'q': '$artist $title'},
        options: Options(headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        }),
      );
      final list = res.data ?? const [];
      final wantsAlt = lyricsIsAlternateRecording(title);
      final hits = <Map<String, dynamic>>[];
      for (final item in list) {
        if (item is! Map<String, dynamic>) continue;
        final recTitle =
            (item['trackName'] ?? item['name'])?.toString() ?? '';
        final recArtist = item['artistName']?.toString() ?? '';
        if (!lyricsTitlesMatch(title, recTitle)) continue;
        if (!lyricsArtistsMatch(artist, recArtist)) continue;
        if (!wantsAlt &&
            lyricsIsAlternateRecording(recTitle,
                album: item['albumName']?.toString() ?? '')) {
          continue;
        }
        if (!lyricsDurationPlausible(
            durationSeconds, item['duration'] as num?)) {
          continue;
        }
        hits.add(item);
      }
      return hits;
    } catch (_) {
      return const [];
    }
  }

  // -- Apple Music word-by-word (lyrics.paxsenix.org) --------------------------

  /// Apple's word-by-word (syllable-timed) lyrics via lyrics.paxsenix.org.
  ///
  /// The endpoint requires an Apple Music track ID, resolved through the
  /// iTunes Search API (catalog IDs match), preferring a result whose artist
  /// and duration line up with the playing track.
  Future<LyricsResult?> _fetchAppleWordByWord(
    String title,
    String artist,
    String album,
    int? durationSeconds,
  ) async {
    final cleanT = cleanSongTitle(title);
    final cleanA = cleanSongArtist(artist);
    var trackIds = await _resolveAppleTrackIds(cleanT, cleanA, durationSeconds);
    if (trackIds.isEmpty && (cleanT != title || cleanA != artist)) {
      trackIds = await _resolveAppleTrackIds(title, artist, durationSeconds);
    }
    if (trackIds.isEmpty) return null;
    // Try the best-scoring candidates in order — different album pressings of
    // the same song have separate catalog IDs and not all carry lyrics.
    LyricsResult? fallback;
    for (final trackId in trackIds.take(3)) {
      try {
        final res = await _dio.get<Map<String, dynamic>>(
          'https://lyrics.paxsenix.org/apple-music/lyrics',
          queryParameters: {'id': trackId},
          options: Options(headers: {
            'User-Agent': DioFactory.desktopUserAgent,
            'Accept': 'application/json',
          }),
        );
        final parsed = parseAppleWordByWord(res.data ?? const {});
        if (parsed == null || parsed.isEmpty) continue;
        if (lyricsLooksLikePlaceholder(parsed) ||
            lyricsLooksLikeThinLoop(parsed)) {
          fallback ??= parsed;
          continue;
        }
        return parsed;
      } catch (_) {}
    }
    return fallback;
  }

  /// iTunes Search API → Apple Music catalog track IDs, best match first.
  ///
  /// Identity is strict: the candidate must be the same title and artist.
  /// Instrumental / karaoke / a-cappella albums and titles are skipped
  /// unless the query itself asks for them. Covers and other songs on the
  /// same album are never used just because the artist matched.
  Future<List<String>> _resolveAppleTrackIds(
    String title,
    String artist,
    int? durationSeconds,
  ) async {
    try {
      // iTunes answers with Content-Type: text/javascript, which Dio will
      // not auto-decode even with ResponseType.json — fetch the raw body
      // and decode it manually.
      final res = await _dio.get<String>(
        'https://itunes.apple.com/search',
        queryParameters: {
          'term': '$artist $title',
          'media': 'music',
          'entity': 'song',
          'limit': '10',
        },
        options: Options(
          headers: {'User-Agent': DioFactory.desktopUserAgent},
          responseType: ResponseType.plain,
        ),
      );
      final decoded = jsonDecode(res.data ?? '');
      var results =
          decoded is Map<String, dynamic> ? decoded['results'] : null;
      if (results is! List || results.isEmpty) {
        final primaryArtist = _extractArtistEntities(artist).firstOrNull;
        if (primaryArtist != null && primaryArtist != artist) {
          final res2 = await _dio.get<String>(
            'https://itunes.apple.com/search',
            queryParameters: {
              'term': '$primaryArtist $title',
              'media': 'music',
              'entity': 'song',
              'limit': '10',
            },
            options: Options(
              headers: {'User-Agent': DioFactory.desktopUserAgent},
              responseType: ResponseType.plain,
            ),
          );
          final decoded2 = jsonDecode(res2.data ?? '');
          results =
              decoded2 is Map<String, dynamic> ? decoded2['results'] : null;
        }
      }
      if (results is! List || results.isEmpty) return const [];

      final wantsAlt = lyricsIsAlternateRecording(title);
      final targetMs = (durationSeconds ?? 0) * 1000;

      final scored = <(String id, int score)>[];
      for (final item in results) {
        if (item is! Map<String, dynamic>) continue;
        final id = item['trackId']?.toString() ?? '';
        if (id.isEmpty) continue;
        final rawTitle = item['trackName']?.toString() ?? '';
        final rawArtist = item['artistName']?.toString() ?? '';
        final album = item['collectionName']?.toString() ?? '';
        if (!wantsAlt &&
            lyricsIsAlternateRecording(rawTitle, album: album)) {
          continue;
        }
        if (!lyricsTitlesMatch(title, rawTitle)) continue;
        if (!lyricsArtistsMatch(artist, rawArtist)) continue;

        var score = 10;
        final ms = (item['trackTimeMillis'] as num?)?.toInt() ?? 0;
        if (targetMs > 0 && ms > 0) {
          final diff = (ms - targetMs).abs();
          if (diff > 25000 && diff / targetMs > 0.25) continue;
          if (diff <= 4000) {
            score += 3;
          } else if (diff <= 10000) {
            score += 1;
          }
        }
        scored.add((id, score));
      }
      // Stable sort keeps iTunes relevance order among equal scores.
      scored.sort((a, b) => b.$2.compareTo(a.$2));
      return scored.map((e) => e.$1).toList();
    } catch (_) {
      return const [];
    }
  }

  /// Parse the paxsenix Apple payload (`content[]` lines with per-word
  /// `text`/`timestamp`/`duration`/`part`) into [LyricLine]s.
  ///
  /// `part: true` marks a word fragment that continues into the next one
  /// without a space ("conver" + "sation" → "conversation"). Syllable text
  /// carries no added spaces — the karaoke view's `groupSyllablesIntoWords`
  /// re-derives word boundaries against the full line text.
  ///
  /// Syllables are attached ONLY for true word-by-word (`type: "Syllable"`)
  /// payloads. Line-synced payloads (`type: "Line"`) ship one whole-line
  /// "word" per line; keeping it would suppress the karaoke wipe, so those
  /// lines stay syllable-free and the adapter interpolates per-word timing.
  static LyricsResult? parseAppleWordByWord(Map<String, dynamic> json) {
    final content = json['content'];
    if (content is! List || content.isEmpty) return null;
    final type = json['type']?.toString().toLowerCase() ?? '';
    final parsed = <({
      int start,
      int duration,
      String text,
      List<LyricSyllable> syllables,
    })>[];
    var sawMultiWordLine = false;
    for (final item in content) {
      if (item is! Map<String, dynamic>) continue;
      final start = parseLyricTimestampMs(item['timestamp']);
      final end = parseLyricTimestampMs(item['endtime']);
      final parsedDuration = parseLyricTimestampMs(item['duration']);
      final duration = parsedDuration > 0
          ? parsedDuration
          : (end - start).clamp(0, 1 << 31);
      final isBackground = item['background'] == true;
      final rawWords = item['text'];
      if (rawWords is! List) continue;
      final words = rawWords.whereType<Map<String, dynamic>>().toList();
      if (words.isEmpty) continue;
      if (words.length > 1) sawMultiWordLine = true;
      final syllables = <LyricSyllable>[];
      final buf = StringBuffer();
      for (var i = 0; i < words.length; i++) {
        final w = words[i];
        final wt = w['text']?.toString() ?? '';
        if (wt.isEmpty) continue;
        final ws = w.containsKey('timestamp')
            ? parseLyricTimestampMs(w['timestamp'])
            : start;
        final wd = parseLyricTimestampMs(w['duration']);
        final isPart = w['part'] == true;
        syllables.add(LyricSyllable(
          timeMs: ws,
          durationMs: wd,
          text: wt,
          isBackground: isBackground,
        ));
        buf.write(wt);
        if (!isPart && i < words.length - 1) buf.write(' ');
      }
      final text = buf.toString().trim();
      if (text.isEmpty) continue;
      parsed.add((
        start: start,
        duration: duration,
        text: text,
        syllables: syllables,
      ));
    }
    final timed = parsed.any((p) => p.start > 0 || p.duration > 0);
    final wordSynced = timed &&
        (type == 'syllable' ||
            type == 'word' ||
            sawMultiWordLine ||
            parsed.any((p) => p.syllables.length > 1));
    final rawLines = [
      for (final p in parsed)
        LyricLine(
          timeMs: p.start,
          durationMs: p.duration,
          text: p.text,
          syllables: wordSynced ? p.syllables : const [],
        ),
    ];
    List<LyricLine> lines;
    if (timed) {
      final indexed = [for (var i = 0; i < rawLines.length; i++) (i, rawLines[i])];
      indexed.sort((a, b) {
        final c = a.$2.timeMs.compareTo(b.$2.timeMs);
        return c != 0 ? c : a.$1.compareTo(b.$1);
      });
      lines = [for (final e in indexed) e.$2];
    } else {
      // Keep source order. Sorting equal 0-timestamps shuffles verses.
      lines = expandPackedLyricLines(rawLines);
    }
    return LyricsResult(
      lines: lines,
      isSynced: timed,
      isWordSynced: wordSynced,
      plainLyrics: json['plain']?.toString() ?? '',
      source: 'Apple Music',
    );
  }
}

final lyricsRepositoryProvider = Provider<LyricsRepository>((ref) {
  return LyricsRepository(
    null,
    const Duration(seconds: 4),
    const Duration(seconds: 12),
    ref.watch(innerTubeProvider),
  );
});
