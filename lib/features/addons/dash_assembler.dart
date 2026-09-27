import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:xml/xml.dart';

/// Assembles server DASH manifests into one progressive fMP4 file.
///
/// Server manifests (inline `manifestXml` or remote `.mpd`) can never
/// reach libmpv directly: the bundled Windows mpv 0.36 demuxer opens
/// the FIRST manifest per process fine, then dies opening the SECOND
/// one (ntdll 0xc0000005, no Dart log — the await never returns).
/// Assembly sidesteps `dashdec` entirely: mpv opens the result with
/// its ordinary progressive `mov` demuxer, the same path local files
/// use on every platform.
///
/// Only the shapes this server emits are supported: static MPD, one
/// audio AdaptationSet, SegmentTemplate with `$Number$` (+ timeline).
/// Anything else returns null and callers fall through to YouTube —
/// a wrong guess here is worse than a fallback.
class DashAssembler {
  /// Refuse absurd manifests instead of downloading the internet.
  static const int maxSegments = 512;

  /// Segment fetch parallelism.
  static const int parallelDownloads = 12;

  /// Assembled-file cache caps (hi-res tracks are ~50–100MB each).
  static const int maxCachedFiles = 16;
  static const int maxCachedBytes = 1024 * 1024 * 1024;

  /// Pure manifest plan (unit-tested): init URL, media template,
  /// first segment number, total segment count. Null when the
  /// manifest isn't the supported audio/numbered shape.
  static ({
    String initUrl,
    String mediaTemplate,
    int startNumber,
    int segmentCount,
  })? planForManifest(String manifestXml) {
    try {
      final doc = XmlDocument.parse(manifestXml);
      final adaptations = doc
          .findAllElements('AdaptationSet')
          .where((a) {
            final type = a.getAttribute('contentType') ?? '';
            final mime = a.getAttribute('mimeType') ?? '';
            return type == 'audio' || mime.startsWith('audio/');
          })
          .toList();
      if (adaptations.isEmpty) return null;
      final firstSet = adaptations.first;
      final representations =
          firstSet.findElements('Representation').toList();
      if (representations.isEmpty) return null;
      // Richest rendition when the server sends several.
      representations.sort(
          (a, b) => _bandwidth(b).compareTo(_bandwidth(a)));
      final rep = representations.first;
      final template = rep.getElement('SegmentTemplate') ??
          firstSet.getElement('SegmentTemplate');
      if (template == null) return null;
      final init = template.getAttribute('initialization') ?? '';
      final media = template.getAttribute('media') ?? '';
      if (init.isEmpty ||
          media.isEmpty ||
          !media.contains(r'$Number')) {
        return null;
      }
      final start =
          int.tryParse(template.getAttribute('startNumber') ?? '1') ??
              1;
      final timeline = template.getElement('SegmentTimeline');
      if (timeline == null) return null;
      var count = 0;
      for (final s in timeline.findElements('S')) {
        final repeat =
            int.tryParse(s.getAttribute('r') ?? '0') ?? 0;
        count += repeat + 1;
      }
      if (count <= 0 || count > maxSegments) return null;
      return (
        initUrl: init,
        mediaTemplate: media,
        startNumber: start,
        segmentCount: count,
      );
    } catch (_) {
      return null;
    }
  }

  static int _bandwidth(XmlElement rep) =>
      int.tryParse(rep.getAttribute('bandwidth') ?? '') ?? 0;

  /// Fill a `$Number$` (or `$Number%0Nd$`) template. Pure, unit-tested.
  static String segmentUrlFor(String template, int number) {
    return template.replaceAllMapped(
      RegExp(r'\$Number(%0(\d+)d)?\$'),
      (m) {
        final width = m.group(2);
        if (width == null) return number.toString();
        return number.toString().padLeft(int.parse(width), '0');
      },
    );
  }

  /// Single fetch (init segment, remote manifest). Null on miss.
  static Future<List<int>?> fetchBytes(Dio dio, String url) async {
    try {
      final res = await dio
          .get<List<int>>(url,
              options: Options(responseType: ResponseType.bytes))
          .timeout(const Duration(seconds: 20));
      final bytes = res.data;
      if (bytes == null || bytes.isEmpty) return null;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// Parallel-batched segment fetch. [onSegment] fires per arrival
  /// (arrival order varies); [onBatch] fires after each fully-arrived
  /// batch so callers can flush contiguous prefixes. False on any miss.
  static Future<bool> fetchSegments(
    Dio dio, {
    required String mediaTemplate,
    required int startNumber,
    required int count,
    required void Function(int index, List<int> bytes) onSegment,
    Future<void> Function(int base, int end)? onBatch,
  }) async {
    for (var base = 0; base < count; base += parallelDownloads) {
      final end = (base + parallelDownloads).clamp(0, count);
      final batch = <Future<bool>>[];
      for (var i = base; i < end; i++) {
        final index = i;
        batch.add(fetchBytes(
          dio,
          segmentUrlFor(mediaTemplate, startNumber + index),
        ).then((bytes) {
          if (bytes == null) return false;
          onSegment(index, bytes);
          return true;
        }));
      }
      final results = await Future.wait(batch);
      if (results.any((ok) => !ok)) return false;
      if (onBatch != null) await onBatch(base, end);
    }
    return true;
  }

  /// Enforce the assembled-file cache caps. [activeNames] are partials
  /// currently being written and must not be reaped.
  static Future<void> pruneCache([Set<String> activeNames = const {}]) async {
    try {
      final dir = Directory('${Directory.systemTemp.path}'
          '${Platform.pathSeparator}lastwave_addon'
          '${Platform.pathSeparator}assembled');
      if (!await dir.exists()) return;
      final finished = <File>[];
      await for (final e in dir.list()) {
        if (e is! File) continue;
        if (e.path.endsWith('.part')) {
          final base = e.path.split(Platform.pathSeparator).last;
          final name = base.substring(0, base.length - 5);
          if (!activeNames.contains(name)) {
            try {
              await e.delete();
            } catch (_) {}
          }
          continue;
        }
        if (e.path.endsWith('.m4a')) finished.add(e);
      }
      final modified = <File, DateTime>{};
      var total = 0;
      for (final f in finished) {
        try {
          final st = await f.stat();
          modified[f] = st.modified;
          total += st.size;
        } catch (_) {}
      }
      final oldestFirst = modified.keys.toList()
        ..sort((a, b) => modified[a]!.compareTo(modified[b]!));
      while ((oldestFirst.length > maxCachedFiles ||
              total > maxCachedBytes) &&
          oldestFirst.isNotEmpty) {
        final victim = oldestFirst.removeAt(0);
        try {
          total -= await victim.length();
          await victim.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }
}
