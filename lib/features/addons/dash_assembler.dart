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

  /// Segment fetch parallelism. A sliding window of 6 workers keeps the
  /// link continuously busy without batch-tail idle gaps or CDN rate-limit
  /// spikes when prefetch runs concurrently.
  static const int parallelDownloads = 6;

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

  /// Single fetch (init segment, remote manifest, media segment) with
  /// automatic retries on transient CDN errors/timeouts. Null on persistent miss.
  static Future<List<int>?> fetchBytes(
    Dio dio,
    String url, {
    int timeoutSeconds = 20,
    int retries = 2,
  }) async {
    for (var attempt = 0; attempt <= retries; attempt++) {
      try {
        final res = await dio
            .get<List<int>>(url,
                options: Options(responseType: ResponseType.bytes))
            .timeout(Duration(seconds: timeoutSeconds));
        final bytes = res.data;
        if (bytes != null && bytes.isNotEmpty) return bytes;
      } catch (_) {}
      if (attempt < retries) {
        await Future<void>.delayed(
            Duration(milliseconds: 150 * (attempt + 1)));
      }
    }
    return null;
  }

  /// Single HTTP byte-range fetch with automatic retries. Null on persistent miss.
  static Future<List<int>?> fetchRangeBytes(
    Dio dio,
    String url, {
    required int start,
    required int end,
    int timeoutSeconds = 20,
    int retries = 2,
  }) async {
    for (var attempt = 0; attempt <= retries; attempt++) {
      try {
        final res = await dio
            .get<List<int>>(
              url,
              options: Options(
                responseType: ResponseType.bytes,
                headers: {'Range': 'bytes=$start-$end'},
              ),
            )
            .timeout(Duration(seconds: timeoutSeconds));
        final bytes = res.data;
        if (bytes != null && bytes.isNotEmpty) return bytes;
      } catch (_) {
        if (attempt == retries) return null;
        await Future.delayed(Duration(milliseconds: 100 * (attempt + 1)));
      }
    }
    return null;
  }

  /// Init range fetch with quick retries.
  static Future<List<int>?> fetchInitRange(
    Dio dio,
    String url, {
    required int start,
    required int end,
  }) async {
    for (final secs in [3, 3, 20]) {
      final bytes = await fetchRangeBytes(
        dio,
        url,
        start: start,
        end: end,
        timeoutSeconds: secs,
      );
      if (bytes != null) return bytes;
    }
    return null;
  }

  /// Init fetch with quick retries. The init is ~1KB but gates every
  /// first byte, and mpv aborts the open after seconds of silence —
  /// so a stalled first attempt must not consume the whole budget.
  static Future<List<int>?> fetchInit(Dio dio, String url) async {
    for (final secs in [3, 3, 20]) {
      final bytes =
          await fetchBytes(dio, url, timeoutSeconds: secs, retries: 0);
      if (bytes != null) return bytes;
    }
    return null;
  }

  /// Sliding-window parallel segment fetch with progressive contiguous
  /// flushing. [onSegment] fires per arrival; [onBatch] fires as soon as
  /// the next contiguous prefix is ready so playback never stalls behind a
  /// single slow segment in a fixed batch. False on any persistent miss.
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
    return _fetchWindowed(
      count: count,
      from: from,
      totalTimeout: totalTimeout,
      fetchOne: (index) => fetchBytes(
        dio,
        segmentUrlFor(mediaTemplate, startNumber + index),
      ),
      onSegment: onSegment,
      onBatch: onBatch,
    );
  }

  /// Sliding-window parallel segment fetch for hybrid byte ranges.
  static Future<bool> fetchHybridSegments(
    Dio dio, {
    required String cdnUrl,
    required List<({int start, int end})> ranges,
    required void Function(int index, List<int> bytes) onSegment,
    Future<void> Function(int base, int end)? onBatch,
    Duration? totalTimeout,
    int from = 0,
  }) async {
    return _fetchWindowed(
      count: ranges.length,
      from: from,
      totalTimeout: totalTimeout,
      fetchOne: (index) => fetchRangeBytes(
        dio,
        cdnUrl,
        start: ranges[index].start,
        end: ranges[index].end,
      ),
      onSegment: onSegment,
      onBatch: onBatch,
    );
  }

  static Future<bool> _fetchWindowed({
    required int count,
    required int from,
    required Duration? totalTimeout,
    required Future<List<int>?> Function(int index) fetchOne,
    required void Function(int index, List<int> bytes) onSegment,
    Future<void> Function(int base, int end)? onBatch,
  }) async {
    if (from >= count) return true;
    var aborted = false;

    Future<bool> run() async {
      const maxWindow = parallelDownloads * 2;
      var nextToFetch = from;
      var nextToFlush = from;
      final ready = List<bool>.filled(count, false);
      Future<void> flushChain = Future<void>.value();

      void scheduleFlush() {
        if (onBatch == null || aborted) return;
        final start = nextToFlush;
        while (nextToFlush < count && ready[nextToFlush]) {
          nextToFlush++;
        }
        final end = nextToFlush;
        if (end > start) {
          flushChain = flushChain.then((_) async {
            if (aborted) return;
            try {
              await onBatch(start, end);
            } catch (_) {
              aborted = true;
              rethrow;
            }
          });
        }
      }

      Future<void> worker() async {
        while (!aborted) {
          if (onBatch != null && nextToFetch - nextToFlush >= maxWindow) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            continue;
          }
          final index = nextToFetch;
          if (index >= count) break;
          nextToFetch++;
          final bytes = await fetchOne(index);
          if (aborted) return;
          if (bytes == null) {
            aborted = true;
            return;
          }
          onSegment(index, bytes);
          ready[index] = true;
          scheduleFlush();
        }
      }

      final workerCount =
          (count - from) < parallelDownloads ? (count - from) : parallelDownloads;
      await Future.wait(List.generate(workerCount, (_) => worker()));
      await flushChain;
      return !aborted;
    }

    if (totalTimeout == null) return run();
    try {
      return await run().timeout(totalTimeout);
    } on TimeoutException {
      aborted = true;
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