import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/dio_factory.dart';
import '../../core/storage/prefs.dart';

/// One translate request for the lines of the track that is open.
class LyricsTranslationKey {
  final String trackKey;
  final String target;
  final String fingerprint;

  const LyricsTranslationKey({
    required this.trackKey,
    required this.target,
    required this.fingerprint,
  });

  @override
  bool operator ==(Object other) =>
      other is LyricsTranslationKey &&
      other.trackKey == trackKey &&
      other.target == target &&
      other.fingerprint == fingerprint;

  @override
  int get hashCode => Object.hash(trackKey, target, fingerprint);
}

/// Sub-lines aligned with [lines]. Blank when a line should not be drawn
/// (empty, or identical to the original). Mirrors Android `LyricsTranslation`
/// using the same public translate endpoint, without the romanization retry.
class LyricsTranslator {
  LyricsTranslator(this._dio);

  final Dio _dio;
  final Map<String, List<String?>> _memory = {};

  Future<List<String?>> translate({
    required String trackKey,
    required String target,
    required List<String> lines,
  }) async {
    if (target == 'off' || target.isEmpty || lines.isEmpty) {
      return List<String?>.filled(lines.length, null);
    }
    final cacheKey = '$trackKey|$target|${lines.join('\n').hashCode}';
    final cached = _memory[cacheKey];
    if (cached != null && cached.length == lines.length) return cached;

    final slots = <int>[];
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].trim().isNotEmpty) slots.add(i);
    }
    final out = List<String?>.filled(lines.length, null);
    if (slots.isEmpty) return out;

    const maxChars = 3500;
    var start = 0;
    while (start < slots.length) {
      var end = start;
      var length = 0;
      while (end < slots.length) {
        final added = lines[slots[end]].length + 8;
        if (end > start && length + added > maxChars) break;
        length += added;
        end++;
      }
      final slice = slots.sublist(start, end);
      final translated = await _batch(
        [for (final index in slice) lines[index]],
        target,
      );
      if (translated == null || translated.length != slice.length) {
        return out;
      }
      for (var i = 0; i < slice.length; i++) {
        final text = translated[i].trim();
        final original = lines[slice[i]].trim();
        if (text.isEmpty || text == original) continue;
        out[slice[i]] = text;
      }
      start = end;
    }
    _memory[cacheKey] = out;
    return out;
  }

  Future<List<String>?> _batch(List<String> texts, String target) async {
    final marker = RegExp('\uE000[^\uE001]*\uE001');
    final payload = StringBuffer();
    for (var i = 0; i < texts.length; i++) {
      if (i > 0) {
        payload
          ..write('\n')
          ..write('\uE000${i.toString().padLeft(4, '0')}\uE001')
          ..write('\n');
      }
      payload.write(texts[i]);
    }
    try {
      final res = await _dio.post<String>(
        'https://translate.googleapis.com/translate_a/single',
        data: {
          'client': 'dict-chrome-ex',
          'sl': 'auto',
          'tl': target,
          'dt': 't',
          'q': payload.toString(),
        },
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          responseType: ResponseType.plain,
          headers: const {
            'User-Agent': 'LastWave/1.0',
            'Accept': 'application/json',
          },
        ),
      );
      final body = res.data;
      if (body == null || body.isEmpty) return null;
      final root = jsonDecode(body);
      if (root is! List || root.isEmpty || root[0] is! List) return null;
      final joined = StringBuffer();
      for (final segment in root[0] as List) {
        if (segment is List && segment.isNotEmpty) {
          joined.write(segment.first?.toString() ?? '');
        }
      }
      final parts = joined.toString().split(marker).map((s) => s.trim()).toList();
      if (parts.length != texts.length || parts.any((s) => s.isEmpty)) {
        return null;
      }
      return parts;
    } catch (_) {
      return null;
    }
  }
}

final lyricsTranslatorProvider = Provider<LyricsTranslator>((ref) {
  return LyricsTranslator(DioFactory.create());
});

final lyricsTranslationProvider = FutureProvider.autoDispose
    .family<List<String?>, LyricsTranslationKey>((ref, key) async {
  if (key.target == 'off') return const [];
  final lines = key.fingerprint.split('\n');
  return ref.watch(lyricsTranslatorProvider).translate(
        trackKey: key.trackKey,
        target: key.target,
        lines: lines,
      );
});

/// Builds the provider key from the open track. Empty fingerprint when
/// translation is off, so the view does not start a request.
LyricsTranslationKey? lyricsTranslationKey({
  required String trackKey,
  required String target,
  required List<String> lines,
}) {
  if (target == 'off' || !Prefs.lyricsTranslationOptions.containsKey(target)) {
    return null;
  }
  return LyricsTranslationKey(
    trackKey: trackKey,
    target: target,
    fingerprint: lines.join('\n'),
  );
}
