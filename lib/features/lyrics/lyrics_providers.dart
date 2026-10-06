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
