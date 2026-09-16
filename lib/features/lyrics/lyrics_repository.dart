import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/env/app_env.dart';
import '../../core/network/dio_factory.dart';
import 'lyrics_models.dart';

/// Lyrics orchestrator with word-by-word racing.
///
/// Ported from LastWave-native `LyricsRepository.kt`:
/// - in-memory cache (word-synced entries preferred)
/// - when `wordByWord` is requested, race LyricsPlus / BetterLyrics /
///   Kugou and return the first word-synced result immediately while
///   keeping a line-synced fallback
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
      if (wordByWord) ...[
        _fetchBiniLyrics(title, artist, album, durationSeconds),
        _fetchLyricsPlus(title, artist, album, durationSeconds),
        _fetchBetterLyrics(title, artist),
        _fetchKugou(title, artist, durationSeconds),
      ],
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

    // 3. Official curated sources (Apple Music, LyricsPlus, BetterLyrics)
    // beat crowdsourced user submissions (lrclib)
    final newIsCurated = newRes.source.toLowerCase().contains('apple') ||
        newRes.source.toLowerCase().contains('lyricsplus') ||
        newRes.source.toLowerCase().contains('betterlyrics');
    final curIsCurated = current.source.toLowerCase().contains('apple') ||
        current.source.toLowerCase().contains('lyricsplus') ||
        current.source.toLowerCase().contains('betterlyrics');
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
          record = res.data;
          break;
        }
      } on DioException catch (e) {
        if (e.response?.statusCode != 404) rethrow;
      }
    }
    // cleaned-title retry
    record ??= await _lrclibSearch(cleanT, cleanA);
    if (record == null && (cleanT != title || cleanA != artist)) {
      record = await _lrclibSearch(title, artist);
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
      String title, String artist) async {
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
      for (final item in list) {
        if (item is! Map<String, dynamic>) continue;
        final a =
            (item['artistName']?.toString() ?? '').toLowerCase();
        final t =
            (item['trackName']?.toString() ?? '').toLowerCase();
        if (a.contains(artist.toLowerCase()) ||
            artist.toLowerCase().contains(a)) {
          if (t.contains(title.toLowerCase()) ||
              title.toLowerCase().contains(t)) {
            return item;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  // -- BiniLyrics (Apple Music TTML → exact word timing) ---------------------

  Future<LyricsResult?> _fetchBiniLyrics(
    String title,
    String artist,
    String album,
    int? durationSeconds,
  ) async {
    final cleanT = cleanSongTitle(title);
    final cleanA = cleanSongArtist(artist);
    final attempts = [
      {'track': cleanT, 'artist': cleanA},
      if (cleanT != title || cleanA != artist)
        {'track': title, 'artist': artist},
    ];
    for (final p in attempts) {
      try {
        final qp = Map<String, String>.from(p);
        if (album.isNotEmpty) qp['album'] = album;
        if (durationSeconds != null && durationSeconds > 0) {
          qp['duration'] = '$durationSeconds';
        }
        final res = await _dio.get<Map<String, dynamic>>(
          'https://lyrics-api.binimum.org/',
          queryParameters: qp,
          options: Options(headers: {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
            'Accept': 'application/json',
          }),
        );
        final results = res.data?['results'];
        if (results is! List || results.isEmpty) continue;
        final first = results.first;
        if (first is! Map<String, dynamic>) continue;
        final lyricsUrl = first['lyricsUrl']?.toString() ?? '';
        if (lyricsUrl.isEmpty) continue;
        final ttmlRes = await _dio.get<String>(
          lyricsUrl,
          options: Options(
            responseType: ResponseType.plain,
            headers: {
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
            },
          ),
        );
        final ttml = ttmlRes.data ?? '';
        if (ttml.isEmpty) continue;
        final lines = parseTtml(ttml);
        if (lines.isNotEmpty) {
          return LyricsResult(
            lines: lines,
            isSynced: true,
            isWordSynced: lines.any((l) => l.hasSyllables),
            source: 'Apple Music',
          );
        }
      } catch (_) {}
    }
    return null;
  }

  // -- LyricsPlus (word-synced) -----------------------------------------------

  static const _lyricsPlusEndpoints = [
    'https://lyricsplus.binimum.org/v2/lyrics/get',
    'https://lyricsplus-seven.vercel.app/v2/lyrics/get',
  ];

  Future<LyricsResult?> _fetchLyricsPlus(
    String title,
    String artist,
    String album,
    int? durationSeconds,
  ) async {
    final cleanT = cleanSongTitle(title);
    final cleanA = cleanSongArtist(artist);
    final attempts = [
      {'title': cleanT, 'artist': cleanA},
      if (cleanT != title || cleanA != artist)
        {'title': title, 'artist': artist},
    ];
    for (final endpoint in _lyricsPlusEndpoints) {
      for (final p in attempts) {
        final qp = Map<String, String>.from(p);
        if (album.isNotEmpty) qp['album'] = album;
        if (durationSeconds != null && durationSeconds > 0) {
          qp['duration'] = '$durationSeconds';
        }
        try {
          final res = await _dio.get<Map<String, dynamic>>(
            endpoint,
            queryParameters: qp,
            options: Options(headers: {
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
              'Accept': 'application/json',
              if (AppEnv.lyricsApiKey.isNotEmpty)
                'x-api-key': AppEnv.lyricsApiKey,
            }),
          );
          final parsed = _parseLyricsPlus(res.data ?? const {});
          if (parsed != null) return parsed;
        } catch (_) {}
      }
    }
    return null;
  }

  LyricsResult? _parseLyricsPlus(Map<String, dynamic> json) {
    final lyrics = json['lyrics'];
    if (lyrics is! List || lyrics.isEmpty) return null;
    final type = json['type']?.toString().toUpperCase() ?? 'LINE';
    final winner = json['winnerSource']?.toString().toLowerCase() ?? '';
    final sourceName = winner.contains('apple')
        ? 'Apple Music'
        : winner.isNotEmpty
            ? winner
            : 'LyricsPlus';
    final lines = <LyricLine>[];
    var hasNativeSyllables = false;
    for (final item in lyrics) {
      if (item is! Map<String, dynamic>) continue;
      final time = (item['time'] as num?)?.toInt() ?? 0;
      final duration = (item['duration'] as num?)?.toInt() ?? 0;
      final text = item['text']?.toString() ?? '';
      if (text.isEmpty) continue;
      final syllabus = item['syllabus'];
      final syllables = <LyricSyllable>[];
      if (syllabus is List && syllabus.isNotEmpty) {
        hasNativeSyllables = true;
        for (final s in syllabus) {
          if (s is! Map<String, dynamic>) continue;
          syllables.add(LyricSyllable(
            timeMs: (s['time'] as num?)?.toInt() ?? time,
            durationMs: (s['duration'] as num?)?.toInt() ?? 0,
            text: s['text']?.toString() ?? '',
            isBackground: s['isBackground'] == true,
          ));
        }
      } else {
        // Synthesize word syllables if not provided
        syllables.addAll(interpolateLineSyllables(
          text: text,
          startTimeMs: time,
          durationMs: duration > 0 ? duration : 4000,
        ));
      }
      lines.add(LyricLine(
        timeMs: time,
        durationMs: duration,
        text: text,
        syllables: syllables,
      ));
    }
    if (lines.isEmpty) return null;
    lines.sort((a, b) => a.timeMs.compareTo(b.timeMs));
    return LyricsResult(
      lines: lines,
      isSynced: true,
      isWordSynced: type == 'WORD' || hasNativeSyllables,
      source: sourceName,
    );
  }

  // -- BetterLyrics (TTML → word timing) -----------------------------------------

  Future<LyricsResult?> _fetchBetterLyrics(
      String title, String artist) async {
    const base = 'https://lyrics-api.boidu.dev';
    final cleanT = cleanSongTitle(title);
    final cleanA = cleanSongArtist(artist);
    final attempts = [
      '$base/getLyrics',
      '$base/ttml/getLyrics',
    ];
    for (final url in attempts) {
      try {
        final res = await _dio.get<Map<String, dynamic>>(
          url,
          queryParameters: {'s': cleanT, 'a': cleanA},
          options: Options(headers: {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
            'Accept': 'application/json',
          }),
        );
        final ttml = res.data?['ttml']?.toString() ??
            res.data?['lyrics']?.toString() ??
            '';
        if (ttml.isEmpty) continue;
        final parsed = parseTtml(ttml);
        if (parsed.isNotEmpty) {
          return LyricsResult(
            lines: parsed,
            isSynced: true,
            isWordSynced: parsed.any((l) => l.hasSyllables),
            source: 'BetterLyrics',
          );
        }
      } catch (_) {}
    }
    return null;
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

  // -- Kugou (KRC → word timing) -----------------------------------------------------

  static const _krcKey = [
    0x40, 0x47, 0x61, 0x77, 0x5E, 0x32, 0x74, 0x47,
    0x51, 0x36, 0x31, 0x2D, 0xCE, 0xD2, 0x6E, 0x69,
  ];

  Future<LyricsResult?> _fetchKugou(
    String title,
    String artist,
    int? durationSeconds,
  ) async {
    try {
      final search = await _dio.get<Map<String, dynamic>>(
        'https://lyrics.kugou.com/search',
        queryParameters: {
          'ver': '1',
          'man': 'yes',
          'client': 'pc',
          'keyword': '$artist - $title',
          if (durationSeconds != null && durationSeconds > 0)
            'duration': '${durationSeconds * 1000}',
          'hash': '',
        },
        options: Options(headers: {'User-Agent': DioFactory.desktopUserAgent}),
      );
      final candidates =
          (search.data?['candidates'] as List?) ?? const [];
      if (candidates.isEmpty) return null;
      final first = candidates.first as Map<String, dynamic>;
      final dl = await _dio.get<Map<String, dynamic>>(
        'https://lyrics.kugou.com/download',
        queryParameters: {
          'ver': '1',
          'client': 'pc',
          'id': '${first['id']}',
          'accesskey': '${first['accesskey']}',
          'fmt': 'krc',
          'charset': 'utf8',
        },
        options: Options(headers: {'User-Agent': DioFactory.desktopUserAgent}),
      );
      final content = dl.data?['content']?.toString() ?? '';
      if (content.isEmpty) return null;
      final lines = parseKrc(decryptKrc(content));
      if (lines.isEmpty) return null;
      return LyricsResult(
        lines: lines,
        isSynced: true,
        isWordSynced: lines.any((l) => l.hasSyllables),
        source: 'kugou',
      );
    } catch (_) {
      return null;
    }
  }

  /// KRC decrypt: base64 → skip `krc1` header → XOR key → zlib inflate.
  /// Mirrors `KugouLyricsApi.decryptKrc`.
  static String decryptKrc(String base64Content) {
    try {
      var bytes = base64.decode(base64Content);
      if (bytes.length > 4) bytes = bytes.sublist(4);
      final xored = List<int>.generate(
        bytes.length,
        (i) => bytes[i] ^ _krcKey[i % _krcKey.length],
      );
      // zlib inflate via dart:io codec
      final inflated = zlib.decode(xored);
      return utf8.decode(inflated, allowMalformed: true);
    } catch (_) {
      return '';
    }
  }

  /// Parse decrypted KRC: `[start,dur]` lines with
  /// `<offset,dur,?>text` syllables. Mirrors `parseKrc`.
  static List<LyricLine> parseKrc(String krc) {
    final lineRegex = RegExp(r'^\[(\d+),(\d+)\](.*)$');
    final sylRegex = RegExp(r'<(\d+),(\d+),\d+>([^<]*)');
    final lines = <LyricLine>[];
    for (final raw in krc.split('\n')) {
      final m = lineRegex.firstMatch(raw.trim());
      if (m == null) continue;
      final start = int.tryParse(m.group(1) ?? '') ?? 0;
      final dur = int.tryParse(m.group(2) ?? '') ?? 0;
      final body = m.group(3) ?? '';
      final syllables = <LyricSyllable>[];
      final buf = StringBuffer();
      for (final s in sylRegex.allMatches(body)) {
        final off = int.tryParse(s.group(1) ?? '') ?? 0;
        final sd = int.tryParse(s.group(2) ?? '') ?? 0;
        final text = s.group(3) ?? '';
        syllables.add(LyricSyllable(
          timeMs: start + off,
          durationMs: sd,
          text: text,
        ));
        buf.write(text);
      }
      final text = buf.toString().trim();
      if (text.isEmpty) continue;
      lines.add(LyricLine(
        timeMs: start,
        durationMs: dur,
        text: text,
        syllables: syllables,
      ));
    }
    lines.sort((a, b) => a.timeMs.compareTo(b.timeMs));
    return lines;
  }
}

final lyricsRepositoryProvider =
    Provider<LyricsRepository>((_) => LyricsRepository());
