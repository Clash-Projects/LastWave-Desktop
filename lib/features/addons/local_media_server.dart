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
        final slots =
            List<List<int>?>.filled(plan.segmentCount, null);
        final ok = await DashAssembler.fetchSegments(
          _dio,
          mediaTemplate: plan.mediaTemplate,
          startNumber: plan.startNumber,
          count: plan.segmentCount,
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
      try {
        final stale = File(_finalPath);
        if (await stale.exists()) await stale.delete();
      } catch (_) {}
      for (var attempt = 0; attempt < 40; attempt++) {
        if (_openReaders == 0) {
          try {
            await File(_partPath).rename(_finalPath);
            break;
          } catch (_) {}
        }
        await Future.delayed(const Duration(milliseconds: 50));
      }
      done = true;
      _slog('assemble done $name');
      unawaited(DashAssembler.pruneCache(_activePartials));
    } catch (_) {
      failed = true;
      _slog('assemble FAILED $name');
    } finally {
      _manifestXml = null;
      _activePartials.remove(name);
      if (!_completion.isCompleted) _completion.complete();
    }
  }

  Future<File?> _awaitCompleteFile() async {
    if (failed) return null;
    if (done) {
      final f = File(_finalPath);
      return await f.exists() ? f : null;
    }
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
      final file = await _awaitCompleteFile();
      if (file == null) {
        res.statusCode = HttpStatus.internalServerError;
        await res.close();
        return;
      }
      final length = await file.length();
      final start = int.parse(m.group(1)!);
      if (start >= length) {
        res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await res.close();
        return;
      }
      final endStr = m.group(2)!;
      var end = endStr.isEmpty ? length - 1 : int.parse(endStr);
      end = min(end, length - 1);
      res.statusCode = HttpStatus.partialContent;
      res.headers.set(
          HttpHeaders.contentRangeHeader, 'bytes $start-$end/$length');
      res.headers.contentLength = end - start + 1;
      res.headers.contentType = ContentType('audio', 'mp4');
      await res.addStream(file.openRead(start, end + 1));
      await res.close();
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

  Future<void> _serveLive(HttpRequest req) async {
    final res = req.response;
    res.headers.contentType = ContentType('audio', 'mp4');
    // Chunked: no content-length, mpv plays as bytes arrive.
    // The source file is re-resolved every tick: once the producer
    // publishes, late ticks continue the SAME byte stream from the
    // finished file. Handles open only during actual I/O, counted in
    // _openReaders so the publish rename finds a reader-free moment.
    var offset = 0;
    while (true) {
      var path = _partPath;
      if (done) {
        try {
          if (await File(_finalPath).exists()) path = _finalPath;
        } catch (_) {}
      }
      var progressed = false;
      if (await File(path).exists()) {
        RandomAccessFile? raf;
        try {
          raf = await File(path).open(mode: FileMode.read);
          _openReaders++;
          try {
            final length = await raf.length();
            if (offset < length) {
              await raf.setPosition(offset);
              final chunk =
                  await raf.read(min(65536, length - offset));
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
        } catch (_) {
          try {
            await raf?.close();
          } catch (_) {}
          break;
        }
        try {
          await raf.close();
        } catch (_) {}
      }
      if (!progressed) {
        if (failed) break;
        if (done) {
          // Published (or publish failed and producer is gone):
          // one last check for the finished file, then stop.
          try {
            final f = File(_finalPath);
            if (await f.exists()) {
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
