import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';

import '../../core/network/dio_factory.dart';
import 'dash_assembler.dart';

/// Loopback origin server for assembled addon audio.///
/// Two problems meet here. (1) Addon DASH manifests can never reach
/// libmpv: the bundled Windows mpv 0.36 demuxer opens the first MPD
/// per process fine, then dies opening the second (ntdll 0xc0000005).
/// (2) Assembling a full ~50MB track before first audio stalls the
/// first play for 10–30s.
///
/// So mpv opens `http://127.0.0.1:<port>/a/<name>.m4a` and this server
/// streams init + segments in arrival order (chunked) while teeing the
/// same bytes to the on-disk assembled file. First audio lands after
/// init + segment 1 (~2 RTTs); replays serve the finished file with
/// full Range support. The init segment carries `mehd`, so mpv still
/// learns the real duration immediately.
///
/// Loopback only — nothing leaves the machine, no firewall prompt.
/// Process singleton: sessions outlive any one AddonApi generation.
class LocalMediaServer {
  LocalMediaServer({Dio? dio}) : _dio = dio ?? DioFactory.create();

  static LocalMediaServer? _instance;

  static LocalMediaServer get instance => _instance ??= LocalMediaServer();

  final Dio _dio;
  HttpServer? _server;
  final Map<String, _Session> _sessions = {};

  Future<int> ensureStarted() async {
    final running = _server;
    if (running != null) return running.port;
    final bound =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    bound.listen(_route, onError: (_) {});
    _server = bound;
    return bound.port;
  }

  Future<void> close() async {
    try {
      await _server?.close(force: true);
    } catch (_) {}
    _server = null;
  }

  /// Manifest registration for streaming. Starts the background
  /// assembly immediately and returns the mpv-ready URL. Never throws
  /// (callers fall through to YouTube on null). A failed session is
  /// evicted so the next play retries fresh instead of replaying a
  /// cached transient failure for the rest of the process.
  Future<Uri?> urlFor({
    required String manifestXml,
    required String cacheName,
  }) async {
    try {
      final port = await ensureStarted();
      final safe =
          cacheName.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      if (_sessions.length > 256) _evict();
      final existing = _sessions[safe];
      if (existing != null && existing.failed) {
        _sessions.remove(safe);
        _slog('evict failed session $safe (retry will be fresh)');
      }
      final session = _sessions.putIfAbsent(
        safe,
        () => _Session(_dio, safe, manifestXml),
      );
      session.kickoff();
      return Uri.parse('http://127.0.0.1:$port/a/$safe.m4a');
    } catch (_) {
      return null;
    }
  }

  void _evict() {
    for (final key in _sessions.keys.toList()) {
      if (_sessions.length <= 192) break;
      final s = _sessions[key];
      if (s != null && (s.done || s.failed)) _sessions.remove(key);
    }
  }

  static String pathFor(String safeName, {required bool part}) =>
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'lastwave_addon${Platform.pathSeparator}assembled'
      '${Platform.pathSeparator}$safeName.${part ? 'part' : 'm4a'}';

  Future<void> _route(HttpRequest req) async {
    try {
      if (req.method != 'GET') {
        req.response.statusCode = HttpStatus.methodNotAllowed;
        await req.response.close();
        return;
      }
      final segs = req.uri.pathSegments;
      if (segs.length != 2 ||
          segs[0] != 'a' ||
          !segs[1].endsWith('.m4a')) {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      final name = segs[1].substring(0, segs[1].length - 4);
      final session = _sessions[name];
      if (session == null) {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      session.kickoff();
      await session.serve(req);
    } catch (_) {
      try {
        await req.response.close();
      } catch (_) {}
    }
  }
}

/// Names currently assembling (prune must not reap their partials).
final Set<String> _activePartials = <String>{};

/// Server breadcrumb log, shared timeline with the playback ops log
/// (`<temp>/lastwave/mpv-ops.log`). Names and shapes only — never URLs.
void _slog(String line) {
  try {
    final path =
        '${Directory.systemTemp.path}${Platform.pathSeparator}lastwave${Platform.pathSeparator}mpv-ops.log';
    File(path).writeAsStringSync(
      '${DateTime.now().toIso8601String()} addon-server $line\n',
      mode: FileMode.append,
      flush: true,
    );
  } catch (_) {}
}

class _Session {
  _Session(this._dio, this.name, String manifestXml)
      : _manifestXml = manifestXml;

  final Dio _dio;
  final String name;
  String? _manifestXml;
  bool started = false;
  bool done = false;
  bool failed = false;
  final Completer<void> _completion = Completer<void>();
  bool _firstByteLogged = false;

  /// Exact assembled size once known (init + all segment bodies).
  /// Null until the background size-discovery pass finishes; null
  /// afterwards means discovery failed and ranges must fall back to
  /// the safe complete-file wait (never serve `/*` — ffmpeg maps an
  /// unknown total to filesize -1 and the mov demuxer then fails its
  /// tail probe with "moov atom not found").
  int? _totalBytes;
  final Completer<void> _totalReady = Completer<void>();

  /// Live readers holding the partial open. The publish rename waits
  /// for zero — blind retries starve when a reader cycles ticks.
  int _openReaders = 0;

  String get _finalPath =>
      LocalMediaServer.pathFor(name, part: false);
  String get _partPath => LocalMediaServer.pathFor(name, part: true);

  void kickoff() {
    if (started) return;
    started = true;
    _activePartials.add(name);
    _slog('assemble start $name');
    // Drop an orphan partial from a previous process before any
    // reader can see it (truncate-under-reader mixes generations).
    try {
      final part = File(_partPath);
      if (part.existsSync() && !File(_finalPath).existsSync()) {
        part.deleteSync();
      }
    } catch (_) {}
    unawaited(_run());
  }

  Future<void> _run() async {
    try {
      if (File(_finalPath).existsSync() &&
          await File(_finalPath).length() > 1024) {
        // ignore: avoid_print
        print('SRV $name: cache hit');
        done = true;
        return;
      }
      final plan =
          DashAssembler.planForManifest(_manifestXml ?? '');
      _manifestXml = null;
      if (plan == null) throw StateError('unsupported manifest');
      _slog('plan $name segments=${plan.segmentCount}');
      final part = File(_partPath);
      await part.parent.create(recursive: true);
      final sink = part.openWrite(mode: FileMode.write);
      try {
        final init =
            await DashAssembler.fetchInit(_dio, plan.initUrl);
        if (init == null) throw StateError('init fetch failed');
        sink.add(init);
        await sink.flush();
        _slog('init $name ${init.length}b');
        // Size discovery races the body fetch: init (the first byte
        // mpv needs) is already on disk, and the total is usually
        // ready before mpv's first probe Range (~100ms after open).
        // Ranges arriving before it wait briefly (see _awaitTotal);
        // a failed discovery falls back to complete-file semantics.
        unawaited(_discoverTotal(plan, init.length));
        final slots =
            List<List<int>?>.filled(plan.segmentCount, null);
        // 120s overall budget (healthy assembles finish in ~3-28s):
        // a stalled CDN fails here into the same-tier retry path
        // instead of wedging the session under a reading player.
        final ok = await DashAssembler.fetchSegments(
          _dio,
          mediaTemplate: plan.mediaTemplate,
          startNumber: plan.startNumber,
          count: plan.segmentCount,
          totalTimeout: const Duration(seconds: 120),
          onSegment: (i, bytes) => slots[i] = bytes,
          onBatch: (base, end) async {
            for (var i = base; i < end; i++) {
              sink.add(slots[i]!);
            }
            await sink.flush();
          },
        );
        if (!ok) throw StateError('segment fetch failed');
      } finally {
        await sink.close();
      }
      // Atomic-ish publish: readers only trust the .m4a name.
      // Windows rename won't overwrite: clear stale output first.
      // Then wait for a reader-free moment instead of blind retries
      // (a live reader cycling ticks starves fixed-attempt loops).
      // A failed publish must stay visible: Pillowtalk truncated at
      // 0:19 because `done` was logged while only the .part existed,
      // and the .part was reaped mid-play (see prune snapshot below).
      try {
        final stale = File(_finalPath);
        if (await stale.exists()) await stale.delete();
      } catch (_) {}
      var published = false;
      for (var attempt = 0; attempt < 80; attempt++) {
        if (_openReaders == 0) {
          try {
            await File(_partPath).rename(_finalPath);
            published = true;
            break;
          } catch (_) {}
        }
        await Future.delayed(const Duration(milliseconds: 50));
      }
      done = true;
      _slog(published
          ? 'assemble done $name'
          : 'assemble done $name publish=partial');
      // Snapshot: prune is unawaited and the `finally` below removes
      // this session from the live set — passing the live set let a
      // session's own prune reap its fresh .part mid-play.
      unawaited(DashAssembler.pruneCache(Set.of(_activePartials)));
    } catch (_) {
      failed = true;
      _slog('assemble FAILED $name');
    } finally {
      _manifestXml = null;
      _activePartials.remove(name);
      if (!_completion.isCompleted) _completion.complete();
    }
  }

  /// The finished bytes: the published file, or the partial when the
  /// publish rename never landed (all bytes are there — only the name
  /// is missing). Null when neither exists.
  Future<File?> _completeFile() async {
    try {
      final f = File(_finalPath);
      if (await f.exists()) return f;
    } catch (_) {}
    try {
      final p = File(_partPath);
      if (await p.exists()) return p;
    } catch (_) {}
    return null;
  }

  Future<File?> _awaitCompleteFile() async {
    if (failed) return null;
    if (done) return _completeFile();
    try {
      await _completion.future.timeout(const Duration(seconds: 180));
    } catch (_) {
      return null;
    }
    if (!done || failed) return null;
    final f = File(_finalPath);
    if (await f.exists()) return f;
    // Publish raced (rename retries exhausted): the bytes are all in
    // the partial — serve that rather than fail the seek.
    final p = File(_partPath);
    return await p.exists() ? p : null;
  }

  Future<void> serve(HttpRequest req) async {
    final res = req.response;
    final range = req.headers.value(HttpHeaders.rangeHeader);
    if (range != null) {
      final m =
          RegExp(r'bytes=(\d+)-(\d*)$').firstMatch(range.trim());
      if (m == null) {
        res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await res.close();
        return;
      }
      final start = int.parse(m.group(1)!);
      final endStr = m.group(2)!;
      if (done) {
        // Finished assembly: instant ranges off the published file.
        await _serveRangeFromCompleteFile(
            res, start, endStr.isEmpty ? null : int.parse(endStr));
        return;
      }
      if (failed) {
        res.statusCode = HttpStatus.internalServerError;
        await res.close();
        return;
      }
      // Assembling: progressive ranges. A probe seek into already-
      // fetched bytes unblocks WITHOUT waiting for the tail, so mpv
      // starts audio while later segments still download. mpv seeks on
      // every lavf probe, and the old code awaited the complete file
      // for any Range — that single branch was the whole ~6s post-open
      // stall. Same 180s patience as before; on timeout the existing
      // 500 -> same-tier-retry path applies.
      if (endStr.isNotEmpty) {
        await _serveRangeProgressive(res, start, int.parse(endStr));
      } else {
        await _serveLive(req, startOffset: start, partial: true);
      }
      return;
    }
    // Progressive open: finished file with length when present
    // (instant duration + seeks), live chunked stream otherwise.
    if (done) {
      final file = File(_finalPath);
      if (await file.exists()) {
        res.headers.contentType = ContentType('audio', 'mp4');
        res.headers.contentLength = await file.length();
        await res.addStream(file.openRead());
        await res.close();
        return;
      }
    }
    await _serveLive(req);
  }

  /// Complete-file range serving: the pre-P2 behavior, used once the
  /// assembly is published (instant) and as the fallback when assembly
  /// finishes while a progressive range is waiting.
  Future<void> _serveRangeFromCompleteFile(
      HttpResponse res, int start, int? end) async {
    final file = await _awaitCompleteFile();
    if (file == null) {
      res.statusCode = HttpStatus.internalServerError;
      await res.close();
      return;
    }
    final length = await file.length();
    if (start >= length) {
      res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      await res.close();
      return;
    }
    var last = end ?? length - 1;
    last = min(last, length - 1);
    res.statusCode = HttpStatus.partialContent;
    res.headers.set(
        HttpHeaders.contentRangeHeader, 'bytes $start-$last/$length');
    res.headers.contentLength = last - start + 1;
    res.headers.contentType = ContentType('audio', 'mp4');
    await res.addStream(file.openRead(start, last + 1));
    await res.close();
  }

  /// Background size discovery: HEAD (fallback Range 0-0) every
  /// segment URL so progressive ranges can advertise the real total.
  /// Runs beside the body fetch; never throws. Null total afterwards
  /// means the host won't tell us sizes — callers fall back to the
  /// complete-file wait rather than serving an unknown total.
  Future<void> _discoverTotal(
    ({String initUrl, String mediaTemplate, int startNumber, int segmentCount})
        plan,
    int initLength,
  ) async {
    try {
      final sizes = List<int?>.filled(plan.segmentCount, null);
      for (var base = 0; base < plan.segmentCount; base += 12) {
        final end = (base + 12).clamp(0, plan.segmentCount);
        final batch = <Future<void>>[];
        for (var i = base; i < end; i++) {
          final index = i;
          batch.add(_probeLength(DashAssembler.segmentUrlFor(
                  plan.mediaTemplate, plan.startNumber + index))
              .then((n) => sizes[index] = n));
        }
        await Future.wait(batch);
        if (failed || done) return;
      }
      if (sizes.any((n) => n == null || n <= 0)) return;
      _totalBytes = initLength + sizes.fold<int>(0, (a, b) => a + b!);
      _slog('size $name total=$_totalBytes');
    } catch (_) {
      // Null total = fallback path; never fail the assembly for this.
    } finally {
      if (!_totalReady.isCompleted) _totalReady.complete();
    }
  }

  /// Single size probe: HEAD content-length, else the total parsed
  /// from a `bytes 0-0/TOTAL` range reply. Null on any miss. Short
  /// budget — a slow size host must not stall the body fetch.
  Future<int?> _probeLength(String url) async {
    try {
      final head = await _dio
          .head<List<int>>(url,
              options: Options(responseType: ResponseType.bytes))
          .timeout(const Duration(seconds: 5));
      final len = head.headers.value(HttpHeaders.contentLengthHeader) ??
          head.headers.value('content-length');
      final n = len == null ? null : int.tryParse(len.trim());
      if (n != null && n > 0) return n;
    } catch (_) {}
    try {
      final res = await _dio
          .get<List<int>>(url,
              options: Options(
                responseType: ResponseType.bytes,
                headers: {HttpHeaders.rangeHeader: 'bytes=0-0'},
              ))
          .timeout(const Duration(seconds: 5));
      final cr = res.headers.value(HttpHeaders.contentRangeHeader);
      if (cr != null) {
        final m = RegExp(r'/(\d+)\s*$').firstMatch(cr);
        final total = m == null ? null : int.tryParse(m.group(1)!);
        if (total != null && total > 0) return total;
      }
      // A host that ignores Range and returns 200 with the whole
      // segment: the body length IS the size (segments are ~0.5MB,
      // acceptable one-off cost on this fallback path only).
      final bytes = res.data;
      if (res.statusCode == 200 && bytes != null && bytes.isNotEmpty) {
        return bytes.length;
      }
    } catch (_) {}
    return null;
  }

  /// Real total, waiting briefly for the background discovery when an
  /// mpv probe Range beats it. Null = unknown (discovery failed or
  /// still silent after the grace) — caller must use complete-file
  /// semantics, never an unknown-total reply.
  Future<int?> _awaitTotal() async {
    if (_totalBytes != null) return _totalBytes;
    if (_totalReady.isCompleted) return _totalBytes;
    try {
      await _totalReady.future.timeout(const Duration(seconds: 15));
    } catch (_) {}
    return _totalBytes;
  }

  /// Wait until [offset]+[need] bytes are readable — from the growing
  /// partial while assembling, or the published file once done. Null on
  /// failure or after 180s without progress (same patience as the old
  /// full-file wait). A done session never waits: the caller falls back
  /// to complete-file semantics.
  Future<File?> _awaitRangeAvailable(int offset, int need) async {
    final deadline =
        DateTime.now().add(const Duration(seconds: 180));
    while (true) {
      if (failed) return null;
      if (done) {
        // Published file preferred; the partial when the rename never
        // landed (publish=partial holds every byte under the old name).
        return _completeFile();
      }
      try {
        final f = File(_partPath);
        if (await f.exists() && await f.length() >= offset + need) {
          return f;
        }
      } catch (_) {}
      if (DateTime.now().isAfter(deadline)) return null;
      await Future.delayed(const Duration(milliseconds: 50));
    }
  }

  /// Explicit range off an in-progress assembly: serve as soon as the
  /// requested bytes exist, advertising the REAL total discovered by
  /// [_discoverTotal]. Never serves `/*`: ffmpeg maps an unknown total
  /// to filesize -1 and the mov demuxer fails its tail probe with
  /// "moov atom not found" (the P2 regression). Unknown total falls
  /// back to the complete-file wait (pre-P2 safe behavior).
  Future<void> _serveRangeProgressive(
      HttpResponse res, int start, int end) async {
    if (end < start) {
      res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      await res.close();
      return;
    }
    if (done) {
      await _serveRangeFromCompleteFile(res, start, end);
      return;
    }
    final total = await _awaitTotal();
    if (total == null) {
      // Size host silent/blocked: safe stall, same as before P2.
      await _serveRangeFromCompleteFile(res, start, end);
      return;
    }
    if (start >= total) {
      res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      await res.close();
      return;
    }
    final last = min(end, total - 1);
    final file = await _awaitRangeAvailable(start, last - start + 1);
    if (file == null) {
      res.statusCode = HttpStatus.internalServerError;
      await res.close();
      return;
    }
    if (done) {
      // Assembly finished while waiting: exact complete-file semantics.
      await _serveRangeFromCompleteFile(res, start, end);
      return;
    }
    res.statusCode = HttpStatus.partialContent;
    res.headers.set(
        HttpHeaders.contentRangeHeader, 'bytes $start-$last/$total');
    res.headers.contentLength = last - start + 1;
    res.headers.contentType = ContentType('audio', 'mp4');
    await res.addStream(file.openRead(start, last + 1));
    await res.close();
  }

  Future<void> _serveLive(HttpRequest req,
      {int startOffset = 0, bool partial = false}) async {
    final res = req.response;
    res.headers.contentType = ContentType('audio', 'mp4');
    int? liveTotal;
    if (partial) {
      if (done) {
        await _serveRangeFromCompleteFile(res, startOffset, null);
        return;
      }
      // Open-ended range off a live assembly: 206 with the REAL total
      // (chunked body, no content-length — mpv reads to `total`).
      // Unknown total falls back to the complete-file wait: an `/*`
      // reply makes ffmpeg report filesize -1 and the mov probe dies
      // with "moov atom not found".
      final total = await _awaitTotal();
      if (total == null) {
        await _serveRangeFromCompleteFile(res, startOffset, null);
        return;
      }
      if (startOffset >= total) {
        res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await res.close();
        return;
      }
      liveTotal = total;
      res.statusCode = HttpStatus.partialContent;
      res.headers.set(HttpHeaders.contentRangeHeader,
          'bytes $startOffset-${total - 1}/$total');
    }
    // Chunked: no content-length, mpv plays as bytes arrive.
    // The source file is re-resolved every tick: once the producer
    // publishes, late ticks continue the SAME byte stream from the
    // finished file. Handles open only during actual I/O, counted in
    // _openReaders so the publish rename finds a reader-free moment.
    // [startOffset]/[partial] serve an open-ended range off the live
    // assembly (mpv's forward reads after a seek); plain GETs start at 0.
    // A partial stream stops at the advertised total, never past it.
    // Transient file errors are RETRIED, never fatal: the publish rename
    // can land between the existence check and the open (or an AV
    // scanner can briefly lock the partial), and closing the response
    // there truncates the stream — mpv then plays the buffered prefix
    // and dies mid-track on a torn frame with a clean-EOF status, which
    // the player mistakes for natural completion and skips ahead.
    var offset = startOffset;
    String? resolvePath() {
      try {
        final partExists = File(_partPath).existsSync();
        final finalExists = File(_finalPath).existsSync();
        // While assembling, the partial is authoritative; once done,
        // the published file — with the partial as fallback when the
        // rename never landed (publish=partial).
        if (done) return finalExists ? _finalPath : (partExists ? _partPath : null);
        return partExists ? _partPath : (finalExists ? _finalPath : null);
      } catch (_) {
        return null;
      }
    }

    while (true) {
      final path = resolvePath();
      var progressed = false;
      if (path != null) {
        RandomAccessFile? raf;
        var opened = false;
        try {
          raf = await File(path).open(mode: FileMode.read);
          opened = true;
          _openReaders++;
          try {
            var length = await raf.length();
            if (liveTotal != null && length > liveTotal) {
              length = liveTotal;
            }
            if (liveTotal != null && offset >= liveTotal) {
              try {
                await raf.close();
              } catch (_) {}
              break;
            }
            if (offset < length) {
              await raf.setPosition(offset);
              var want = length - offset;
              if (liveTotal != null) {
                want = min(want, liveTotal - offset);
              }
              final chunk = await raf.read(min(65536, want));
              offset += chunk.length;
              res.add(chunk);
              await res.flush();
              progressed = true;
              if (!_firstByteLogged) {
                _firstByteLogged = true;
                _slog('first-byte $name');
              }
            }
          } finally {
            _openReaders--;
          }
        } catch (e) {
          if (opened) {
            try {
              await raf?.close();
            } catch (_) {}
          }
          if (e is FileSystemException && !failed) {
            // Transient file race (publish rename, scanner lock):
            // wait out the producer instead of truncating the stream.
            // Client-side failures (res.add/flush) still break below.
            await Future.delayed(const Duration(milliseconds: 50));
            continue;
          }
          break;
        }
        try {
          await raf.close();
        } catch (_) {}
      }
      if (liveTotal != null && offset >= liveTotal) break;
      if (!progressed) {
        if (failed) break;
        if (done) {
          // Published (or publish failed and producer is gone):
          // one last check for the finished bytes, then stop. A
          // failed publish leaves the bytes in the .part — closing
          // here truncated Pillowtalk at 0:19.
          try {
            final f = await _completeFile();
            if (f != null) {
              final length = await f.length();
              if (offset < length) continue;
            }
          } catch (_) {}
          break;
        }
        await Future.delayed(const Duration(milliseconds: 50));
      }
    }
    try {
      await res.close();
    } catch (_) {}
  }
}
