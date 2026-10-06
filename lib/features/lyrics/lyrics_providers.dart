/// Lyrics provider registry + fetchers ported from LastWave-native
/// `data/lyrics/*.kt`.
///
/// [LyricsProviderId.lrcRed] takes the first-party slot: lrc.red serves
/// the Bini-compatible search API (`/api/v1`) and word-sync TTML
/// documents (`/s/{ISRC}.ttml`) — verified live 2026-10-06
/// (`lyrics-api.binimum.org` 307-redirects to `lrc.red/api/v1`).
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:dio/dio.dart';

import 'lyrics_models.dart';
enum LyricsProviderId {
  auto(
    'auto',
    'Auto',
    'Fastest word-sync wins, LRCLIB fallback',
  ),
  lrcRed(
    'lrc_red',
    'Lrc.Red',
    'Recording-matched word-sync first',
  ),
  appleMusic(
    'apple_music',
    'Apple Music',
    'Syllable-synced Apple Music lyrics first',
  ),
  betterLyrics(
    'better_lyrics',
    'BetterLyrics',
    'Word-synced lyrics first',
  ),
  kugou(
    'kugou',
    'Kugou',
    'KRC word-synced lyrics first',
  ),
  simpMusic(
    'simp_music',
    'Video-Match',
    'Matched on the playing video first',
  ),
  musixmatch(
    'musixmatch',
    'Catalog',
    'Largest catalogue line-sync first',
  ),
  lrclib(
    'lrclib',
    'LRCLIB',
    'Line-synced community lyrics first',
  );

  final String id;
  final String title;
  final String subtitle;

  const LyricsProviderId(this.id, this.title, this.subtitle);

  /// True for providers that can return syllable/word timing and take
  /// part in the word-sync race with a preferred head start.
  bool get isWordProvider =>
      this != auto &&
      this != lrclib;

  static LyricsProviderId fromId(String? id) =>
      values.firstWhere(
        (p) => p.id == id,
        orElse: () => auto,
      );
}

// -- BetterLyrics (lyrics-api.boidu.dev) -----------------------------------
// Free, no key. Apple-Music TTML with per-syllable timing; both TTML
// endpoints are tried, then the QQ karaoke endpoint.

const _betterBases = [
  'https://lyrics-api.boidu.dev/getLyrics',
  'https://lyrics-api.boidu.dev/ttml/getLyrics',
  'https://lyrics-api.boidu.dev/qq/getLyrics',
];

const _betterEnvelopeKeys = [
  'ttml',
  'ttmlContent',
  'lyrics',
  'lrc',
  'content',
  'text',
  'plainLyrics',
  'syncedLyrics',
  'line',
  'lines',
  'lyric',
  'data',
  'result',
  'response',
];

Future<LyricsResult?> fetchBetterLyrics(
  Dio dio, {
  required String title,
  required String artist,
  String? album,
  int? durationSeconds,
}) async {
  if (title.trim().isEmpty || artist.trim().isEmpty) return null;
  final attempts = [(title, artist)];
  final cleaned =
      (lyricsForSearchTitle(title), lyricsForSearchArtist(artist));
  if (cleaned.$1 != title || cleaned.$2 != artist) attempts.add(cleaned);
  for (final attempt in attempts) {
    if (attempt.$1.trim().isEmpty || attempt.$2.trim().isEmpty) continue;
    final lines = await _fetchBetterAttempt(
      dio,
      title: attempt.$1,
      artist: attempt.$2,
      album: album,
      durationSeconds: durationSeconds,
    );
    if (lines != null && lyricsPlausibleDuration(lines, durationSeconds)) {
      final wordSynced = lines.any((l) => l.hasSyllables);
      return LyricsResult(
        lines: lines,
        isSynced: true,
        isWordSynced: wordSynced,
        plainLyrics: lines.map((l) => l.text).join('\n'),
        source: wordSynced
            ? 'BetterLyrics (Word-Sync)'
            : 'BetterLyrics (Line-Sync)',
      );
    }
  }
  return null;
}

Future<List<LyricLine>?> _fetchBetterAttempt(
  Dio dio, {
  required String title,
  required String artist,
  String? album,
  int? durationSeconds,
}) async {
  for (final base in _betterBases) {
    final qp = {
      's': title.trim(),
      'a': artist.trim(),
      if (durationSeconds != null && durationSeconds > 0)
        'd': '$durationSeconds',
      if (album != null && album.trim().isNotEmpty) 'al': album.trim(),
    };
    try {
      final res = await dio.get<String>(
        base,
        queryParameters: qp,
        options: Options(
          responseType: ResponseType.plain,
          headers: {'Accept': 'application/json'},
        ),
      );
      final body = res.data;
      if (body == null || body.isEmpty) continue;
      final parsed = parseBetterDocument(body);
      if (parsed != null && parsed.isNotEmpty) return parsed;
    } catch (_) {}
  }
  return null;
}

/// Parse a BetterLyrics document: TTML word timing first, then the
/// QQ karaoke millisecond format, then enhanced + plain LRC.
List<LyricLine>? parseBetterDocument(String raw) {
  final payload = _unwrapBetterPayload(raw);
  if (payload == null || payload.isEmpty) return null;
  final lower = payload.toLowerCase();
  if (lower.contains('<tt') || lower.contains('http://www.w3.org/ns/ttml')) {
    final ttml = parseTtml(payload);
    if (ttml.isNotEmpty) return ttml;
  }
  final karaoke = parseBetterKaraoke(payload);
  if (karaoke.isNotEmpty) return karaoke;
  final enhanced = parseEnhancedLrc(payload);
  if (enhanced.isNotEmpty) return enhanced;
  final lrc = parseLrc(payload);
  if (lrc.isNotEmpty) return lrc;
  return null;
}

dynamic _betterJsonDecode(String raw) {
  try {
    return jsonDecode(raw);
  } catch (_) {
    return null;
  }
}

String? _unwrapBetterPayload(String raw) {
  final trimmed = raw.replaceAll('﻿', '').trim();
  if (trimmed.isEmpty) return null;
  if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) return trimmed;
  final element = _betterJsonDecode(trimmed);
  if (element == null) return trimmed;
  final found = _extractBetterContent(element)?.trim();
  if (found == null || found.isEmpty) return trimmed;
  return found;
}

String? _extractBetterContent(dynamic element) {
  if (element == null) return null;
  if (element is String) {
    final text = element.trim();
    if (text.isEmpty) return null;
    if ((text.startsWith('{') || text.startsWith('[')) &&
        _betterJsonDecode(text) != null) {
      return _extractBetterContent(_betterJsonDecode(text)) ?? text;
    }
    return text;
  }
  if (element is List) {
    final texts = <String>[];
    for (final item in element) {
      final t = _extractBetterContent(item);
      if (t != null && t.isNotEmpty) texts.add(t);
    }
    final joined = texts.join('\n');
    return joined.isEmpty ? null : joined;
  }
  if (element is Map) {
    if (element['isError']?.toString() == 'true' ||
        element['ok']?.toString() == 'false') {
      return null;
    }
    for (final key in _betterEnvelopeKeys) {
      if (element.containsKey(key)) {
        final found = _extractBetterContent(element[key]);
        if (found != null && found.isNotEmpty) return found;
      }
    }
    return null;
  }
  return null;
}

final _karaokeLineRegex = RegExp(r'^\[(\d{1,8}),(\d{1,8})](.*)$');
final _karaokeWordRegex =
    RegExp(r'\((\d{1,8}),(\d{1,8})(?:,\d{1,8})?\)([^()]*)');
final _karaokeTimeRegex = RegExp(r'\(\d{1,8},\d{1,8}(?:,\d{1,8})?\)');

/// QQ karaoke rows: `[lineStart,lineDur](wStart,wDur[,?])word …`.
List<LyricLine> parseBetterKaraoke(String raw) {
  if (!raw.contains('[') || !raw.contains('(')) return const [];
  final rows = <LyricLine>[];
  for (final source in raw.split('\n')) {
    final match = _karaokeLineRegex.firstMatch(source.trim());
    if (match == null) continue;
    final lineStart = int.tryParse(match.group(1) ?? '');
    final lineDuration = int.tryParse(match.group(2) ?? '') ?? 0;
    if (lineStart == null) continue;
    final body = match.group(3) ?? '';
    final words = <LyricSyllable>[];
    for (final word in _karaokeWordRegex.allMatches(body)) {
      final text =
          lyricsDecodeEntities(word.group(3) ?? '').trim();
      if (text.isEmpty) continue;
      final startMs = int.tryParse(word.group(1) ?? '');
      if (startMs == null) continue;
      final durMs = int.tryParse(word.group(2) ?? '') ?? 0;
      words.add(LyricSyllable(
        timeMs: startMs,
        durationMs: durMs.clamp(0, 1 << 31),
        text: text,
      ));
    }
    if (words.isEmpty) continue;
    final text =
        lyricsDecodeEntities(body.replaceAll(_karaokeTimeRegex, '')).trim();
    if (text.isEmpty) continue;
    rows.add(LyricLine(
      timeMs: math.min(lineStart, words.first.timeMs),
      durationMs: lineDuration.clamp(0, 1 << 31),
      text: text,
      syllables: words,
    ));
  }
  rows.sort((a, b) => a.timeMs.compareTo(b.timeMs));
  return rows;
}

// -- Lrc.Red (lrc.red/api/v1, Bini-compatible) -------------------------------
// Recording-matched Apple TTML plus the ISRC other lookups can reuse.
// Ported from native `BiniLyricsApi` with the base URL moved to lrc.red
// (binimum 307-redirects there; schema verified identical 2026-10-06).

const _lrcRedBase = 'https://lrc.red/api/v1';

class LrcRedHit {
  final String? trackName;
  final String? artistName;
  final String? albumName;
  final int? duration;
  final String? isrc;
  final String? timingType;
  final String? lyricsUrl;

  const LrcRedHit({
    this.trackName,
    this.artistName,
    this.albumName,
    this.duration,
    this.isrc,
    this.timingType,
    this.lyricsUrl,
  });

  factory LrcRedHit.fromJson(Map<String, dynamic> json) => LrcRedHit(
        trackName: json['track_name']?.toString(),
        artistName: json['artist_name']?.toString(),
        albumName: json['album_name']?.toString(),
        duration: (json['duration'] as num?)?.toInt(),
        isrc: json['isrc']?.toString(),
        timingType: json['timing_type']?.toString(),
        lyricsUrl: json['lyricsUrl']?.toString(),
      );
}

/// Floor: exact title + artist agreement (3 + 2). Fuzzy-title hits
/// (1 + 2) never pass on their own — homonyms stay out.
int scoreLrcRedHit(
  LrcRedHit hit, {
  required String title,
  required String artist,
  int? durationSeconds,
}) {
  var score = 0;
  final candTitle = lyricsForSearchTitle(hit.trackName ?? '');
  final reqTitle = lyricsForSearchTitle(title);
  if (candTitle.toLowerCase() == reqTitle.toLowerCase()) {
    score += 3;
  } else if (lyricsTitlesMatchStrict(candTitle, reqTitle)) {
    score += 1;
  }
  final candArtist = lyricsForSearchArtist(hit.artistName ?? '');
  final reqArtist = lyricsForSearchArtist(artist);
  if (candArtist.isNotEmpty &&
      reqArtist.isNotEmpty &&
      (candArtist.toLowerCase() == reqArtist.toLowerCase() ||
          lyricsArtistsMatchStrict(candArtist, reqArtist))) {
    score += 2;
  }
  final hitSecs = hit.duration ?? 0;
  if (durationSeconds != null && durationSeconds > 0 && hitSecs > 0) {
    final delta = (hitSecs - durationSeconds).abs();
    if (delta <= 3) {
      score += 3;
    } else if (delta <= 10) {
      score += 1;
    }
  }
  return score;
}

int _lrcRedDurationDelta(LrcRedHit hit, int? durationSeconds) {
  final hitSecs = hit.duration ?? 0;
  if (durationSeconds == null || durationSeconds <= 0 || hitSecs <= 0) {
    return 0;
  }
  return (hitSecs - durationSeconds).abs();
}

/// Same recording only, both sides agreeing, word-timed files first,
/// duration closest. Below-floor hits are rejected.
LrcRedHit? selectLrcRedBest(
  List<LrcRedHit> hits, {
  required String title,
  required String artist,
  int? durationSeconds,
}) {
  if (hits.isEmpty) return null;
  final scored = <({LrcRedHit hit, int score})>[];
  for (final hit in hits) {
    if (!lyricsSameVersion(title, hit.trackName ?? '')) continue;
    final score = scoreLrcRedHit(
      hit,
      title: title,
      artist: artist,
      durationSeconds: durationSeconds,
    );
    if (score >= 5) scored.add((hit: hit, score: score));
  }
  scored.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    if (byScore != 0) return byScore;
    final aWord =
        a.hit.timingType?.toLowerCase() == 'word' ? 0 : 1;
    final bWord =
        b.hit.timingType?.toLowerCase() == 'word' ? 0 : 1;
    final byWord = aWord.compareTo(bWord);
    if (byWord != 0) return byWord;
    return _lrcRedDurationDelta(a.hit, durationSeconds)
        .compareTo(_lrcRedDurationDelta(b.hit, durationSeconds));
  });
  return scored.isEmpty ? null : scored.first.hit;
}

Future<List<LrcRedHit>> _queryLrcRed(
  Dio dio,
  Map<String, String> params,
) async {
  try {
    final res = await dio.get<Map<String, dynamic>>(
      _lrcRedBase,
      queryParameters: params,
      options: Options(headers: {'Accept': 'application/json'}),
    );
    final results = res.data?['results'];
    if (results is! List) return const [];
    return [
      for (final item in results)
        if (item is Map<String, dynamic>) LrcRedHit.fromJson(item)
        else if (item is Map)
          LrcRedHit.fromJson(Map<String, dynamic>.from(item)),
    ];
  } catch (_) {
    return const [];
  }
}

Future<LrcRedHit?> identifyLrcRed(
  Dio dio, {
  required String title,
  required String artist,
  String? album,
  int? durationSeconds,
  String? isrc,
}) async {
  if (isrc != null && isrc.trim().isNotEmpty) {
    // ISRC names the recording exactly: take it, preferring a
    // word-timed file when the catalogue holds several.
    final hits = await _queryLrcRed(dio, {'isrc': isrc.trim()});
    hits.sort((a, b) {
      final aWord =
          a.timingType?.toLowerCase() == 'word' ? 0 : 1;
      final bWord =
          b.timingType?.toLowerCase() == 'word' ? 0 : 1;
      return aWord.compareTo(bWord);
    });
    if (hits.isNotEmpty) return hits.first;
  }
  if (title.trim().isEmpty) return null;
  final shaped = {
    'track': title.trim(),
    'artist': artist.trim(),
    if (album != null && album.trim().isNotEmpty) 'album': album.trim(),
    if (durationSeconds != null && durationSeconds > 0)
      'duration': '$durationSeconds',
  };
  // Free-text fallback: the shaped query can miss while `q` hits
  // (and vice versa), so try both before giving up.
  return selectLrcRedBest(
        await _queryLrcRed(dio, shaped),
        title: title,
        artist: artist,
        durationSeconds: durationSeconds,
      ) ??
      selectLrcRedBest(
        await _queryLrcRed(dio, {
          'q': artist.trim().isEmpty
              ? title.trim()
              : '${artist.trim()} - ${title.trim()}',
        }),
        title: title,
        artist: artist,
        durationSeconds: durationSeconds,
      );
}

Future<List<LyricLine>?> fetchLrcRedLines(Dio dio, LrcRedHit hit) async {
  final documentUrl = hit.lyricsUrl;
  if (documentUrl == null || documentUrl.trim().isEmpty) return null;
  try {
    final res = await dio.get<String>(
      documentUrl,
      options: Options(
        responseType: ResponseType.plain,
        headers: {'Accept': 'application/xml, text/xml, */*'},
      ),
    );
    final ttml = res.data;
    if (ttml == null || ttml.trim().isEmpty) return null;
    final lines = parseTtml(ttml);
    return lines.isEmpty ? null : lines;
  } catch (_) {
    return null;
  }
}

Future<LyricsResult?> fetchLrcRed(
  Dio dio, {
  required String title,
  required String artist,
  String? album,
  int? durationSeconds,
  String? isrc,
}) async {
  final hit = await identifyLrcRed(
    dio,
    title: title,
    artist: artist,
    album: album,
    durationSeconds: durationSeconds,
    isrc: isrc,
  );
  if (hit == null) return null;
  final lines = await fetchLrcRedLines(dio, hit);
  if (lines == null || lines.isEmpty) return null;
  if (!lyricsPlausibleDuration(lines, durationSeconds)) return null;
  final wordSynced = lines.any((l) => l.hasSyllables);
  return LyricsResult(
    lines: lines,
    isSynced: true,
    isWordSynced: wordSynced,
    plainLyrics: lines.map((l) => l.text).join('\n'),
    source:
        wordSynced ? 'Lrc.Red (Word-Sync)' : 'Lrc.Red (Line-Sync)',
  );
}
