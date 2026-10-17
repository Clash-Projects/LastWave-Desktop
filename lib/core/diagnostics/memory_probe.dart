import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Minimal JSON-RPC client for the process's own VM service.
///
/// Exists for one number the Dart side cannot read any other way: the
/// Dart heap. `RssAnon` folds the Dart heap together with every native
/// allocator (libmpv's demuxer/frame buffers, ffmpeg, glibc arenas,
/// Impeller's software surfaces), and "trim the heap" vs "stop allocating
/// frame buffers" are different fixes — so the probe asks the VM service
/// over its own localhost socket (the one `flutter run --profile` is
/// already serving) rather than guessing from the RSS curve.
///
/// Deliberately dependency-free and fail-open: any error (no service in
/// release, socket refused, method missing) marks the client [_dead],
/// after which every call returns null immediately; the probe retries
/// with a fresh client a couple of times and then prints `heap=?`.
class _VmClient {
  WebSocket? _ws;
  bool _dead = false;
  int _nextId = 0;
  final Map<int, Completer<Map<String, Object?>>> _pending = {};

  /// Once a connect or request has failed the socket is not reused; the
  /// probe swaps in a fresh client instead (a dropped connection, or the
  /// service coming up slightly after Dart `main`, is worth one retry).
  bool get dead => _dead;

  Future<Map<String, Object?>?> call(
      String method, Map<String, Object?> params) async {
    if (_dead) return null;
    final ws = await _ensure();
    if (ws == null) return null;
    final id = ++_nextId;
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    try {
      ws.add(jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }));
      return await completer.future.timeout(const Duration(seconds: 8));
    } catch (_) {
      return null;
    } finally {
      _pending.remove(id);
    }
  }

  Future<WebSocket?> _ensure() async {
    final existing = _ws;
    if (existing != null) return existing;
    try {
      final info = await dev.Service.getInfo().timeout(
            const Duration(seconds: 8),
          );
      final base = info.serverUri;
      if (base == null) {
        _dead = true;
        return null;
      }
      // http://127.0.0.1:PORT/TOKEN/ → ws://127.0.0.1:PORT/TOKEN/ws
      final wsUri = base.replace(scheme: 'ws', path: '${base.path}ws');
      final ws = await WebSocket.connect(wsUri.toString())
          .timeout(const Duration(seconds: 8));
      ws.listen(
        (data) {
          if (data is! String) return;
          try {
            final msg = jsonDecode(data);
            if (msg is! Map) return;
            final id = int.tryParse('${msg['id']}');
            if (id == null) return;
            _pending.remove(id)?.complete(msg.cast<String, Object?>());
          } catch (_) {}
        },
        onDone: () {
          _ws = null;
        },
        onError: (_) {
          _ws = null;
        },
        cancelOnError: true,
      );
      _ws = ws;
      return ws;
    } catch (_) {
      _dead = true;
      return null;
    }
  }
}

/// Sampling probe for the "RSS climbs while playing" hunt.
///
/// The total tells you nothing: Flutter's engine, two libmpv instances,
/// the decoded-image cache and the Dart heap all land in the same RSS
/// number. So services publish a one-line gauge here, and [snapshot]
/// stitches those together with the process RSS, the resident-file vs
/// resident-anonymous split, the Dart heap and Flutter's image-cache
/// occupancy. Comparing two samples minutes apart shows *which* pool grew,
/// which is the difference between "the cache filled up, as designed",
/// "mapped libraries", "the Dart heap ratcheted" and "something is
/// accumulating forever".
///
/// Cost when running: one `Timer.periodic` that reads a handful of
/// integer getters every [every], plus one localhost round trip to the VM
/// service for the heap numbers. Nothing walks the widget tree and nothing
/// allocates per frame. [start] is a no-op in release builds so the
/// shipped binary pays nothing.
class MemoryProbe {
  MemoryProbe._();

  /// name → one-line gauge. Registration is idempotent per name; the
  /// last registrant wins, which is what we want for per-instance
  /// services (a rebuilt service publishes its own counters).
  static final Map<String, String Function()> _gauges = {};

  static Timer? _timer;
  static int _baselineRss = 0;
  static String _last = '';

  /// Dart heap numbers from the VM service (see [_VmClient]). Nothing on
  /// the Dart side can read these: `RssAnon` covers the Dart heap *and*
  /// every native allocator (libmpv/ffmpeg/glibc arenas), and the fix is
  /// completely different depending on which one is growing. `heapCap`
  /// is the ratchet metric — Dart grows heap segments and only hands
  /// them back to the OS on an idle GC, so a heap that never shrinks
  /// while playing looks exactly like a leak in RSS.
  static int? _heapUsage;
  static int? _heapCapacity;
  static int? _external;
  static String? _heapError;
  static int _ticks = 0;

  /// Forced-GC delta (bytes of anon handed back by a full GC, or null
  /// when the private service method is unavailable). Non-zero means the
  /// climb is *reclaimable garbage*; zero with a big heap means the
  /// objects are live.
  static int? _gcReclaimed;

  /// Bytes of anon handed back by `malloc_trim(0)` right after that GC.
  /// This is the glibc-arena share: buffers mpv/ffmpeg/GTK freed but the
  /// allocator kept mapped because `free()` only returns the top of a
  /// heap when it exceeds `M_TRIM_THRESHOLD` (which glibc raises
  /// dynamically as large blocks are freed). Non-zero here means the
  /// native side is sitting on memory the OS could have back.
  static int? _trimReclaimed;

  static bool _gcUnavailable = false;
  static bool _trimBound = false;
  static int Function(int)? _mallocTrim;

  /// The reclaim experiment (forced GC + `malloc_trim`) is **opt-in**,
  /// because it perturbs the very curve it measures: it hands memory back
  /// on every 4th tick, which would mask a slow climb during a soak, and
  /// the forced GC can hiccup the UI isolate. Enable it when attributing
  /// a climb:
  ///
  ///     flutter run --profile --dart-define=LW_MEM_RECLAIM=1
  ///
  /// Off, the probe stays a pure reader (`heap=` still works) and
  /// `gcFreed=` / `trimFreed=` drop off the line.
  static const bool _reclaimExperiment = bool.fromEnvironment('LW_MEM_RECLAIM');

  static _VmClient _vmClient = _VmClient();
  static int _heapFails = 0;
  static bool _heapGaveUp = false;

  /// Most recent [snapshot], or '' before the first sample. Lets a UI
  /// surface (or a copied diagnostics blob) include the latest line
  /// without waiting for the next periodic print.
  static String get last => _last;

  static void register(String name, String Function() gauge) {
    _gauges[name] = gauge;
  }

  static String _mb(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(1)}M';

  /// `RssAnon` / `RssFile` out of `/proc/self/status` (kB).
  ///
  /// This is the only split the Dart side cannot see by itself: anonymous
  /// pages are heap + native allocators (Dart heap, libmpv's buffers,
  /// Impeller surfaces), file-backed pages are mapped code (libmpv,
  /// Mesa, and — because `desktop_webview_window` links it — WebKit).
  /// A climbing `file` number means "we loaded more libraries", which is
  /// a completely different fix from a climbing `anon` number.
  static ({int anon, int file})? _rssSplit() {
    if (!Platform.isLinux) return null;
    try {
      final status = File('/proc/self/status').readAsStringSync();
      int? pick(String key) {
        for (final line in status.split('\n')) {
          if (line.startsWith('$key:')) {
            final kb = int.tryParse(
                line.substring(key.length + 1).trim().split(RegExp(r'\s')).first);
            if (kb != null) return kb * 1024;
          }
        }
        return null;
      }

      final anon = pick('RssAnon');
      final file = pick('RssFile');
      if (anon == null || file == null) return null;
      return (anon: anon, file: file);
    } catch (_) {
      return null;
    }
  }

  /// Display scale. Decode buckets are DPR-aware, so on a 2× panel the
  /// same feed card decodes (and uploads to the GPU) at 4× the pixels —
  /// this is the number that turns "lots of live images" into megabytes.
  static String _viewInfo() {
    try {
      final view = PlatformDispatcher.instance.implicitView;
      if (view == null) return '';
      final size = view.physicalSize;
      return ' dpr=${view.devicePixelRatio.toStringAsFixed(2)} '
          'view=${size.width.toInt()}x${size.height.toInt()}';
    } catch (_) {
      return '';
    }
  }

  /// `heap=<live>/<capacity> ext=<dart-malloc>` — see [_heapUsage].
  static String _heapInfo() {
    if (_heapUsage == null) {
      // Release builds have no service; profile runs where the socket
      // never came up print the reason once so the blank is diagnosable.
      return _heapError == null ? ' heap=?' : ' heap=?($_heapError)';
    }
    var s = ' heap=${_mb(_heapUsage!)}/${_mb(_heapCapacity ?? 0)}'
        ' ext=${_mb(_external ?? 0)}';
    final gc = _gcReclaimed;
    if (gc != null) s += ' gcFreed=${_mb(gc)}';
    final trim = _trimReclaimed;
    if (trim != null) s += ' trimFreed=${_mb(trim)}';
    return s;
  }

  /// Bind `malloc_trim(0)` from the process's own libc. Linux-only; any
  /// failure leaves [_mallocTrim] null and the rest of the probe intact.
  static void _bindTrim() {
    if (_trimBound) return;
    _trimBound = true;
    if (!Platform.isLinux) return;
    try {
      _mallocTrim = DynamicLibrary.process()
          .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
              'malloc_trim');
    } catch (_) {
      _mallocTrim = null;
    }
  }

  /// Pull `getMemoryUsage` for this isolate over the VM service. Every
  /// failure path leaves the fields null (or, after one hard failure,
  /// gives up for the run) — the probe must never be the reason a build
  /// misbehaves.
  ///
  /// With [probeReclaim] it also runs the two-step reclaim experiment:
  /// a full GC (Dart heap), then `malloc_trim` (glibc arenas). Both are
  /// measured in anon bytes handed back, which is what separates "the
  /// climb is garbage nobody collected" from "the allocator is keeping
  /// freed pages" from "these objects are genuinely live".
  static Future<void> _refreshHeap({bool probeReclaim = false}) async {
    if (_heapGaveUp) return;
    try {
      final isolateId = dev.Service.getIsolateId(Isolate.current);
      if (isolateId == null) {
        _heapError = 'no-isolate-id';
        return;
      }
      if (_vmClient.dead) {
        if (_heapFails >= 3) {
          _heapGaveUp = true;
          _heapError = 'unavailable';
          return;
        }
        _vmClient = _VmClient();
      }
      if (probeReclaim) {
        var anon = _rssSplit()?.anon;
        if (!_gcUnavailable) {
          final ok = await _vmClient
              .call('_collectAllGarbage', {'isolateId': isolateId});
          if (ok == null) {
            // Private method not exposed (e.g. service in authenticated
            // mode). Stop asking, but keep the rest of the probe alive.
            _gcUnavailable = true;
          } else if (anon != null) {
            await Future<void>.delayed(const Duration(milliseconds: 300));
            final afterGc = _rssSplit()?.anon;
            if (afterGc != null) {
              _gcReclaimed = anon - afterGc;
              anon = afterGc;
            }
          }
        }
        _bindTrim();
        if (_mallocTrim != null && anon != null) {
          _mallocTrim!(0);
          final afterTrim = _rssSplit()?.anon;
          if (afterTrim != null) _trimReclaimed = anon - afterTrim;
        }
      }
      final res =
          await _vmClient.call('getMemoryUsage', {'isolateId': isolateId});
      final result = res?['result'];
      if (result is Map) {
        _heapUsage = _asInt(result['heapUsage']);
        _heapCapacity = _asInt(result['heapCapacity']);
        _external = _asInt(result['externalUsage']);
        _heapError = null;
        _heapFails = 0;
      } else {
        _heapFails++;
        _heapError = 'unavailable';
      }
    } catch (e) {
      _heapFails++;
      _heapError = e.runtimeType.toString();
    }
  }

  static int? _asInt(Object? v) => v is num ? v.toInt() : null;

  /// One line: RSS (+ growth since [start]) · anon/file split · Dart heap ·
  /// display · image cache · every gauge.
  static String snapshot() {
    final b = StringBuffer();
    var rss = 0;
    try {
      rss = ProcessInfo.currentRss;
    } catch (_) {}
    final cache = PaintingBinding.instance.imageCache;
    b.write('rss=${_mb(rss)} (+${_mb(rss - _baselineRss)})');
    final split = _rssSplit();
    if (split != null) {
      b.write(' anon=${_mb(split.anon)} file=${_mb(split.file)}');
    }
    b.write(_heapInfo());
    b.write(_viewInfo());
    b.write(' img[${cache.currentSize}imgs/'
        '${(cache.currentSizeBytes / (1024 * 1024)).toStringAsFixed(1)}MiB '
        'live=${cache.liveImageCount} pend=${cache.pendingImageCount}]');
    for (final e in _gauges.entries) {
      try {
        b.write(' ${e.key}[${e.value()}]');
      } catch (_) {
        b.write(' ${e.key}[!]');
      }
    }
    _last = b.toString();
    return _last;
  }

  /// Debug-only periodic printer. Safe to call twice (the timer is
  /// shared). [every] is deliberately slow — this is a leak hunt, not a
  /// frame profiler; 30s of playback is thousands of ticks.
  ///
  /// With `--dart-define=LW_MEM_RECLAIM=1` every 4th tick also runs the
  /// reclaim experiment first, reported as `gcFreed=` (bytes handed back
  /// by a forced full GC) and `trimFreed=` (bytes handed back by
  /// `malloc_trim`). That separates "the RSS climb is reclaimable garbage
  /// the GC simply hasn't been asked to collect" (the app is never idle
  /// while playing, and Dart only shrinks heap segments on an idle GC),
  /// "the allocator is holding freed native pages" and "these objects are
  /// live". It is off by default because it perturbs the measurement.
  static void start({Duration every = const Duration(seconds: 30)}) {
    if (kReleaseMode) return;
    try {
      _baselineRss = ProcessInfo.currentRss;
    } catch (_) {}
    _timer ??= Timer.periodic(every, (_) async {
      _ticks++;
      final probeReclaim = _reclaimExperiment && _ticks % 4 == 0;
      await _refreshHeap(probeReclaim: probeReclaim);
      debugPrint('[mem] ${snapshot()}');
    });
    // Printed synchronously, before anything else allocates, so the (+Δ)
    // column stays honest. The heap numbers only appear from tick 1 on —
    // reading them needs a round trip to the VM service.
    debugPrint('[mem] baseline ${snapshot()}');
    unawaited(_refreshHeap());
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
