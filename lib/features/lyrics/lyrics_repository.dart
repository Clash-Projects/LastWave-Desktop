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
      if (lineFallback == null ||
          (result.isSynced && !lineFallback.isSynced)) {
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

  // -- LRCLIB ---------------------------------------------------------------

  Future<LyricsResult?> _fetchLrclib(
    String title,
    String artist,
    String album,
    int? durationSeconds,
  ) async {
    Map<String, dynamic>? record;
    final attempts = [
      {'track_name': title, 'artist_name': artist, 'album_name': album},
      {'track_name': title, 'artist_name': artist},
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
                'LastWave-Desktop/1.0 (https://github.com/duxtami/LastWave)',
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
    record ??= await _lrclibSearch(title, artist);
    if (record == null) return null;
    if (record['instrumental'] == true) {
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
              'LastWave-Desktop/1.0 (https://github.com/duxtami/LastWave)',
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

  // -- LyricsPlus (word-synced) -----------------------------------------------

  static const _lyricsPlusEndpoints = [
    'https://lyricsplus.prjktla.my.id/v2/lyrics/get',
    'https://lyricsplus.clashgram.workers.dev/v2/lyrics/get',
  ];

  Future<LyricsResult?> _fetchLyricsPlus(
    String title,
    String artist,
    String album,
    int? durationSeconds,
  ) async {
    for (final endpoint in _lyricsPlusEndpoints) {
      final qp = {'title': title, 'artist': artist};
      if (album.isNotEmpty) qp['album'] = album;
      if (durationSeconds != null && durationSeconds > 0) {
        qp['duration'] = '$durationSeconds';
      }
      try {
        final res = await _dio.get<Map<String, dynamic>>(
          endpoint,
          queryParameters: qp,
          options: Options(headers: {
            'User-Agent': 'LastWave-Desktop/1.0',
            'Accept': 'application/json',
            if (AppEnv.lyricsApiKey.isNotEmpty)
              'x-api-key': AppEnv.lyricsApiKey,
          }),
        );
        final parsed = _parseLyricsPlus(res.data ?? const {});
        if (parsed != null) return parsed;
      } catch (_) {}
    }
    return null;
  }

  LyricsResult? _parseLyricsPlus(Map<String, dynamic> json) {
    final lyrics = json['lyrics'];
    if (lyrics is! List || lyrics.isEmpty) return null;
    final type = json['type']?.toString().toUpperCase() ?? 'LINE';
    final lines = <LyricLine>[];
    for (final item in lyrics) {
      if (item is! Map<String, dynamic>) continue;
      final time = (item['time'] as num?)?.toInt() ?? 0;
      final duration = (item['duration'] as num?)?.toInt() ?? 0;
      final text = item['text']?.toString() ?? '';
      if (text.isEmpty) continue;
      final syllabus = item['syllabus'];
      final syllables = <LyricSyllable>[];
      if (syllabus is List) {
        for (final s in syllabus) {
          if (s is! Map<String, dynamic>) continue;
          syllables.add(LyricSyllable(
            timeMs: (s['time'] as num?)?.toInt() ?? time,
            durationMs: (s['duration'] as num?)?.toInt() ?? 0,
            text: s['text']?.toString() ?? '',
            isBackground: s['isBackground'] == true,
          ));
        }
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
      isWordSynced:
          type == 'WORD' || lines.any((l) => l.hasSyllables),
      source: 'lyricsplus',
    );
  }

  // -- BetterLyrics (TTML → word timing) -----------------------------------------

  Future<LyricsResult?> _fetchBetterLyrics(
      String title, String artist) async {
    const base = 'https://lyrics-api.boidu.dev';
    final attempts = [
      '$base/getLyrics',
      '$base/ttml/getLyrics',
    ];
    for (final url in attempts) {
      try {
        final res = await _dio.get<Map<String, dynamic>>(
          url,
          queryParameters: {'s': title, 'a': artist},
          options: Options(headers: {
            'User-Agent': 'LastWave-Desktop/1.0',
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
            source: 'betterlyrics',
          );
        }
      } catch (_) {}
    }
    return null;
  }

  /// Parse TTML (`<p begin end>` lines, `<span begin end>` words).
  /// Mirrors `BetterLyricsApi.parseTtml`.
  static List<LyricLine> parseTtml(String ttml) {
    final pTag = RegExp(
        r'<p\s+[^>]*begin="([^"]+)"[^>]*end="([^"]+)"[^>]*>(.*?)</p>',
        dotAll: true);
    final spanTag = RegExp(
        r'<span\s+[^>]*begin="([^"]+)"[^>]*end="([^"]+)"[^>]*>(.*?)</span>',
        dotAll: true);
    final xmlTag = RegExp(r'<[^>]+>');
    final lines = <LyricLine>[];
    for (final p in pTag.allMatches(ttml)) {
      final start = _parseTtmlTime(p.group(1) ?? '');
      final end = _parseTtmlTime(p.group(2) ?? '');
      final inner = p.group(3) ?? '';
      final spans = spanTag.allMatches(inner).toList();
      if (spans.isEmpty) {
        final text = _unescapeXml(
            inner.replaceAll(xmlTag, '').trim());
        if (text.isEmpty) continue;
        lines.add(LyricLine(
          timeMs: start,
          durationMs: (end - start).clamp(0, 1 << 31),
          text: text,
        ));
      } else {
        final syllables = <LyricSyllable>[];
        final buf = StringBuffer();
        for (final s in spans) {
          final ws = _parseTtmlTime(s.group(1) ?? '');
          final we = _parseTtmlTime(s.group(2) ?? '');
          final wt =
              _unescapeXml((s.group(3) ?? '').replaceAll(xmlTag, ''));
          syllables.add(LyricSyllable(
            timeMs: ws,
            durationMs: (we - ws).clamp(0, 1 << 31),
            text: wt,
          ));
          buf.write(wt);
          buf.write(' ');
        }
        final text = buf.toString().trim();
        if (text.isEmpty) continue;
        lines.add(LyricLine(
          timeMs: start,
          durationMs: (end - start).clamp(0, 1 << 31),
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
      if (s.contains(':')) {
        final parts = s.split(':');
        var ms = 0;
        for (final part in parts) {
          ms = ms * 60 + (double.parse(part) * 1000).round();
        }
        // adjust: loop above over-multiplies; recompute properly
        final nums =
            parts.map(double.parse).toList().reversed.toList();
        var total = 0.0;
        var mult = 1.0;
        for (final n in nums) {
          total += n * mult;
          mult *= 60;
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
