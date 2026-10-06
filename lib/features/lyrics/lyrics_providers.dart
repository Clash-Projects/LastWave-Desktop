/// Lyrics provider registry + fetchers ported from LastWave-native
/// `data/lyrics/*.kt`.
///
/// [LyricsProviderId.lrcRed] takes the first-party slot: lrc.red serves
/// the Bini-compatible search API (`/api/v1`) and word-sync TTML
/// documents (`/s/{ISRC}.ttml`) — verified live 2026-10-06
/// (`lyrics-api.binimum.org` 307-redirects to `lrc.red/api/v1`).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
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

/// Map a result `source` label back to its provider id. Unknown labels
/// yield null (no exclusion possible for them).
String? lyricsSourceToProviderId(String source) {
  final s = source.toLowerCase();
  if (s.startsWith('lrc.red')) return LyricsProviderId.lrcRed.id;
  if (s.contains('apple')) return LyricsProviderId.appleMusic.id;
  if (s.startsWith('betterlyrics')) return LyricsProviderId.betterLyrics.id;
  if (s.startsWith('kugou')) return LyricsProviderId.kugou.id;
  if (s.startsWith('video-match')) return LyricsProviderId.simpMusic.id;
  if (s.startsWith('catalog')) return LyricsProviderId.musixmatch.id;
  if (s.contains('lrclib')) return LyricsProviderId.lrclib.id;
  return null;
}

/// Next per-track selection after the user picks [pickedId] (`auto`
/// clears everything). A newly picked provider is pinned as the
/// override AND the previously current provider is excluded from its
/// fallback chain, so switching always attempts the best provider
/// excluding the current one instead of serving it again.
({String? override, Set<String> excludes}) nextLyricsSelection({
  required String? pickedId,
  required String? currentId,
  required Set<String> currentExcludes,
}) {
  if (pickedId == null || pickedId == LyricsProviderId.auto.id) {
    return (override: null, excludes: <String>{});
  }
  final excludes = currentId != null && currentId != pickedId
      ? {...currentExcludes, currentId}
      : Set<String>.from(currentExcludes);
  return (override: pickedId, excludes: excludes);
}

/// `Try another source`: keep the override, exclude the current
/// provider so the race settles on the best of the rest.
Set<String> retryLyricsExcludingCurrent({
  required String? currentId,
  required Set<String> excludes,
}) =>
    currentId == null
        ? Set<String>.from(excludes)
        : {...excludes, currentId};

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

// -- Kugou KRC (lyrics.kugou.com) --------------------------------------------
// Word-sync via encrypted KRC documents: search → download (Base64) →
// XOR decrypt → zlib inflate → KRC parse. HTTPS only. Ported from
// native `KugouLyricsApi` (round-trip verified live 2026-10-06).

const _kugouKey = [
  0x40, 0x47, 0x61, 0x77, 0x5e, 0x32, 0x74, 0x47,
  0x51, 0x36, 0x31, 0x2d, 0xce, 0xd2, 0x6e, 0x69,
];

const _kugouUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36';

final _krcOffsetRegex =
    RegExp(r'^\[offset:\s*([+-]?\d+)\s*]', caseSensitive: false);
final _krcLineRegex = RegExp(r'^\[(\d+),(\d+)](.*)$');
final _krcSyllableRegex = RegExp(r'<(\d+),(\d+),\d+>([^<]*)');
final _krcCreditRegex = RegExp(
  r'^\s*(?:lyrics\s*by|written\s*by|composed\s*by|produced\s*by|'
  r'arranged\s*by|recorded\s*(?:at|by)|mixed\s*by|remixed\s*by|'
  r'mixing\s*(?:assistant|engineer)?|mastered\s*by|mastering|drums|'
  r'guitar|bass|keyboards|strings|vocals?|作\s*词|作\s*曲|编\s*曲|'
  r'制\s*作(?:人)?|演\s*唱|录\s*音|混\s*音|母\s*带|吉\s*他|贝\s*斯|鼓)'
  r'\s*[:：]',
  caseSensitive: false,
);

bool _isKugouCreditLine(String text, bool isFirstLine) {
  if (_krcCreditRegex.hasMatch(text)) return true;
  if (isFirstLine &&
      (text.contains(' - ') ||
          text.contains(' – ') ||
          text.contains(' — '))) {
    return true;
  }
  return false;
}

/// Decrypt a KRC `content` payload: Base64 → drop 4 magic bytes →
/// XOR with the rotating key → zlib inflate. Null on any bad input.
String? decryptKugouKrc(String base64Content) {
  try {
    final enc = base64Decode(base64Content.trim());
    if (enc.length <= 4) return null;
    final xored = List<int>.generate(
      enc.length - 4,
      (i) => enc[i + 4] ^ _kugouKey[i % _kugouKey.length],
    );
    final inflated = ZLibCodec().decode(xored);
    return utf8.decode(inflated);
  } catch (_) {
    return null;
  }
}

/// Parse decrypted KRC text into word-timed lines. Credit rows and a
/// leading `Artist - Title` row are dropped.
List<LyricLine> parseKugouKrc(String krcText) {
  final lines = <LyricLine>[];
  var globalOffsetMs = 0;
  var isFirstRawLine = true;
  for (final rawLine in krcText.split('\n')) {
    final trimmed = rawLine.trim();
    if (trimmed.isEmpty || !trimmed.startsWith('[')) continue;
    final offsetMatch = _krcOffsetRegex.firstMatch(trimmed);
    if (offsetMatch != null) {
      globalOffsetMs = int.tryParse(offsetMatch.group(1) ?? '') ?? 0;
      continue;
    }
    final match = _krcLineRegex.firstMatch(trimmed);
    if (match == null) continue;
    final rawStart = int.tryParse(match.group(1) ?? '');
    if (rawStart == null) continue;
    final lineDurationMs = int.tryParse(match.group(2) ?? '') ?? 0;
    final syllablesContent = match.group(3) ?? '';
    final lineStartMs = math.max(0, rawStart + globalOffsetMs);

    final syllables = <LyricSyllable>[];
    final buf = StringBuffer();
    for (final sylMatch in _krcSyllableRegex.allMatches(syllablesContent)) {
      final offsetMs = int.tryParse(sylMatch.group(1) ?? '') ?? 0;
      final durMs = int.tryParse(sylMatch.group(2) ?? '') ?? 0;
      final sylText = sylMatch.group(3) ?? '';
      if (sylText.trim().isEmpty) {
        if (syllables.isNotEmpty &&
            !syllables.last.text.endsWith(' ')) {
          final last = syllables.last;
          syllables[syllables.length - 1] = LyricSyllable(
            timeMs: last.timeMs,
            durationMs: last.durationMs,
            text: '${last.text} ',
            isBackground: last.isBackground,
          );
        }
        buf.write(sylText);
        continue;
      }
      syllables.add(LyricSyllable(
        timeMs: math.max(0, lineStartMs + offsetMs),
        durationMs: durMs,
        text: sylText,
      ));
      buf.write(sylText);
    }

    final fullLineText = buf.toString().trim();
    if (fullLineText.isNotEmpty && syllables.isNotEmpty) {
      final isCredit = _isKugouCreditLine(fullLineText, isFirstRawLine);
      isFirstRawLine = false;
      if (isCredit) continue;
      lines.add(LyricLine(
        timeMs: lineStartMs,
        durationMs: lineDurationMs,
        text: fullLineText,
        syllables: syllables,
      ));
    }
  }
  lines.sort((a, b) => a.timeMs.compareTo(b.timeMs));
  return lines;
}

String _kugouCleanArtist(String raw) {
  final noFeat = raw
      .replaceAll(
          RegExp(r'\s*(?:feat\.?|ft\.?)\s+.*$', caseSensitive: false), '')
      .trim();
  return lyricsForSearchArtist(noFeat.isEmpty ? raw : noFeat);
}

int _kugouDurationDelta(
    Map<String, dynamic> cand, int? durationSeconds) {
  final candMs = (cand['duration'] as num?)?.toInt() ?? 0;
  if (durationSeconds == null || durationSeconds <= 0 || candMs <= 0) {
    return 0;
  }
  return (candMs - durationSeconds * 1000).abs();
}

/// Search Kugou, download the best text-matched KRC, decrypt + parse.
/// Text match is mandatory: duration alone never selects a candidate.
Future<LyricsResult?> fetchKugou(
  Dio dio, {
  required String title,
  required String artist,
  int? durationSeconds,
}) async {
  if (title.trim().isEmpty || artist.trim().isEmpty) return null;
  try {
    final cleanedTitle = lyricsForSearchTitle(title);
    final cleanedArtist = _kugouCleanArtist(artist);
    var searchTitle = stripLeadingArtistPrefix(cleanedTitle);
    if (searchTitle.isEmpty) searchTitle = cleanedTitle;

    final searchRes = await dio.get<Map<String, dynamic>>(
      'https://lyrics.kugou.com/search',
      queryParameters: {
        'ver': '1',
        'man': 'yes',
        'client': 'pc',
        'keyword': '$cleanedArtist - $searchTitle',
        'duration': durationSeconds != null && durationSeconds > 0
            ? '${durationSeconds * 1000}'
            : '',
        'hash': '',
      },
      options: Options(headers: {'User-Agent': _kugouUserAgent}),
    );
    final candidates = searchRes.data?['candidates'];
    if (candidates is! List || candidates.isEmpty) return null;

    bool textMatches(Map<String, dynamic> cand) {
      final song = cand['song']?.toString() ?? '';
      // Never serve the wrong recording (live/remix/cover/etc.).
      if (!lyricsSameVersion(title, song)) return false;
      final candSinger = _kugouCleanArtist(cand['singer']?.toString() ?? '');
      final candSong = lyricsForSearchTitle(song);
      if (!_artistMatchesLoose(candSinger, cleanedArtist)) return false;
      return lyricsTitlesMatchStrict(candSong, cleanedTitle) ||
          lyricsTitlesMatchStrict(candSong, searchTitle);
    }

    final matched = [
      for (final c in candidates)
        if (c is Map<String, dynamic> && textMatches(c)) c
        else if (c is Map &&
            textMatches(Map<String, dynamic>.from(c)))
          Map<String, dynamic>.from(c),
    ]..sort((a, b) => _kugouDurationDelta(a, durationSeconds)
        .compareTo(_kugouDurationDelta(b, durationSeconds)));
    if (matched.isEmpty) return null;

    Map<String, dynamic>? pick(int maxDelta) {
      for (final c in matched) {
        if (_kugouDurationDelta(c, durationSeconds) <= maxDelta) return c;
      }
      return null;
    }

    final candidate =
        pick(8000) ?? pick(30000) ?? matched.first;

    final downloadRes = await dio.get<Map<String, dynamic>>(
      'https://lyrics.kugou.com/download',
      queryParameters: {
        'ver': '1',
        'client': 'pc',
        'id': '${candidate['id']}',
        'accesskey': '${candidate['accesskey']}',
        'fmt': 'krc',
        'charset': 'utf8',
      },
      options: Options(headers: {'User-Agent': _kugouUserAgent}),
    );
    final rawBase64 = downloadRes.data?['content']?.toString();
    if (rawBase64 == null || rawBase64.isEmpty) return null;
    final krcText = decryptKugouKrc(rawBase64);
    if (krcText == null) return null;
    final lines = parseKugouKrc(krcText);
    if (lines.isEmpty) return null;
    if (!lyricsPlausibleDuration(lines, durationSeconds)) return null;
    return LyricsResult(
      lines: lines,
      isSynced: true,
      isWordSynced: lines.any((l) => l.hasSyllables),
      plainLyrics: lines.map((l) => l.text).join('\n'),
      source: 'Kugou KRC (Word-Sync)',
    );
  } catch (_) {
    return null;
  }
}

bool _artistMatchesLoose(String candidate, String request) {
  if (candidate.isEmpty || request.isEmpty) return false;
  if (candidate.toLowerCase() == request.toLowerCase()) return true;
  return lyricsArtistsMatchStrict(candidate, request);
}

// -- Musixmatch (apic.musixmatch.com) ------------------------------------------
// Line-sync from the largest catalogue via its web client. No API key:
// requests carry the client's signature scheme plus a session token
// that is refreshed when the service rejects it. Ported from native
// `MusixmatchLyricsApi` (host verified alive 2026-10-06 via 401 JSON).

const _mxmBase = 'https://apic.musixmatch.com/ws/1.1';
const _mxmAppId = 'web-desktop-app-v1.0';
const _mxmSigningSecret = 'RJDefUswhwjkZDeM';

String? _mxmToken;

String _twoDigits(int n) => n.toString().padLeft(2, '0');

/// Sign a Musixmatch URL the web-client way: HMAC-SHA256 over
/// `url + yyyyMMdd(UTC)`, Base64, appended with the sha256 protocol.
/// [now] is injectable for deterministic tests.
String musixmatchSign(String url, {DateTime? now}) {
  final date = (now ?? DateTime.now()).toUtc();
  final stamp = '${date.year}${_twoDigits(date.month)}${_twoDigits(date.day)}';
  final hmac = Hmac(sha256, utf8.encode(_mxmSigningSecret));
  final raw = hmac.convert(utf8.encode('$url$stamp')).bytes;
  final signature = base64Encode(raw);
  return '$url&signature=${Uri.encodeQueryComponent(signature)}&signature_protocol=sha256';
}

double musixmatchScore({
  required String trackName,
  required String artistName,
  int? trackLength,
  required String title,
  required String artist,
  required int seconds,
}) {
  var score = 0.0;
  final name = trackName.trim().toLowerCase();
  final targetTitle = title.trim().toLowerCase();
  if (name == targetTitle) {
    score += 80;
  } else if (name.contains(targetTitle) || targetTitle.contains(name)) {
    score += 40;
  }
  if (artistName.trim().toLowerCase().contains(artist.trim().toLowerCase())) {
    score += 40;
  }
  if (trackLength != null && seconds > 0) {
    final diff = (trackLength - seconds).abs();
    if (diff <= 2) {
      score += 30;
    } else if (diff <= 5) {
      score += 15;
    } else if (diff <= 10) {
      score += 5;
    } else {
      score -= 20;
    }
  }
  return score;
}

/// `[{text, time:{total:sec}}]` subtitle JSON → LRC text.
String musixmatchSubtitleToLrc(String subtitleBody) {
  dynamic decoded;
  try {
    decoded = jsonDecode(subtitleBody);
  } catch (_) {
    return '';
  }
  if (decoded is! List) return '';
  final buf = StringBuffer();
  for (final item in decoded) {
    if (item is! Map) continue;
    final text = item['text']?.toString() ?? '';
    if (text.trim().isEmpty) continue;
    final time = item['time'];
    final total =
        time is Map ? (time['total'] as num?)?.toDouble() ?? 0 : 0.0;
    final totalMs = (total * 1000).toInt();
    final minutes = totalMs ~/ 60000;
    final seconds = (totalMs ~/ 1000) % 60;
    final millis = totalMs % 1000;
    buf.write('[${_twoDigits(minutes)}:${_twoDigits(seconds)}.'
        '${millis.toString().padLeft(3, '0')}]$text\n');
  }
  return buf.toString().trim();
}

Future<String?> _mxmGet(Dio dio, String url) async {
  try {
    final res = await dio.get(
      url,
      options: Options(headers: {'Accept': 'application/json'}),
    );
    final data = res.data;
    if (data == null) return null;
    if (data is String) return data;
    return jsonEncode(data);
  } catch (_) {
    return null;
  }
}

bool _mxmUnauthorized(String body) {
  try {
    final decoded = jsonDecode(body);
    final status = decoded['message']?['header']?['status_code'];
    return status == 401 || status == 402;
  } catch (_) {
    return false;
  }
}

Future<String?> _mxmTokenFor(Dio dio) async {
  if (_mxmToken != null) return _mxmToken;
  final body = await _mxmGet(dio, musixmatchSign('$_mxmBase/token.get?app_id=$_mxmAppId'));
  if (body == null) return null;
  try {
    final token = jsonDecode(body)['message']?['body']?['user_token'];
    if (token is String && token.isNotEmpty) {
      _mxmToken = token;
      return token;
    }
  } catch (_) {}
  return null;
}

/// GET with the session token; refresh once when the service rejects it.
Future<String?> _mxmSignedGet(Dio dio, String unsignedUrl) async {
  final token = await _mxmTokenFor(dio);
  if (token == null) return null;
  final first =
      await _mxmGet(dio, musixmatchSign('$unsignedUrl&usertoken=$token'));
  if (first != null && !_mxmUnauthorized(first)) return first;
  _mxmToken = null;
  final fresh = await _mxmTokenFor(dio);
  if (fresh == null) return null;
  return _mxmGet(dio, musixmatchSign('$unsignedUrl&usertoken=$fresh'));
}

Future<List<Map<String, dynamic>>?> _mxmSearchTracks(
  Dio dio,
  String title,
  String artist,
) async {
  final query =
      '$_mxmBase/track.search?app_id=$_mxmAppId&q_track=${Uri.encodeQueryComponent(title)}&q_artist=${Uri.encodeQueryComponent(artist)}&f_has_lyrics=1&s_track_rating=desc&quorum_factor=1&page_size=10&page=1';
  final body = await _mxmSignedGet(dio, query);
  if (body == null) return null;
  try {
    final list = jsonDecode(body)['message']?['body']?['track_list'];
    if (list is! List) return null;
    return [
      for (final item in list)
        if (item is Map<String, dynamic>) item,
    ];
  } catch (_) {
    return null;
  }
}

Future<LyricsResult?> fetchMusixmatch(
  Dio dio, {
  required String title,
  required String artist,
  int? durationSeconds,
}) async {
  if (title.trim().isEmpty || artist.trim().isEmpty) return null;
  try {
    final seconds = durationSeconds ?? 0;
    final tracks = await _mxmSearchTracks(dio, title, artist);
    if (tracks == null || tracks.isEmpty) return null;
    // Both sides must agree: title-exact homonyms and same-singer wrong
    // songs otherwise win on a high partial score with wrong timing.
    Map<String, dynamic>? best;
    var bestScore = 0.0;
    for (final wrapper in tracks) {
      final track = wrapper['track'];
      if (track is! Map<String, dynamic>) continue;
      final artistOk = artist.trim().isEmpty ||
          (track['artist_name']?.toString() ?? '')
              .toLowerCase()
              .contains(artist.trim().toLowerCase());
      if (!artistOk) continue;
      final score = musixmatchScore(
        trackName: track['track_name']?.toString() ?? '',
        artistName: track['artist_name']?.toString() ?? '',
        trackLength: (track['track_length'] as num?)?.toInt(),
        title: title,
        artist: artist,
        seconds: seconds,
      );
      if (score < 80 || score <= bestScore) continue;
      bestScore = score;
      best = track;
    }
    if (best == null) return null;
    if ((best['has_subtitles'] as num?)?.toInt() != 1) return null;
    final trackId = '${best['track_id']}';
    final subBody = await _mxmSignedGet(
      dio,
      '$_mxmBase/track.subtitle.get?app_id=$_mxmAppId&track_id=${Uri.encodeQueryComponent(trackId)}&subtitle_format=mxm',
    );
    if (subBody == null) return null;
    String? subtitle;
    try {
      subtitle =
          jsonDecode(subBody)['message']?['body']?['subtitle']?['subtitle_body']
              ?.toString();
    } catch (_) {
      return null;
    }
    if (subtitle == null || subtitle.isEmpty) return null;
    final lrc = musixmatchSubtitleToLrc(subtitle);
    if (lrc.isEmpty) return null;
    final lines = parseLrc(lrc);
    if (lines.isEmpty) return null;
    // Server fuzzy-matches with no usable candidate identity: reject
    // wrong-cut timelines before they poison line-sync.
    if (!lyricsPlausibleDuration(lines, durationSeconds)) return null;
    return LyricsResult(
      lines: lines,
      isSynced: true,
      isWordSynced: lines.any((l) => l.hasSyllables),
      plainLyrics: lines.map((l) => l.text).join('\n'),
      source: 'Catalog (Line-Sync)',
    );
  } catch (_) {
    return null;
  }
}

// -- SimpMusic (api-lyrics.simpmusic.org) --------------------------------------
// Community database keyed on the playing video id, so the exact cut
// that is playing is looked up instead of a same-name edit. Rich sync
// is enhanced LRC with per-word stamps; plain LRC is the fallback.
// Ported from native `SimpMusicLyricsApi`.

/// Returns raw lines (the race in `LyricsRepository` wraps them with the
/// `Video-Match` source label and plausibility gate), null on miss.
Future<List<LyricLine>?> fetchSimpMusic(
  Dio dio, {
  String? videoId,
  int? durationSeconds,
}) async {
  if (videoId == null || videoId.trim().isEmpty) return null;
  try {
    final res = await dio.get<Map<String, dynamic>>(
      'https://api-lyrics.simpmusic.org/v1/${videoId.trim()}',
      options: Options(headers: {'Accept': 'application/json'}),
    );
    final data = res.data;
    if (data == null || data['success'] != true) return null;
    final tracks = data['data'];
    if (tracks is! List) return null;
    final seconds = durationSeconds != null && durationSeconds > 0
        ? durationSeconds
        : 0;
    Map<String, dynamic>? pick;
    var pickDelta = 1 << 30;
    for (final item in tracks) {
      final track =
          item is Map<String, dynamic> ? item : Map<String, dynamic>.from(item as Map);
      final trackSecs = (track['duration'] as num?)?.toInt() ?? 0;
      if (seconds > 0 && (trackSecs - seconds).abs() > 10) continue;
      final delta = (trackSecs - seconds).abs();
      if (delta < pickDelta) {
        pickDelta = delta;
        pick = track;
      }
    }
    if (pick == null) return null;
    final rich = pick['richSyncLyrics']?.toString() ?? '';
    if (rich.trim().isNotEmpty) {
      final lines = parseEnhancedLrc(rich);
      if (lines.isNotEmpty) return lines;
    }
    final synced = pick['syncedLyrics']?.toString() ?? '';
    if (synced.trim().isEmpty) return null;
    final lines = parseLrc(synced);
    return lines.isEmpty ? null : lines;
  } catch (_) {
    return null;
  }
}
