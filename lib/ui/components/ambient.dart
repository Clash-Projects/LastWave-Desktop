import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:palette_generator/palette_generator.dart';

import '../../core/diagnostics/memory_probe.dart';
import '../../core/storage/prefs.dart';
import '../theme/haze.dart';
import '../theme/tokens.dart';

/// Provider for visualizer toggle (persisted in preferences).
final visualizerEnabledProvider =
    StateNotifierProvider<VisualizerEnabledNotifier, bool>((ref) {
  final prefs = ref.watch(prefsProvider);
  return VisualizerEnabledNotifier(prefs);
});

class VisualizerEnabledNotifier extends StateNotifier<bool> {
  final Prefs _prefs;

  VisualizerEnabledNotifier(this._prefs) : super(_prefs.visualizerEnabled);

  void toggle() {
    state = !state;
    _prefs.setVisualizerEnabled(state);
  }

  void setEnabled(bool enabled) {
    state = enabled;
    _prefs.setVisualizerEnabled(enabled);
  }
}

/// Multi-tone palette extracted from album artwork for dynamic ambient effects.
class ArtworkPalette {
  final Color primary;
  final Color vibrant;
  final Color darkMuted;
  final Color lightVibrant;
  final Color cream;
  final Color shadow;

  const ArtworkPalette({
    required this.primary,
    required this.vibrant,
    required this.darkMuted,
    required this.lightVibrant,
    required this.cream,
    required this.shadow,
  });

  static const fallback = ArtworkPalette(
    primary: Color(0xFF8A4A28),
    vibrant: Color(0xFFC45A1A),
    darkMuted: Color(0xFF3A2418),
    lightVibrant: Color(0xFFE0A060),
    cream: Color(0xFFE8DFD0),
    shadow: Color(0xFF0C0806),
  );

  @override
  bool operator ==(Object other) =>
      other is ArtworkPalette &&
      other.primary == primary &&
      other.vibrant == vibrant &&
      other.darkMuted == darkMuted &&
      other.lightVibrant == lightVibrant &&
      other.cream == cream &&
      other.shadow == shadow;

  @override
  int get hashCode => Object.hash(
        primary,
        vibrant,
        darkMuted,
        lightVibrant,
        cream,
        shadow,
      );
}

/// How much extra scrim a palette needs (0..1): the mean luminance
/// of the light end (cream/lightVibrant — where lyrics sit). Below
/// 0.45 the base alphas suffice; at 0.8+ the stage is near-white and
/// the scrim deepens toward its maxima. Pure Dart, no image pass.
double _scrimBoost(ArtworkPalette palette) {
  final light = (palette.cream.computeLuminance() +
          palette.lightVibrant.computeLuminance()) /
      2;
  return ((light - 0.45) / 0.35).clamp(0.0, 1.0);
}

/// Directional contrast scrim shared by every ambient stage
/// (cinematic aura, solid-mode static gradient): tints the glass the
/// title, lyrics, and top bar sit on toward the theme background.
/// Alphas deepen with [boost] so light covers stay readable without
/// dulling dark ones. Must wrap both paths — solid mode skips the
/// mesh painter (and its baked-in scrim) entirely, which is why text
/// used to vanish there while automatic looked fine.
///
/// Base alphas are deliberately light: the stage is the hero artwork's
/// colour and the page reads as "too dark" when the scrim eats it. The
/// [boost] term, not the base, is what guarantees contrast on pale covers.
///
/// The gradient carries no steps — but 8-bit alpha does. The dark ramp runs
/// 0.28 → 0.54, i.e. ~66 distinct levels stretched over the window height,
/// so a contour lands every ~13px and reads as banding on a dark stage.
/// Neither Flutter nor Skia dithers gradients, so [_DitherPainter] adds the
/// noise by hand on top of it (and therefore on top of the aura as well).
class _StageScrim extends StatelessWidget {
  final bool isDark;
  final double boost;
  const _StageScrim({required this.isDark, this.boost = 0});

  @override
  Widget build(BuildContext context) {
    final b = boost.clamp(0.0, 1.0);
    final topAlpha = (isDark ? 0.28 : 0.34) + b * 0.25;
    final bottomAlpha = (isDark ? 0.54 : 0.60) + b * 0.28;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            (isDark ? Colors.black : Colors.white)
                .withValues(alpha: topAlpha),
            waveBackground(context).withValues(alpha: bottomAlpha),
          ],
        ),
      ),
      // Painted after the decoration above, so the noise dithers the scrim's
      // contours rather than being darkened by them. Still under page content.
      child: const CustomPaint(
        painter: _DitherPainter(),
        child: SizedBox.expand(),
      ),
    );
  }
}

/// Shared dithering noise: a 128x128 grayscale tile, built once per process.
///
/// Deliberately *not* baked per artwork (unlike [auraImageProvider]): the
/// pattern is unrelated to the cover, and a process-wide tile costs one 64 KiB
/// texture that is never worth freeing.
final ui.Image _ditherTile = _buildDitherTile();

ui.Image _buildDitherTile() {
  const size = 128;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final paint = Paint()..isAntiAlias = false;
  // Fixed seed: a stable pattern between runs, and stable between repaints so
  // the stage never shimmers when something above it re-rasterizes.
  final rnd = math.Random(0x5EED);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final v = rnd.nextInt(256);
      paint.color = Color.fromARGB(255, v, v, v);
      canvas.drawRect(Rect.fromLTWH(x.toDouble(), y.toDouble(), 1, 1), paint);
    }
  }
  final picture = recorder.endRecording();
  try {
    // Rasterizes asynchronously in the engine, but the handle is usable
    // immediately and this is not on a hot path.
    return picture.toImageSync(size, size);
  } finally {
    picture.dispose();
  }
}

/// Tiles [_ditherTile] over the stage at a couple of percent alpha.
///
/// An 8-bit dither only has to nudge a pixel by about one level to break a
/// contour, so this stays well below anything that reads as grain — or as haze
/// over the artwork.
class _DitherPainter extends CustomPainter {
  const _DitherPainter();

  static const double _alpha = 0.02;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final area = Offset.zero & size;
    final paint = Paint()
      ..shader = ImageShader(
        _ditherTile,
        TileMode.repeated,
        TileMode.repeated,
        Matrix4.identity().storage,
        filterQuality: FilterQuality.none,
      )
      // Alpha as a matrix, not `Paint.color`: image/shader draws are allowed
      // to ignore the paint colour (see [_AuraPainter]).
      ..colorFilter = const ColorFilter.matrix(<double>[
        1, 0, 0, 0, 0, //
        0, 1, 0, 0, 0, //
        0, 0, 1, 0, 0, //
        0, 0, 0, _alpha, 0, //
      ]);
    canvas.drawRect(area, paint);
  }

  @override
  bool shouldRepaint(covariant _DitherPainter oldDelegate) => false;
}

double _colorDistance(Color a, Color b) {
  final ah = HSLColor.fromColor(a);
  final bh = HSLColor.fromColor(b);
  var dh = (ah.hue - bh.hue).abs();
  if (dh > 180) dh = 360 - dh;
  return dh / 180 + (ah.lightness - bh.lightness).abs() * 1.4;
}

Color _nudgeColor(
  Color color, {
  double sat = 1.08,
  double minL = 0.06,
  double maxL = 0.82,
}) {
  final hsl = HSLColor.fromColor(color);
  return hsl
      .withSaturation((hsl.saturation * sat).clamp(0.08, 0.92))
      .withLightness(hsl.lightness.clamp(minL, maxL))
      .toColor();
}

/// Light, desaturated wash like the lyrics side on Apple Music / monochrome.
Color _toCream(Color color) {
  final hsl = HSLColor.fromColor(color);
  return hsl
      .withSaturation((hsl.saturation * 0.18).clamp(0.04, 0.20))
      .withLightness(0.82)
      .toColor();
}

Color _toGold(Color color) {
  final hsl = HSLColor.fromColor(color);
  return hsl
      .withHue((hsl.hue * 0.25 + 36 * 0.75) % 360)
      .withSaturation((hsl.saturation * 0.68).clamp(0.32, 0.58))
      .withLightness(hsl.lightness.clamp(0.46, 0.62))
      .toColor();
}

List<Color> _poolFrom(PaletteGenerator gen) {
  final pool = <Color>[];
  void add(Color? color) {
    if (color == null) return;
    for (final existing in pool) {
      if (_colorDistance(existing, color) < 0.08) return;
    }
    pool.add(color);
  }

  add(gen.vibrantColor?.color);
  add(gen.lightVibrantColor?.color);
  add(gen.darkVibrantColor?.color);
  add(gen.dominantColor?.color);
  add(gen.mutedColor?.color);
  add(gen.lightMutedColor?.color);
  add(gen.darkMutedColor?.color);
  for (final swatch in gen.paletteColors) {
    add(swatch.color);
  }
  return pool;
}

Color _pickDistinct(
  List<Color> pool,
  List<Color> already, {
  required Color fallback,
  double minLight = 0,
  double maxLight = 1,
  bool preferSat = false,
}) {
  Color? best;
  var bestScore = -1.0;
  for (final color in pool) {
    final hsl = HSLColor.fromColor(color);
    if (hsl.lightness < minLight || hsl.lightness > maxLight) continue;
    var nearest = 4.0;
    for (final other in already) {
      nearest = math.min(nearest, _colorDistance(color, other));
    }
    final score = nearest + (preferSat ? hsl.saturation * 0.35 : 0);
    if (score > bestScore) {
      bestScore = score;
      best = color;
    }
  }
  return best ?? fallback;
}

ArtworkPalette _paletteFromRegions({
  required PaletteGenerator full,
  PaletteGenerator? left,
  PaletteGenerator? right,
  PaletteGenerator? bottom,
}) {
  final pool = _poolFrom(full);
  final leftPool = _poolFrom(left ?? full);
  final rightPool = _poolFrom(right ?? full);
  final bottomPool = _poolFrom(bottom ?? full);
  if (pool.isEmpty) return ArtworkPalette.fallback;

  final shadow = _nudgeColor(
    _pickDistinct(
      leftPool.isEmpty ? pool : leftPool,
      const [],
      fallback: pool.first,
      maxLight: 0.34,
    ),
    sat: 0.95,
    minL: 0.04,
    maxL: 0.16,
  );
  final cream = _toCream(
    _pickDistinct(
      rightPool.isEmpty ? pool : rightPool,
      [shadow],
      fallback: pool.last,
      minLight: 0.28,
    ),
  );
  final vibrant = _nudgeColor(
    _pickDistinct(
      pool,
      [shadow, cream],
      fallback: pool.first,
      preferSat: true,
      minLight: 0.22,
      maxLight: 0.72,
    ),
    sat: 1.12,
    minL: 0.30,
    maxL: 0.58,
  );
  final primary = _nudgeColor(
    _pickDistinct(pool, [shadow, cream, vibrant], fallback: vibrant),
    sat: 0.92,
    minL: 0.18,
    maxL: 0.46,
  );
  final light = _toGold(
    _pickDistinct(
      bottomPool.isEmpty ? pool : bottomPool,
      [shadow, cream, vibrant, primary],
      fallback: vibrant,
      minLight: 0.28,
    ),
  );
  final dark = _nudgeColor(
    _pickDistinct(
      leftPool.isEmpty ? pool : leftPool,
      [shadow, cream, vibrant, primary, light],
      fallback: shadow,
      maxLight: 0.40,
    ),
    sat: 0.90,
    minL: 0.10,
    maxL: 0.30,
  );

  return ArtworkPalette(
    primary: primary,
    vibrant: vibrant,
    darkMuted: dark,
    lightVibrant: light,
    cream: cream,
    shadow: shadow,
  );
}

Future<ui.Image> _decodeArtwork(String url) {
  final provider =
      CachedNetworkImageProvider(url, maxWidth: 192, maxHeight: 192);
  final completer = Completer<ui.Image>();
  final stream = provider.resolve(const ImageConfiguration());
  late final ImageStreamListener listener;
  listener = ImageStreamListener((info, _) {
    if (!completer.isCompleted) completer.complete(info.image);
    stream.removeListener(listener);
  }, onError: (Object error, StackTrace? stack) {
    if (!completer.isCompleted) {
      completer.completeError(error, stack);
    }
    stream.removeListener(listener);
  });
  stream.addListener(listener);
  return completer.future.timeout(const Duration(seconds: 8));
}

/// Isolate job: raw RGBA bytes + dimensions. The 192px decode stays on
/// the UI thread (GPU-backed, fast); the 4× quantizer passes
/// (~200ms) run off-thread. Everything crossing the boundary is plain
/// data (bytes + ArtworkPalette of int-backed Colors).
class _PaletteJob {
  final Uint8List bytes;
  final int width;
  final int height;
  const _PaletteJob(this.bytes, this.width, this.height);
}

Future<ArtworkPalette> _extractPalette(_PaletteJob job) async {
  final encoded = EncodedImage(
    ByteData.sublistView(job.bytes),
    width: job.width,
    height: job.height,
  );
  final w = job.width.toDouble();
  final h = job.height.toDouble();
  final full = await PaletteGenerator.fromByteData(
    encoded,
    maximumColorCount: 24,
    filters: const [],
  );
  final left = await PaletteGenerator.fromByteData(
    encoded,
    region: Rect.fromLTWH(0, 0, w * 0.42, h),
    maximumColorCount: 10,
    filters: const [],
  );
  final right = await PaletteGenerator.fromByteData(
    encoded,
    region: Rect.fromLTWH(w * 0.55, 0, w * 0.45, h),
    maximumColorCount: 10,
    filters: const [],
  );
  final bottom = await PaletteGenerator.fromByteData(
    encoded,
    region: Rect.fromLTWH(0, h * 0.58, w, h * 0.42),
    maximumColorCount: 10,
    filters: const [],
  );
  return _paletteFromRegions(
    full: full,
    left: left,
    right: right,
    bottom: bottom,
  );
}

final _paletteLruCache = <String, ArtworkPalette>{};

/// Cumulative LRU misses. Diagnostic only (see [_PalettePool.debugGauge]).
int _paletteMisses = 0;

/// Cumulative extraction failures + the last error's type. Distinguishes
/// "the quantizer is broken" from "the 192px decode never arrives" —
/// both used to end in the same silent fallback.
int _paletteFailures = 0;
String _paletteLastError = '';

/// How long a resolved palette provider stays alive with no listeners.
///
/// The palette cache itself is bounded ([_paletteLruCache], 500 entries),
/// but `keepAlive()` is not: an `autoDispose` *family* keeps one element
/// per distinct artwork URL for the rest of the process, and an endless
/// radio queue mints a new URL every few minutes. Holding the element
/// until the LRU needs the slot is the intent; holding it forever is a
/// slow leak. So the link is released on a timer — long enough that
/// navigating back to a page re-reads the cached palette instead of
/// re-extracting it, short enough that a long session's element count
/// stays proportional to what's on screen.
const _paletteKeepAlive = Duration(minutes: 5);

void _keepPaletteAlive(Ref ref) {
  final link = ref.keepAlive();
  final timer = Timer(_paletteKeepAlive, link.close);
  ref.onDispose(timer.cancel);
}

// ── Palette worker pool ───────────────────────────────────────────────
//
// Extraction used to go through `compute()`, which spawns AND tears down a
// fresh isolate per call. A cold Home requests a palette for every shelf
// card at once (`artworkSeedProvider` watchers in `shelf.dart`, one per
// card), so a first paint spawned dozens of short-lived isolates — an RSS
// spike plus a spawn/teardown per card. A small warm pool keeps
// [_PalettePool._maxWorkers] isolates alive for the life of the process
// and caps concurrency, so a cold page costs zero spawns after the first.

class _PaletteRequest {
  final int id;
  final Uint8List bytes;
  final int width;
  final int height;
  const _PaletteRequest(this.id, this.bytes, this.width, this.height);
}

class _PaletteReply {
  final int id;
  final ArtworkPalette? palette;
  final String? error;
  const _PaletteReply(this.id, {this.palette, this.error});
}

/// Worker entry point — one long-lived isolate per pool slot.
void _paletteWorkerMain(SendPort reply) {
  final inbox = ReceivePort();
  reply.send(inbox.sendPort);
  inbox.listen((Object? message) async {
    if (message is! _PaletteRequest) return;
    try {
      final palette = await _extractPalette(
        _PaletteJob(message.bytes, message.width, message.height),
      );
      reply.send(_PaletteReply(message.id, palette: palette));
    } catch (e) {
      reply.send(_PaletteReply(message.id, error: e.toString()));
    }
  });
}

/// One warm isolate. Self-healing: if the isolate dies or a job wedges,
/// the affected job falls back to the one-shot `compute()` path and the
/// slot respawns on the next request — a broken worker can never take the
/// ambient stage (or the caller) down with it.
class _PaletteWorker {
  static const Duration _jobTimeout = Duration(seconds: 20);
  static const Duration _handshakeTimeout = Duration(seconds: 10);

  /// Times a job had to fall back to the one-shot `compute()` path, i.e.
  /// the warm isolate was unusable. This is the number that must stay 0:
  /// every count here is an extra isolate spawn **per palette request**.
  static int _fallbacks = 0;

  Isolate? _isolate;
  ReceivePort? _replies;
  SendPort? _send;
  Future<void>? _starting;
  Completer<SendPort>? _handshake;
  int _nextId = 0;
  final Map<int, Completer<ArtworkPalette>> _pending = {};

  Future<ArtworkPalette> extract(_PaletteJob job) async {
    try {
      final send = await _sendPort();
      final id = _nextId++;
      final completer = Completer<ArtworkPalette>();
      _pending[id] = completer;
      send.send(_PaletteRequest(id, job.bytes, job.width, job.height));
      return await completer.future.timeout(_jobTimeout);
    } catch (_) {
      _teardown(killIsolate: true);
      _fallbacks++;
      return compute(_extractPalette, job);
    }
  }

  Future<SendPort> _sendPort() async {
    final ready = _send;
    if (ready != null) return ready;
    final start = _starting ??= _start();
    try {
      await start;
    } finally {
      _starting = null;
    }
    final send = _send;
    if (send == null) throw StateError('palette worker unavailable');
    return send;
  }

  Future<void> _start() async {
    final replies = ReceivePort();
    final handshake = Completer<SendPort>();
    // Pre-attach a handler: a teardown landing before `_start` reaches the
    // await below would otherwise report as an unhandled completer error.
    unawaited(handshake.future.then((_) {}, onError: (Object _) {}));
    _replies = replies;
    _handshake = handshake;
    replies.listen(
      (Object? message) {
        if (message is SendPort) {
          if (!handshake.isCompleted) handshake.complete(message);
          return;
        }
        if (message is! _PaletteReply) return;
        final completer = _pending.remove(message.id);
        if (completer == null || completer.isCompleted) return;
        final palette = message.palette;
        if (palette != null) {
          completer.complete(palette);
        } else {
          completer.completeError(
              StateError(message.error ?? 'palette worker failed'));
        }
      },
      onDone: () => _teardown(),
      onError: (Object _) => _teardown(),
      cancelOnError: true,
    );
    try {
      _isolate = await Isolate.spawn(
        _paletteWorkerMain,
        replies.sendPort,
        debugName: 'lastwave-palette',
        errorsAreFatal: false,
      );
      // The worker's first message is its own SendPort. THIS assignment is
      // what makes the worker usable: `_sendPort()` reads `_send`, so
      // without it every request threw 'palette worker unavailable' and
      // fell through to the one-shot `compute()` path — spawning a second
      // isolate per palette (and killing this one) forever. The pool was
      // warm in name only; the churn it exists to remove was still there.
      _send = await handshake.future.timeout(_handshakeTimeout);
    } catch (_) {
      _teardown(killIsolate: true);
      rethrow;
    }
  }

  /// Drops this slot's state, failing anything still in flight so callers
  /// fall back to `compute()` instead of hanging.
  void _teardown({bool killIsolate = false}) {
    if (killIsolate) {
      try {
        _isolate?.kill(priority: Isolate.immediate);
      } catch (_) {}
    }
    _isolate = null;
    _send = null;
    _starting = null;
    final handshake = _handshake;
    _handshake = null;
    if (handshake != null && !handshake.isCompleted) {
      handshake.completeError(StateError('palette worker stopped'));
    }
    final replies = _replies;
    _replies = null;
    if (replies != null) {
      try {
        replies.close();
      } catch (_) {}
    }
    if (_pending.isNotEmpty) {
      final stalled = _pending.values.toList(growable: false);
      _pending.clear();
      for (final completer in stalled) {
        if (!completer.isCompleted) {
          completer.completeError(StateError('palette worker stopped'));
        }
      }
    }
  }
}

class _PaletteTask {
  final _PaletteJob job;
  final Completer<ArtworkPalette> completer = Completer<ArtworkPalette>();
  _PaletteTask(this.job);
}

/// Fixed-size pool over [_PaletteWorker]s with a FIFO queue.
class _PalettePool {
  static const int _maxWorkers = 4;

  _PalettePool() {
    MemoryProbe.register('palette', () => debugGauge);
  }

  /// `misses` is cumulative and only rises on an LRU miss, so a curve
  /// that tracks RSS growth means per-artwork retention (elements or
  /// decoded pixels), not the pool. `spawns` counts how many times a
  /// worker had to fall back to the one-shot `compute()` path — it must
  /// stay at 0 once a worker is warm.
  String get debugGauge => 'lru=${_paletteLruCache.length} '
      'misses=$_paletteMisses failed=$_paletteFailures '
      'err=${_paletteLastError.isEmpty ? '-' : _paletteLastError} '
      'workers=${_workers.length} spawns=${_PaletteWorker._fallbacks} '
      'queued=${_queue.length} running=$_running';

  final List<_PaletteWorker> _workers = [];
  final List<_PaletteTask> _queue = [];
  int _running = 0;
  int _cursor = 0;

  Future<ArtworkPalette> extract(_PaletteJob job) {
    final task = _PaletteTask(job);
    _queue.add(task);
    _pump();
    return task.completer.future;
  }

  void _pump() {
    while (_running < _maxWorkers && _queue.isNotEmpty) {
      final task = _queue.removeAt(0);
      while (_workers.length < _maxWorkers) {
        _workers.add(_PaletteWorker());
      }
      // Round-robin keeps one job in flight per worker while `_running`
      // is capped, so the pool never oversubscribes an isolate.
      final worker = _workers[_cursor++ % _maxWorkers];
      _running++;
      worker.extract(task.job).then(
        task.completer.complete,
        onError: (Object error, StackTrace stack) {
          if (!task.completer.isCompleted) {
            task.completer.completeError(error, stack);
          }
        },
      ).whenComplete(() {
        _running--;
        _pump();
      });
    }
  }
}

final _palettePool = _PalettePool();

/// Test seam: drives the real pool with synthetic RGBA so the warm-isolate
/// path is exercised end to end (see `test/palette_pool_test.dart`).
@visibleForTesting
Future<ArtworkPalette> extractPaletteForTest(
        List<int> rgba, int width, int height) =>
    _palettePool
        .extract(_PaletteJob(Uint8List.fromList(rgba), width, height));

/// Test seam: `compute()` fallbacks so far. Must stay 0 — every count is
/// an extra isolate spawned *and killed* per palette request.
@visibleForTesting
int get palettePoolFallbacks => _PaletteWorker._fallbacks;

/// Shared artwork-derived multi-color palette, cached by image identity with LRU retention.
final artworkPaletteProvider =
    FutureProvider.autoDispose.family<ArtworkPalette, String>((ref, url) async {
  if (url.isEmpty) return ArtworkPalette.fallback;
  final cached = _paletteLruCache[url];
  if (cached != null) return cached;
  _paletteMisses++;
  _keepPaletteAlive(ref);
  ui.Image? image;
  try {
    image = await _decodeArtwork(url);
    final bytes = await image.toByteData();
    if (bytes == null) return ArtworkPalette.fallback;
    final job = _PaletteJob(
      bytes.buffer.asUint8List(
          bytes.offsetInBytes, bytes.lengthInBytes),
      image.width,
      image.height,
    );
    image.dispose();
    image = null;
    final palette = await _palettePool.extract(job);
    if (_paletteLruCache.length >= 500) {
      _paletteLruCache.remove(_paletteLruCache.keys.first);
    }
    _paletteLruCache[url] = palette;
    return palette;
  } catch (e) {
    // Type only — CachedNetworkImageProvider errors embed the URL and the
    // residency log must never carry one.
    _paletteFailures++;
    _paletteLastError = e.runtimeType.toString();
    return ArtworkPalette.fallback;
  } finally {
    image?.dispose();
  }
});

/// Shared artwork-derived ambient primary color, cached by image identity.
final artworkSeedProvider =
    FutureProvider.autoDispose.family<Color, String>((ref, url) async {
  if (url.isEmpty) return const Color(0xFF232838);
  _keepPaletteAlive(ref);
  final pal = await ref.watch(artworkPaletteProvider(url).future);
  return pal.primary;
});

/// Pre-blurred, small aura texture. Blur is baked once per artwork URL;
/// the ambient stage paints it statically (no rotation, no vsync ticks).
final auraImageProvider =
    FutureProvider.autoDispose.family<ui.Image, String>((ref, url) async {
  if (url.isEmpty) throw StateError('empty artwork');
  final src = await _decodeArtwork(url);
  const out = 256;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final paint = Paint()
    ..filterQuality = FilterQuality.low
    ..colorFilter = const ColorFilter.matrix(<double>[
      1.467, -0.288, -0.029, 0, 0,
      -0.086, 1.265, -0.029, 0, 0,
      -0.086, -0.288, 1.523, 0, 0,
      0, 0, 0, 1, 0,
    ])
    ..imageFilter = ui.ImageFilter.blur(
      sigmaX: 22,
      sigmaY: 22,
      tileMode: TileMode.mirror,
    );
  canvas.drawImageRect(
    src,
    Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
    const Rect.fromLTWH(0, 0, 256, 256),
    paint,
  );
  src.dispose();
  final picture = recorder.endRecording();
  try {
    final baked = await picture.toImage(out, out);
    ref.onDispose(baked.dispose);
    return baked;
  } finally {
    picture.dispose();
  }
});

/// Static ambient background (no animation).
///
/// Fully static by design: no AnimationControllers, no tickers, no
/// AnimatedBuilder, no per-frame CustomPaint repaints. Each stage paints
/// exactly once per (artworkUrl, palette, theme) change, so RSS stays flat
/// after first paint. The [cinematic] flag selects the static baked-aura
/// stage vs the static palette-orb stage; both are still images.
class WaveAmbientMesh extends ConsumerWidget {
  final String artworkUrl;
  final bool isFullBleed;
  final double height;
  final double opacity;
  final bool cinematic;

  const WaveAmbientMesh({
    super.key,
    required this.artworkUrl,
    this.isFullBleed = true,
    this.height = 360,
    this.opacity = 1.0,
    this.cinematic = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reduceTransparency =
        MediaQuery.maybeOf(context)?.highContrast ?? false;
    final blurEnabled = WaveHazeScope.blurEnabled(context);

    final paletteAsync = ref.watch(artworkPaletteProvider(artworkUrl));
    final palette = paletteAsync.valueOrNull ?? ArtworkPalette.fallback;

    final isDark = waveIsDark(context);
    final darkBase = waveBackground(context);
    final visualizerEnabled = ref.watch(visualizerEnabledProvider);

    // Toggle is a hard show/hide: no fade animation, no retained layers.
    if (!visualizerEnabled) return const SizedBox.shrink();

    if (reduceTransparency || !blurEnabled) {
      // Solid / high-contrast path: the static palette gradient gets
      // the same contrast scrim as the cinematic aura. Without it a
      // light cover parks cream/lightVibrant under white theme text
      // (Now Playing lyrics) with nothing to read against — the reason
      // solid mode looked "broken" next to automatic.
      return IgnorePointer(
        child: Opacity(
          opacity: opacity,
          child: Stack(
            children: [
              Container(
                height: isFullBleed ? null : height,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      palette.shadow,
                      palette.darkMuted,
                      palette.cream,
                      palette.lightVibrant,
                    ],
                    stops: const [0.0, 0.28, 0.68, 1.0],
                  ),
                ),
              ),
              Positioned.fill(
                child: _StageScrim(
                  isDark: isDark,
                  boost: _scrimBoost(palette),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final Widget content;
    if (cinematic && artworkUrl.isNotEmpty) {
      content = Stack(
        children: [
          _AppleArtworkAura(artworkUrl: artworkUrl),
          // Contrast guarantee (shared _StageScrim): the aura
          // paints the cover's real colors at high opacity, so a
          // light cover yields a light stage and theme text
          // vanishes — same role as the scrim baked into the
          // non-cinematic mesh painter.
          Positioned.fill(
            child: IgnorePointer(
              child: _StageScrim(
                isDark: isDark,
                boost: _scrimBoost(palette),
              ),
            ),
          ),
        ],
      );
    } else {
      content = CustomPaint(
        isComplex: false,
        willChange: false,
        size: isFullBleed
            ? Size.infinite
            : Size(double.infinity, height),
        painter: _AmbientMeshPainter(
          palette: palette,
          isDark: isDark,
          darkBase: darkBase,
          opacity: opacity,
        ),
      );
    }

    return IgnorePointer(
      child: Opacity(
        opacity: opacity,
        child: isFullBleed
            ? SizedBox.expand(child: content)
            : SizedBox(
                width: double.infinity,
                height: height,
                child: content,
              ),
      ),
    );
  }
}

/// Apple Music / monochrome artwork aura: a baked blur texture painted
/// once, statically. No rotation, no shader, no vsync ticks.
class _AppleArtworkAura extends ConsumerWidget {
  final String artworkUrl;

  const _AppleArtworkAura({required this.artworkUrl});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncImg = ref.watch(auraImageProvider(artworkUrl));
    return asyncImg.when(
      loading: () => const ColoredBox(color: Color(0xFF0B0D11)),
      error: (_, _) => const ColoredBox(color: Color(0xFF0B0D11)),
      data: (image) => _AuraLayers(image: image),
    );
  }
}

/// Static aura layer.
///
/// Paints the baked texture at half resolution and lets [FittedBox] upscale
/// it: the aura is a blur wash, so painting at 0.5x is visually identical
/// while the cached layer holds a quarter of the pixels. Full-window retained
/// layers are the dominant RSS cost on Windows ANGLE.
///
/// Deliberately a plain image draw, not an `ImageShader` with a tile mode:
/// the shader (plus the `ImageShader` object it had to keep alive per size)
/// was the most expensive sampling path in the stage, so any future animation
/// that lands a transform on this subtree paid for it per frame. A single
/// `drawImageRect` of an already-blurred texture is the cheap path, and the
/// 2.3x zoom is just a smaller source rect (see [_AuraPainter]).
class _AuraLayers extends StatelessWidget {
  final ui.Image image;

  const _AuraLayers({required this.image});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (!size.isFinite || size.isEmpty) {
          return const SizedBox.expand();
        }
        final half = Size(size.width / 2, size.height / 2);
        return SizedBox.expand(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox.fromSize(
              size: half,
              child: RepaintBoundary(
                child: CustomPaint(
                  isComplex: false,
                  willChange: false,
                  painter: _AuraPainter(image: image, canvasSize: half),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _AuraPainter extends CustomPainter {
  final ui.Image image;
  final Size canvasSize;

  _AuraPainter({
    required this.image,
    required this.canvasSize,
  });

  /// Cover zoom: a tight crop reads as an abstract colour wash instead of a
  /// second copy of the sleeve, and keeps bright covers from blowing the
  /// stage out.
  static const double _zoom = 2.3;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final imageW = image.width.toDouble();
    final imageH = image.height.toDouble();
    if (imageW <= 0 || imageH <= 0) return;

    // Same framing the old shader sampled: cover-fit, zoomed [_zoom]x, starting
    // at the cover's centre and running toward its bottom-right corner.
    final pxPerImagePx = math.max(size.width, size.height) / imageW * _zoom;
    final src = Rect.fromLTWH(
      imageW / 2,
      imageH / 2,
      size.width / pxPerImagePx,
      size.height / pxPerImagePx,
    ).intersect(Rect.fromLTWH(0, 0, imageW, imageH));
    if (src.isEmpty) return;

    final paint = Paint()
      ..isAntiAlias = false
      ..filterQuality = FilterQuality.low
      // Wash, not wallpaper: this is the stage's colour, so it has to read as
      // the cover's palette without turning into a second copy of the sleeve.
      // 0.40 under the scrim photographed as "too dark"; 0.70 blew bright
      // covers out into an overexposed double image.
      //
      // Opacity as an alpha matrix rather than `Paint.color`: image draws are
      // allowed to ignore the paint colour (Impeller does), and this has to
      // look identical on both backends.
      ..colorFilter = const ColorFilter.matrix(<double>[
        1, 0, 0, 0, 0, //
        0, 1, 0, 0, 0, //
        0, 0, 1, 0, 0, //
        0, 0, 0, 0.52, 0, //
      ]);
    canvas.drawImageRect(image, src, Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(covariant _AuraPainter old) {
    return old.image != image || old.canvasSize != canvasSize;
  }
}

class _AmbientMeshPainter extends CustomPainter {
  final ArtworkPalette palette;
  final bool isDark;
  final Color darkBase;
  final double opacity;

  _AmbientMeshPainter({
    required this.palette,
    required this.isDark,
    required this.darkBase,
    required this.opacity,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final rect = Offset.zero & size;
    final maxDim = math.max(size.width, size.height);
    final alphaScale = (isDark ? 0.38 : 0.22) * opacity;

    void paintOrb({
      required Offset center,
      required Color color,
      required double radius,
      required double strength,
    }) {
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [
            color.withValues(alpha: (alphaScale * strength).clamp(0.0, 1.0)),
            color.withValues(
                alpha: (alphaScale * strength * 0.48).clamp(0.0, 1.0)),
            color.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.46, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: radius));
      canvas.drawRect(rect, paint);
    }

    // Fixed orb layout: identical composition to the old animated stage
    // at phase zero, painted once instead of 30×/sec.
    paintOrb(
      center: Offset(size.width * 0.24, size.height * 0.22),
      color: palette.primary,
      radius: maxDim * 0.65,
      strength: 1.1,
    );
    paintOrb(
      center: Offset(size.width * 0.80, size.height * 0.32),
      color: palette.vibrant,
      radius: maxDim * 0.60,
      strength: 0.95,
    );
    paintOrb(
      center: Offset(size.width * 0.28, size.height * 0.80),
      color: palette.lightVibrant,
      radius: maxDim * 0.58,
      strength: 0.85,
    );
    paintOrb(
      center: Offset(size.width * 0.76, size.height * 0.74),
      color: palette.darkMuted,
      radius: maxDim * 0.70,
      strength: 0.80,
    );

    final scrimPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          (isDark ? Colors.black : Colors.white)
              .withValues(alpha: isDark ? 0.35 : 0.40),
          darkBase.withValues(alpha: isDark ? 0.55 : 0.60),
        ],
      ).createShader(rect);
    canvas.drawRect(rect, scrimPaint);
  }

  @override
  bool shouldRepaint(covariant _AmbientMeshPainter old) {
    return old.palette != palette ||
        old.isDark != isDark ||
        old.darkBase != darkBase ||
        old.opacity != opacity;
  }
}

/// Artwork-tinted band behind an editorial header ([child] keeps its own
/// layout and paints on top).
///
/// Deliberately the static [AmbientWash], not the mesh: a header band has
/// to be there whatever the haze/visualizer settings say
/// ([WaveAmbientMesh] renders nothing when they are off), and its palette
/// radial fades to zero so title and meta keep their contrast on any
/// cover without a scrim.
class WaveAmbientBand extends StatelessWidget {
  final String artworkUrl;
  final Widget child;

  /// Forwarded to [AmbientWash] — raise it if the band still reads faint.
  final double strength;
  const WaveAmbientBand({
    super.key,
    required this.artworkUrl,
    required this.child,
    this.strength = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    if (artworkUrl.isEmpty) return child;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: AmbientWash(
            artworkUrl: artworkUrl,
            dynamicMesh: false,
            height: 320,
            strength: strength,
          ),
        ),
        child,
      ],
    );
  }
}

/// Artwork-derived ambient wash for editorial headers and containers.
class AmbientWash extends StatelessWidget {
  final String artworkUrl;
  final double height;
  final bool dynamicMesh;

  /// Multiplies the static gradient's alphas (the mesh has its own
  /// opacity). 1.0 is the tuned header default: plainly visible as a lit
  /// surface, still faint enough that title/meta hold their contrast
  /// without a scrim.
  final double strength;

  const AmbientWash({
    super.key,
    required this.artworkUrl,
    this.height = 320,
    this.dynamicMesh = true,
    this.strength = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    if (dynamicMesh) {
      return WaveAmbientMesh(
        artworkUrl: artworkUrl,
        isFullBleed: false,
        height: height,
        opacity: 0.9,
      );
    }

    final dark = Theme.of(context).brightness == Brightness.dark;
    final reduceT = MediaQuery.maybeOf(context)?.highContrast ?? false;
    if (reduceT) return const SizedBox.shrink();

    return Consumer(
      builder: (context, ref, _) {
        // Palette, not the single seed: one flat colour at low alpha is
        // what made an earlier header band invisible against #0E0E0E. Two
        // stops off the artwork's own vivid/primary read as light on the
        // surface. Null until the palette answers, so nothing is painted
        // in a wrong colour — the band simply fades up.
        final palette =
            ref.watch(artworkPaletteProvider(artworkUrl)).valueOrNull;
        final lead = dark
            ? (palette?.vibrant ?? ArtworkPalette.fallback.vibrant)
            : (palette?.lightVibrant ?? ArtworkPalette.fallback.lightVibrant);
        final tail = dark
            ? (palette?.primary ?? ArtworkPalette.fallback.primary)
            : (palette?.cream ?? ArtworkPalette.fallback.cream);
        final a = ((dark ? 0.44 : 0.32) * strength).clamp(0.0, 0.92);

        return IgnorePointer(
          child: AnimatedOpacity(
            opacity: palette == null ? 0 : 1,
            duration: waveMotion(context, WaveMotion.slow),
            curve: WaveMotion.standard,
            child: Container(
              height: height,
              decoration: BoxDecoration(
                // Vertical fade, not a radial: a glow anchored above the
                // box always has non-zero alpha where the header's top edge
                // cuts the box, and that straight line of colour reads as
                // the artwork being clipped. This is transparent at the top
                // and at the foot, so the band has no edge at all — it just
                // lifts the header's own surface.
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    tail.withValues(alpha: 0.0),
                    lead.withValues(alpha: a * 0.5),
                    lead.withValues(alpha: a),
                    tail.withValues(alpha: a * 0.28),
                    tail.withValues(alpha: 0.0),
                  ],
                  stops: const [0.0, 0.24, 0.5, 0.8, 1.0],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
