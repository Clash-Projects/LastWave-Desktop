import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/dio_factory.dart';
import 'lyrics_models.dart';

/// Lyrics orchestrator with Apple Music word-by-word lyrics.
///
/// Ported from LastWave-native `LyricsRepository.kt`:
/// - in-memory cache (word-synced entries preferred)
/// - when `wordByWord` is requested, fetch Apple Music word-by-word
///   (syllable-timed) lyrics via lyrics.paxsenix.org and return them
///   immediately while keeping a line-synced LRCLIB fallback
/// - LRCLIB tiers: instrumental → synced LRC → plain → empty
String cleanSongTitle(String title) {
  var t = title;
  t = t.replaceAll(
      RegExp(
          r'\s*\([^)]*(?:official|video|audio|remaster|feat|ft\.|live|version|edit|visualizer|lyrics?)[^)]*\)',
          caseSensitive: false),
      '');
  t = t.replaceAll(
      RegExp(
          r'\s*\[[^\]]*(?:official|video|audio|remaster|feat|ft\.|live|version|edit|visualizer|lyrics?)[^\]]*\]',
          caseSensitive: false),
      '');
  t = t.replaceAll(
      RegExp(
          r'\s*-\s*(?:official|video|audio|remaster|live|remastered|lyrics?).*$',
          caseSensitive: false),
      '');
  t = t.replaceAll(RegExp(r'[\s\-–—]+$'), '').trim();
  return t.isNotEmpty ? t : title;
}

String cleanSongArtist(String artist) {
  var a = artist;
  a = a.replaceAll(RegExp(r'\s*-\s*Topic$', caseSensitive: false), '');
  a = a.replaceAll(
      RegExp(r'\s*(?:feat\.|ft\.|featuring).*$', caseSensitive: false), '');
  return a.trim().isNotEmpty ? a.trim() : artist;
}

/// Drop featuring clauses, bracketed noise, and punctuation so "ALL CAPS"
/// and "All Caps [Official Audio]" compare equal.
String normalizeLyricsTitle(String s) {
  var t = s.toLowerCase();
  t = t.replaceAll(RegExp(r'\[[^\]]*\]'), ' ');
  t = t.replaceAll(RegExp(r'\b(?:feat\.?|ft\.?|featuring)\b.*$'), ' ');
  t = t.replaceAll(RegExp(r'\(\s*\)'), ' ');
  t = t.replaceAll(RegExp(r'[\(\[]\s*$'), ' ');
  t = t.replaceAll(RegExp(r'[‘’`]'), "'");
  t = t.replaceAll(RegExp(r"[^\w\s()'&]"), ' ');
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
  final q = normalizeLyricsTitle(query);
  final c = normalizeLyricsTitle(candidate);
  if (q.isEmpty || c.isEmpty) return false;
  if (q == c) return true;
  final qCore = _lyricsCoreTitle(q);
  final cCore = _lyricsCoreTitle(c);
  if (qCore.isEmpty || cCore.isEmpty || qCore != cCore) return false;
  final qExtra = q.replaceAll(qCore, '').trim();
  final cExtra = c.replaceAll(cCore, '').trim();
  // Query named a specific cut the candidate does not have
  // ("Song (Interlude)" must not match "Song").
  if (qExtra.isNotEmpty && cExtra.isEmpty) return false;
  if (qExtra.isNotEmpty && cExtra.isNotEmpty && qExtra != cExtra) {
    return false;
  }
  return true;
}

/// Artists match when equal, or the shorter name is a full token in the
/// longer billing ("Madvillain" in "Madvillain & MF DOOM").
bool lyricsArtistsMatch(String query, String candidate) {
  final q = cleanSongArtist(query).toLowerCase().trim();
  final c = cleanSongArtist(candidate).toLowerCase().trim();
  if (q.isEmpty || c.isEmpty) return false;
  if (q == c) return true;
  final shorter = q.length <= c.length ? q : c;
  final longer = q.length <= c.length ? c : q;
  if (shorter.length < 2) return false;
  return RegExp(
    '(^|[\\s&/,;+])${RegExp.escape(shorter)}(\$|[\\s&/,;+])',
  ).hasMatch(longer);
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
  if (diff <= 12) return true;
  return diff / querySeconds <= 0.2;
}

class LyricsRepository {
  final Dio _dio;
  final Map<String, LyricsResult> _cache = {};

  LyricsRepository([Dio? dio]) : _dio = dio ?? DioFactory.create();

  String _key(String title, String artist, [String album = '']) =>
      '${title.toLowerCase()}|${artist.toLowerCase()}|${album.toLowerCase()}';

  Future<LyricsResult> getLyrics({
    required String title,
    required String artist,
    String album = '',
    int? durationSeconds,
    bool forceRefresh = false,
    bool wordByWord = true,
    void Function(LyricsResult partial)? onPartialResult,
  }) async {
    final key = _key(title, artist, album);
    if (!forceRefresh) {
      final cached = _cache[key];
      if (cached != null) {
        if (!cached.isEmpty) onPartialResult?.call(cached);
        if (!wordByWord || cached.isWordSynced || cached.isInstrumental) {
          return cached;
        }
      }
    }

    LyricsResult? lineFallback;

    final futures = [
      _fetchLrclib(title, artist, album, durationSeconds),
      if (wordByWord)
        _fetchAppleWordByWord(title, artist, album, durationSeconds),
    ];
    final pending = futures.map((future) => future
        .timeout(const Duration(seconds: 12))
        .then<LyricsResult?>((value) => value, onError: (_) => null));
    await for (final result in Stream.fromFutures(pending)) {
      if (result == null || result.isEmpty) continue;
      if (result.isWordSynced || result.isInstrumental) {
        _cache[key] = result;
        return result;
      }
      if (lineFallback == null || isBetterCandidate(result, lineFallback)) {
        lineFallback = result;
        onPartialResult?.call(result);
      }
    }

    if (lineFallback != null) {
      _cache[key] = lineFallback;
      return lineFallback;
    }
    const empty = LyricsResult.empty();
    _cache[key] = empty;
    return empty;
  }

  /// Compares two lyrics candidates to decide if [newRes] should supersede [current].
  static bool isBetterCandidate(LyricsResult newRes, LyricsResult current) {
    // 1. True word-synced always beats non-word-synced
    if (newRes.isWordSynced && !current.isWordSynced) return true;
    if (!newRes.isWordSynced && current.isWordSynced) return false;

    // 2. Synced always beats unsynced
    if (newRes.isSynced && !current.isSynced) return true;
    if (!newRes.isSynced && current.isSynced) return false;

    // 3. Official curated sources (Apple Music) beat crowdsourced
    // user submissions (lrclib)
    final newIsCurated = newRes.source.toLowerCase().contains('apple');
    final curIsCurated = current.source.toLowerCase().contains('apple');
    if (newIsCurated && !curIsCurated) return true;
    if (!newIsCurated && curIsCurated) return false;

    // 4. Line count: substantially richer lyrics beat short loops / sample transcripts
    if (newRes.lines.length >= (current.lines.length * 1.3).round()) return true;

    return false;
  }

  // -- LRCLIB ---------------------------------------------------------------

  Future<LyricsResult?> _fetchLrclib(
    String title,
    String artist,
    String album,
    int? durationSeconds,
  ) async {
    Map<String, dynamic>? record;
    final cleanT = cleanSongTitle(title);
    final cleanA = cleanSongArtist(artist);
    final attempts = [
      {'track_name': cleanT, 'artist_name': cleanA, 'album_name': album},
      {'track_name': cleanT, 'artist_name': cleanA},
      if (cleanT != title || cleanA != artist) ...[
        {'track_name': title, 'artist_name': artist, 'album_name': album},
        {'track_name': title, 'artist_name': artist},
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
          final data = res.data!;
          final recTitle =
              (data['trackName'] ?? data['name'])?.toString() ?? '';
          final recArtist = data['artistName']?.toString() ?? '';
          if (!lyricsTitlesMatch(cleanT, recTitle) ||
              !lyricsArtistsMatch(cleanA, recArtist)) {
            continue;
          }
          if (!lyricsDurationPlausible(
              durationSeconds, data['duration'] as num?)) {
            continue;
          }
          if (!cleanT.toLowerCase().contains('instrumental') &&
              lyricsIsAlternateRecording(recTitle,
                  album: data['albumName']?.toString() ?? '')) {
            continue;
          }
          record = data;
          break;
        }
      } on DioException catch (e) {
        if (e.response?.statusCode != 404) rethrow;
      }
    }
    // cleaned-title retry
    record ??= await _lrclibSearch(cleanT, cleanA, durationSeconds);
    if (record == null && (cleanT != title || cleanA != artist)) {
      record = await _lrclibSearch(title, artist, durationSeconds);
    }
    if (record == null) return null;
    final recordName = record['name']?.toString() ?? '';
    final isInstrumentalRecord = record['instrumental'] == true ||
        recordName.toLowerCase().contains('(instrumental)') ||
        recordName.toLowerCase().contains('[instrumental]');
    if (isInstrumentalRecord) {
      if (!cleanT.toLowerCase().contains('instrumental')) {
        // Skip instrumental entries if user wanted the vocal track
        return null;
      }
      return const LyricsResult(
          isInstrumental: true, source: 'lrclib');
    }
    final synced = record['syncedLyrics']?.toString() ?? '';
    if (synced.isNotEmpty) {
      final lines = parseLrc(synced);
      if (lines.isNotEmpty) {
        return LyricsResult(
          lines: lines,
          isSynced: true,
          isWordSynced: false,
          plainLyrics: record['plainLyrics']?.toString() ?? '',
          source: 'lrclib',
        );
      }
    }
    final plain = record['plainLyrics']?.toString() ?? '';
    if (plain.isNotEmpty) {
      return LyricsResult(
        lines: plain
            .split('\n')
            .map((l) => LyricLine(timeMs: 0, text: l.trim()))
            .where((l) => l.text.isNotEmpty)
            .toList(),
        plainLyrics: plain,
        source: 'lrclib',
      );
    }
    return null;
  }

  Future<Map<String, dynamic>?> _lrclibSearch(
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
      Map<String, dynamic>? best;
      var bestDiff = 1 << 30;
      final wantsAlt = lyricsIsAlternateRecording(title);
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
        final dur = (item['duration'] as num?)?.round() ?? 0;
        final diff = durationSeconds != null && durationSeconds > 0 && dur > 0
            ? (dur - durationSeconds).abs()
            : 0;
        if (best == null || diff < bestDiff) {
          best = item;
          bestDiff = diff;
        }
      }
      return best;
    } catch (_) {}
    return null;
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
        if (parsed != null && !parsed.isEmpty) return parsed;
      } catch (_) {}
    }
    return null;
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
      final results =
          decoded is Map<String, dynamic> ? decoded['results'] : null;
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
      final start = (item['timestamp'] as num?)?.toInt() ?? 0;
      final end = (item['endtime'] as num?)?.toInt() ?? 0;
      final duration = (item['duration'] as num?)?.toInt() ??
          (end - start).clamp(0, 1 << 31);
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
        final ws = (w['timestamp'] as num?)?.toInt() ?? start;
        final wd = (w['duration'] as num?)?.toInt() ?? 0;
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
    if (parsed.isEmpty) return null;
    final wordSynced = type == 'syllable' || sawMultiWordLine;
    final lines = [
      for (final p in parsed)
        LyricLine(
          timeMs: p.start,
          durationMs: p.duration,
          text: p.text,
          syllables: wordSynced ? p.syllables : const [],
        ),
    ]..sort((a, b) => a.timeMs.compareTo(b.timeMs));
    return LyricsResult(
      lines: lines,
      isSynced: true,
      isWordSynced: wordSynced,
      plainLyrics: json['plain']?.toString() ?? '',
      source: 'Apple Music',
    );
  }

  /// Parse TTML (`<p begin end>` lines, `<span begin end>` words).
  static List<LyricLine> parseTtml(String ttml) {
    final pTag = RegExp(
        r'<p\s+([^>]*?)>(.*?)</p>',
        dotAll: true);
    final spanTag = RegExp(
        r'<span\s+([^>]*?)>(.*?)</span>(\s*)',
        dotAll: true);
    final xmlTag = RegExp(r'<[^>]+>');
    final lines = <LyricLine>[];

    for (final p in pTag.allMatches(ttml)) {
      final pAttrs = p.group(1) ?? '';
      final inner = p.group(2) ?? '';
      final pBeginMatch = RegExp(r'begin="([^"]+)"').firstMatch(pAttrs);
      final pEndMatch = RegExp(r'end="([^"]+)"').firstMatch(pAttrs);
      final start = _parseTtmlTime(pBeginMatch?.group(1) ?? '');
      final end = _parseTtmlTime(pEndMatch?.group(1) ?? '');
      final duration = (end - start).clamp(0, 1 << 31);
      final spans = spanTag.allMatches(inner).toList();

      if (spans.isEmpty) {
        final text = _unescapeXml(inner.replaceAll(xmlTag, '').trim());
        if (text.isEmpty) continue;
        final syllables = interpolateLineSyllables(
          text: text,
          startTimeMs: start,
          durationMs: duration > 0 ? duration : 4000,
        );
        lines.add(LyricLine(
          timeMs: start,
          durationMs: duration,
          text: text,
          syllables: syllables,
        ));
      } else {
        final syllables = <LyricSyllable>[];
        final buf = StringBuffer();
        final hasExplicitInterTagSpaces =
            RegExp(r'</span>\s+<span').hasMatch(inner);

        for (var i = 0; i < spans.length; i++) {
          final s = spans[i];
          final isLast = i == spans.length - 1;
          final attrs = s.group(1) ?? '';
          final rawContent = s.group(2) ?? '';
          final trailingSpace = s.group(3) ?? '';

          final beginMatch = RegExp(r'begin="([^"]+)"').firstMatch(attrs);
          final endMatch = RegExp(r'end="([^"]+)"').firstMatch(attrs);

          if (beginMatch == null || endMatch == null) {
            // Nested or container span (e.g. <span ttm:role="x-bg">)
            final innerSpans = spanTag.allMatches(rawContent).toList();
            final isBg = attrs.contains('role="x-bg"');
            for (var j = 0; j < innerSpans.length; j++) {
              final ispan = innerSpans[j];
              final isInnerLast = isLast && j == innerSpans.length - 1;
              final iattrs = ispan.group(1) ?? '';
              final ibMatch = RegExp(r'begin="([^"]+)"').firstMatch(iattrs);
              final ieMatch = RegExp(r'end="([^"]+)"').firstMatch(iattrs);
              if (ibMatch == null || ieMatch == null) continue;
              final ws = _parseTtmlTime(ibMatch.group(1) ?? '');
              final we = _parseTtmlTime(ieMatch.group(1) ?? '');
              final wt = _unescapeXml(ispan.group(2)?.replaceAll(xmlTag, '') ?? '');
              final iTrailing = ispan.group(3) ?? '';
              final addSpace = hasExplicitInterTagSpaces
                  ? (wt.endsWith(' ') || iTrailing.isNotEmpty)
                  : (!isInnerLast && !wt.endsWith(' '));
              final sylText = addSpace ? '${wt.trimRight()} ' : wt;
              syllables.add(LyricSyllable(
                timeMs: ws,
                durationMs: (we - ws).clamp(0, 1 << 31),
                text: hasExplicitInterTagSpaces ? sylText : wt.trim(),
                isBackground: isBg,
              ));
              buf.write(sylText);
            }
            continue;
          }

          final ws = _parseTtmlTime(beginMatch.group(1) ?? '');
          final we = _parseTtmlTime(endMatch.group(1) ?? '');
          final wt = _unescapeXml(rawContent.replaceAll(xmlTag, ''));
          final isBg = attrs.contains('role="x-bg"');
          final addSpace = hasExplicitInterTagSpaces
              ? (wt.endsWith(' ') || trailingSpace.isNotEmpty)
              : (!isLast && !wt.endsWith(' '));
          final sylText = addSpace ? '${wt.trimRight()} ' : wt;
          syllables.add(LyricSyllable(
            timeMs: ws,
            durationMs: (we - ws).clamp(0, 1 << 31),
            text: hasExplicitInterTagSpaces ? sylText : wt.trim(),
            isBackground: isBg,
          ));
          buf.write(sylText);
        }

        final text = buf.toString().trim();
        if (text.isEmpty) continue;
        lines.add(LyricLine(
          timeMs: start,
          durationMs: duration,
          text: text,
          syllables: syllables,
        ));
      }
    }
    lines.sort((a, b) => a.timeMs.compareTo(b.timeMs));
    return lines;
  }

  static int _parseTtmlTime(String s) {
    s = s.trim();
    if (s.isEmpty) return 0;
    try {
      if (s.endsWith('ms')) {
        return double.parse(s.substring(0, s.length - 2)).round();
      }
      if (s.endsWith('s')) {
        return (double.parse(s.substring(0, s.length - 1)) * 1000).round();
      }
      if (s.contains(':')) {
        final parts = s.split(':');
        final nums = parts.map(double.parse).toList().reversed.toList();
        var total = 0.0;
        var mult = 1.0;
        for (final n in nums) {
          total += n * mult;
          mult *= 60.0;
        }
        return (total * 1000).round();
      }
      return (double.parse(s) * 1000).round();
    } catch (_) {
      return 0;
    }
  }

  static String _unescapeXml(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&#39;', "'");
}

final lyricsRepositoryProvider =
    Provider<LyricsRepository>((_) => LyricsRepository());
