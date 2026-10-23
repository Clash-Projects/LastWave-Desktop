import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:xml/xml.dart';

/// Segment layout of one addon DASH manifest.
///
/// [timescale]/[durations] are the manifest's own `SegmentTimeline`
/// units — the loopback server rescales them into the media timescale
/// when it writes a `sidx` (per-fragment seek durations).
typedef DashPlan = ({
  String initUrl,
  String mediaTemplate,
  int startNumber,
  int segmentCount,
  int timescale,
  List<int> durations,
});

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

  /// Segment fetch parallelism. 6 left the pipe idle on high-latency
  /// CDNs (a 59MB hi-res track took ~17s at ~3.4MB/s); 10 keeps the
  /// link busy while staying under ~12MB of in-flight segment memory.
  static const int parallelDownloads = 10;

  /// Assembled-file cache caps (hi-res tracks are ~50–100MB each).
  static const int maxCachedFiles = 16;
  static const int maxCachedBytes = 1024 * 1024 * 1024;

  /// Pure manifest plan (unit-tested): init URL, media template,
  /// first segment number, total segment count, plus the segment
  /// timeline in the manifest's own timescale ([timescale]/[durations])
  /// which the file index needs for per-fragment seek durations.
  static DashPlan? planForManifest(String manifestXml) {
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
      final timescale =
          int.tryParse(template.getAttribute('timescale') ?? '') ?? 1;
      var count = 0;
      final durations = <int>[];
      var lastDuration = 0;
      for (final s in timeline.findElements('S')) {
        final d = int.tryParse(s.getAttribute('d') ?? '') ?? lastDuration;
        if (d <= 0) break;
        lastDuration = d;
        final repeat = int.tryParse(s.getAttribute('r') ?? '0') ?? 0;
        // r="-1" (repeat until the period ends) can't be expanded from
        // the manifest alone: stop here so the count and the timeline
        // stay in lockstep. The index then simply isn't emitted.
        if (repeat < 0) break;
        for (var i = 0; i <= repeat; i++) {
          durations.add(d);
        }
        count += repeat + 1;
        if (count > maxSegments) break;
      }
      if (count <= 0 || count > maxSegments) return null;
      return (
        initUrl: init,
        mediaTemplate: media,
        startNumber: start,
        segmentCount: count,
        timescale: timescale > 0 ? timescale : 1,
        durations: durations,
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
  static Future<List<int>?> fetchBytes(
    Dio dio,
    String url, {
    int timeoutSeconds = 20,
  }) async {
    try {
      final res = await dio
          .get<List<int>>(url,
              options: Options(responseType: ResponseType.bytes))
          .timeout(Duration(seconds: timeoutSeconds));
      final bytes = res.data;
      if (bytes == null || bytes.isEmpty) return null;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// Init fetch with quick retries. The init is ~1KB but gates every
  /// first byte, and mpv aborts the open after seconds of silence —
  /// so a stalled first attempt must not consume the whole budget.
  static Future<List<int>?> fetchInit(Dio dio, String url) async {
    for (final secs in [3, 3, 20]) {
      final bytes =
          await fetchBytes(dio, url, timeoutSeconds: secs);
      if (bytes != null) return bytes;
    }
    return null;
  }

  /// Parallel-batched segment fetch. [onSegment] fires per arrival
  /// (arrival order varies); [onBatch] fires after each fully-arrived
  /// batch so callers can flush contiguous prefixes. False on any miss.
  ///
  /// [from] skips already-fetched leading segments (the assembler pulls
  /// segment 0 on its own: its `tfdt` seeds the file index).
  ///
  /// [totalTimeout] bounds the whole fetch: a stalled CDN must fail
  /// fast into the caller's fallback (same-tier retry, then YouTube),
  /// never wedge the session while the player reads a partial file.
  static Future<bool> fetchSegments(
    Dio dio, {
    required String mediaTemplate,
    required int startNumber,
    required int count,
    required void Function(int index, List<int> bytes) onSegment,
    Future<void> Function(int base, int end)? onBatch,
    Duration? totalTimeout,
    int from = 0,
  }) async {
    Future<bool> run() async {
      for (var base = from; base < count; base += parallelDownloads) {
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

    if (totalTimeout == null) return run();
    try {
      return await run().timeout(totalTimeout);
    } on TimeoutException {
      return false;
    }
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
            // Age-gated: a fresh .part may be a failed-publish
            // leftover whose session just finished (or is serving
            // from it) — reaping it truncated Pillowtalk at 0:19.
            // Only previous-process orphans (stale > 1h) are reaped.
            try {
              final st = await e.stat();
              if (DateTime.now().difference(st.modified) >
                  const Duration(hours: 1)) {
                await e.delete();
              }
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