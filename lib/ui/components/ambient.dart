import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
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

/// Now Playing ambient style. See [Prefs.ambientStyle].
enum AmbientStyle {
  apple('apple', 'Apple Music'),
  winui('winui', 'WinUI');

  final String id;
  final String label;
  const AmbientStyle(this.id, this.label);

  static AmbientStyle fromId(String id) =>
      id == winui.id ? winui : apple;
}

final ambientStyleProvider =
    StateNotifierProvider<AmbientStyleNotifier, AmbientStyle>((ref) {
  return AmbientStyleNotifier(ref.watch(prefsProvider));
});

class AmbientStyleNotifier extends StateNotifier<AmbientStyle> {
  final Prefs _prefs;
  AmbientStyleNotifier(this._prefs)
      : super(AmbientStyle.fromId(_prefs.ambientStyle));

  void set(AmbientStyle style) {
    state = style;
    _prefs.setAmbientStyle(style.id);
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
    final topAlpha = (isDark ? 0.06 : 0.16) + b * 0.28;
    final bottomAlpha = (isDark ? 0.34 : 0.40) + b * 0.30;
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

/// Scrim for the Apple Music stage: always black, never the theme
/// background, so the stage looks the same in Midnight, Pearl, AMOLED and
/// Custom and always carries white text. Light at the top so the colours
/// stay vivid, deeper toward the bottom (controls, dock). [boost] adds
/// depth for pale covers, as in [_StageScrim].
class _AppleScrim extends StatelessWidget {
  final double boost;
  const _AppleScrim({this.boost = 0});

  @override
  Widget build(BuildContext context) {
    final b = boost.clamp(0.0, 1.0);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0.06 + b * 0.30),
            Colors.black.withValues(alpha: 0.22 + b * 0.32),
          ],
        ),
      ),
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
    final score = nearest + (preferSat ? hsl.saturation * 0.65 : 0);
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
  if (pool.isEmpty &&
      leftPool.isEmpty &&
      rightPool.isEmpty &&
      bottomPool.isEmpty) {
    return ArtworkPalette.fallback;
  }

  // Merge regional pools with the full cover pool so small regional accents
  // (e.g. a bright label or corner tape on an otherwise monochrome cover)
  // are available when picking vibrant and primary hues.
  final allPool = <Color>[...pool];
  for (final regional in [leftPool, rightPool, bottomPool]) {
    for (final c in regional) {
      var duplicate = false;
      for (final existing in allPool) {
        if (_colorDistance(existing, c) < 0.06) {
          duplicate = true;
          break;
        }
      }
      if (!duplicate) allPool.add(c);
    }
  }

  final shadow = _nudgeColor(
    _pickDistinct(
      leftPool.isEmpty ? allPool : leftPool,
      const [],
      fallback: allPool.first,
      maxLight: 0.34,
    ),
    sat: 0.95,
    minL: 0.04,
    maxL: 0.16,
  );
  final cream = _toCream(
    _pickDistinct(
      rightPool.isEmpty ? allPool : rightPool,
      [shadow],
      fallback: allPool.last,
      minLight: 0.28,
    ),
  );
  final vibrant = _nudgeColor(
    _pickDistinct(
      allPool,
      [shadow, cream],
      fallback: allPool.first,
      preferSat: true,
      minLight: 0.18,
      maxLight: 0.78,
    ),
    sat: 1.24,
    minL: 0.30,
    maxL: 0.60,
  );
  final primary = _nudgeColor(
    _pickDistinct(
      allPool,
      [shadow, cream, vibrant],
      fallback: vibrant,
      preferSat: true,
    ),
    sat: 1.05,
    minL: 0.20,
    maxL: 0.48,
  );
  final light = _toGold(
    _pickDistinct(
      bottomPool.isEmpty ? allPool : bottomPool,
      [shadow, cream, vibrant, primary],
      fallback: vibrant,
      minLight: 0.28,
    ),
  );
  final dark = _nudgeColor(
    _pickDistinct(
      leftPool.isEmpty ? allPool : leftPool,
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

/// Pre-baked album-cover visualizer textures:
/// - [base]: Full 256×256 saturation-boosted & blurred cover texture.
/// - [sprite]: The same blurred cover texture masked with a radial alpha
///   falloff (1.0 at center -> 0.0 at edge) so multiple rotating & orbiting
///   layers can be composited with zero rectangular edges or per-frame shaders.
class _AuraTextures {
  final ui.Image base;
  final ui.Image sprite;
  const _AuraTextures({required this.base, required this.sprite});
}

final auraTexturesProvider =
    FutureProvider.autoDispose.family<_AuraTextures, String>((ref, url) async {
  if (url.isEmpty) throw StateError('empty artwork');
  final src = await _decodeArtwork(url);
  const out = 256;
  const rect = Rect.fromLTWH(0, 0, 256, 256);

  // 1. Bake full-cover saturated Gaussian blur texture.
  final baseRecorder = ui.PictureRecorder();
  final baseCanvas = Canvas(baseRecorder);
  final blurPaint = Paint()
    ..filterQuality = FilterQuality.low
    ..colorFilter = const ColorFilter.matrix(<double>[
      1.58, -0.34, -0.06, 0, 0,
      -0.11, 1.36, -0.06, 0, 0,
      -0.11, -0.34, 1.64, 0, 0,
      0, 0, 0, 1, 0,
    ])
    ..imageFilter = ui.ImageFilter.blur(
      sigmaX: 26,
      sigmaY: 26,
      tileMode: TileMode.mirror,
    );
  baseCanvas.drawImageRect(
    src,
    Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
    rect,
    blurPaint,
  );
  src.dispose();
  final basePic = baseRecorder.endRecording();
  late final ui.Image baseImg;
  try {
    baseImg = await basePic.toImage(out, out);
  } finally {
    basePic.dispose();
  }

  // 2. Bake radially-feathered sprite texture from `baseImg` so orbiting/
  //    counter-rotating layers have soft circular falloff with zero edges.
  final spriteRecorder = ui.PictureRecorder();
  final spriteCanvas = Canvas(spriteRecorder);
  spriteCanvas.drawImage(baseImg, Offset.zero, Paint());
  final maskPaint = Paint()
    ..blendMode = BlendMode.dstIn
    ..shader = const RadialGradient(
      colors: [
        Color(0xFFFFFFFF),
        Color(0xE0FFFFFF),
        Color(0x66FFFFFF),
        Color(0x00FFFFFF),
      ],
      stops: [0.0, 0.42, 0.74, 1.0],
    ).createShader(rect);
  spriteCanvas.drawRect(rect, maskPaint);
  final spritePic = spriteRecorder.endRecording();
  late final ui.Image spriteImg;
  try {
    spriteImg = await spritePic.toImage(out, out);
  } catch (_) {
    baseImg.dispose();
    rethrow;
  } finally {
    spritePic.dispose();
  }

  ref.onDispose(() {
    baseImg.dispose();
    spriteImg.dispose();
  });
  return _AuraTextures(base: baseImg, sprite: spriteImg);
});

/// Pre-blurred, small aura texture exposed for compatibility.
final auraImageProvider =
    FutureProvider.autoDispose.family<ui.Image, String>((ref, url) async {
  final textures = await ref.watch(auraTexturesProvider(url).future);
  return textures.base;
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

  /// Apple Music stage: vivid multi-colour aura and a fixed dark scrim,
  /// identical in every app theme (the caller renders white text on it).
  /// Only meaningful with [cinematic].
  final bool apple;

  const WaveAmbientMesh({
    super.key,
    required this.artworkUrl,
    this.isFullBleed = true,
    this.height = 360,
    this.opacity = 1.0,
    this.cinematic = false,
    this.apple = false,
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
                child: apple && cinematic
                    ? _AppleScrim(boost: _scrimBoost(palette))
                    : _StageScrim(
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
          _AppleArtworkAura(
            artworkUrl: artworkUrl,
            palette: palette,
            apple: apple,
          ),
          // Contrast guarantee (shared _StageScrim): the aura
          // paints the cover's real colors at high opacity, so a
          // light cover yields a light stage and theme text
          // vanishes — same role as the scrim baked into the
          // non-cinematic mesh painter.
          Positioned.fill(
            child: IgnorePointer(
              child: apple
                  ? _AppleScrim(boost: _scrimBoost(palette))
                  : _StageScrim(
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

/// Apple Music-inspired album cover background visualizer:
/// Composites multiple slowly counter-rotating and orbiting blurred layers of
/// the album cover with regional palette blooms.
class _AppleArtworkAura extends ConsumerWidget {
  final String artworkUrl;
  final ArtworkPalette palette;
  final bool apple;

  const _AppleArtworkAura({
    required this.artworkUrl,
    required this.palette,
    this.apple = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncTextures = ref.watch(auraTexturesProvider(artworkUrl));
    return asyncTextures.when(
      loading: () => const ColoredBox(color: Color(0xFF0B0D11)),
      error: (_, _) => const ColoredBox(color: Color(0xFF0B0D11)),
      data: (textures) => _AuraLayers(
        textures: textures,
        palette: palette,
        apple: apple,
      ),
    );
  }
}

/// Multi-layer album-cover visualizer rendered at 0.5x canvas resolution and
/// upscaled via [FittedBox].
///
/// Uses pre-baked 256×256 blurred cover textures ([_AuraTextures.base] and
/// radially-feathered [_AuraTextures.sprite]) so each frame is just 4 matrix-
/// transformed `drawImageRect` calls plus 3 soft palette radial blooms — no
/// per-frame blur filters or `saveLayer` allocations.
class _AuraLayers extends StatefulWidget {
  final _AuraTextures textures;
  final ArtworkPalette palette;
  final bool apple;

  const _AuraLayers({
    required this.textures,
    required this.palette,
    this.apple = false,
  });

  @override
  State<_AuraLayers> createState() => _AuraLayersState();
}

class _AuraLayersState extends State<_AuraLayers>
    with SingleTickerProviderStateMixin {
  Ticker? _ticker;
  double _phase = 0.0;
  Duration _lastTick = Duration.zero;

  bool _shouldAnimate(BuildContext context) {
    final isTest =
        WidgetsBinding.instance.runtimeType.toString().contains('Test');
    if (isTest) return false;
    final disableAnimations =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (disableAnimations) return false;
    return WaveHazeScope.blurEnabled(context);
  }

  void _syncTicker(bool animate) {
    if (animate) {
      _ticker ??= createTicker(_onTick);
      if (!_ticker!.isActive) {
        _lastTick = Duration.zero;
        _ticker!.start();
      }
    } else {
      _ticker?.stop();
    }
  }

  void _onTick(Duration elapsed) {
    // Throttle to ~30fps (33ms) since the blurred aura moves at a meditative
    // pace (~45s per full revolution).
    if (_lastTick != Duration.zero &&
        (elapsed - _lastTick).inMilliseconds < 33) {
      return;
    }
    final dtMs = _lastTick == Duration.zero
        ? 33
        : (elapsed - _lastTick).inMilliseconds.clamp(1, 200);
    _lastTick = elapsed;
    setState(() {
      _phase = (_phase + (dtMs / 1000.0) * 0.14) % (math.pi * 200);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncTicker(_shouldAnimate(context));
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

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
                  willChange: _ticker?.isActive ?? false,
                  painter: _AuraPainter(
                    textures: widget.textures,
                    palette: widget.palette,
                    canvasSize: half,
                    phase: _phase,
                    apple: widget.apple,
                  ),
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
  final _AuraTextures textures;
  final ArtworkPalette palette;
  final Size canvasSize;
  final double phase;

  /// Apple Music stage ([_paintApple]) instead of the calm tonal one.
  final bool apple;

  _AuraPainter({
    required this.textures,
    required this.palette,
    required this.canvasSize,
    required this.phase,
    this.apple = false,
  });

  /// Alpha plus saturation in one matrix (1 = as baked, <1 = more muted).
  static ColorFilter _alphaFilter(double alpha, [double saturation = 1.0]) {
    final s = saturation;
    final a = (1 - s) * 0.213;
    final b = (1 - s) * 0.715;
    final c = (1 - s) * 0.072;
    return ColorFilter.matrix(<double>[
      a + s, b, c, 0, 0, //
      a, b + s, c, 0, 0, //
      a, b, c + s, 0, 0, //
      0, 0, 0, alpha, 0, //
    ]);
  }

  void _drawRotatedTexture(
    Canvas canvas,
    ui.Image img, {
    required Offset center,
    required double diameter,
    required double angle,
    required double alpha,
    double saturation = 1.0,
  }) {
    final src = Rect.fromLTWH(
      0,
      0,
      img.width.toDouble(),
      img.height.toDouble(),
    );
    final dst = Rect.fromCenter(
      center: Offset.zero,
      width: diameter,
      height: diameter,
    );
    final paint = Paint()
      ..isAntiAlias = true
      ..filterQuality = FilterQuality.low
      ..colorFilter = _alphaFilter(alpha, saturation);
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(angle);
    canvas.drawImageRect(img, src, dst, paint);
    canvas.restore();
  }

  void _drawPaletteBloom(
    Canvas canvas,
    Rect rect, {
    required Offset center,
    required double radius,
    required Color color,
    required double alpha,
    BlendMode blendMode = BlendMode.srcOver,
  }) {
    final paint = Paint()
      ..blendMode = blendMode
      ..shader = RadialGradient(
        colors: [
          color.withValues(alpha: alpha.clamp(0.0, 1.0)),
          color.withValues(alpha: (alpha * 0.45).clamp(0.0, 1.0)),
          color.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.48, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawRect(rect, paint);
  }

  /// Apple Music stage: the cover's own colours as large soft fields that
  /// drift past each other, mid-dark everywhere (no fall-off to black), so
  /// white text reads anywhere on the page.
  ///
  /// A full-saturation wash of the blurred cover sets the colour
  /// distribution; four feathered sprites of the same texture, each turned
  /// to a different angle, bring different regions of the cover (sky, skin,
  /// foliage…) to different corners and orbit slowly. Then a uniform dim
  /// and a soft vignette. Same cost as the tonal stage: 5 drawImageRects at
  /// half resolution, no per-frame filters or layers.
  void _paintApple(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final rect = Offset.zero & size;
    final maxDim = math.max(w, h);

    final ground =
        Color.lerp(const Color(0xFF05070B), palette.darkMuted, 0.65) ??
            palette.darkMuted;
    canvas.drawRect(rect, Paint()..color = ground);

    _drawRotatedTexture(
      canvas,
      textures.base,
      center: Offset(w * 0.50, h * 0.50),
      diameter: maxDim * 1.7,
      angle: phase * 0.08,
      alpha: 0.92,
      saturation: 1.15,
    );

    // (x, y, spin rate, phase offset): spread so each corner gets its own
    // part of the cover.
    const sprites = <(double, double, double, double)>[
      (0.18, 0.22, 0.30, 0.0),
      (0.84, 0.28, -0.24, 2.1),
      (0.62, 0.90, 0.18, 4.2),
      (0.30, 0.80, -0.16, 1.3),
    ];
    for (final (x, y, spin, k) in sprites) {
      _drawRotatedTexture(
        canvas,
        textures.sprite,
        center: Offset(
          w * (x + 0.05 * math.cos(phase * 0.50 + k)),
          h * (y + 0.05 * math.sin(phase * 0.43 + k)),
        ),
        diameter: maxDim * 1.05,
        angle: phase * spin + k,
        alpha: 0.80,
        saturation: 1.25,
      );
    }

    // Uniform dim: keeps the colours but brings the whole stage into the
    // range white text needs. Pale covers get more from [_AppleScrim].
    canvas.drawRect(rect, Paint()..color = const Color(0x4D000000));

    canvas.drawRect(
      rect,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment.center,
          radius: 1.05,
          colors: [
            Color(0x00000000),
            Color(0x00000000),
            Color(0x47000000),
          ],
          stops: [0.0, 0.55, 1.0],
        ).createShader(rect),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    if (apple) {
      _paintApple(canvas, size);
      return;
    }
    final w = size.width;
    final h = size.height;
    final rect = Offset.zero & size;
    final maxDim = math.max(w, h);

    // Calm, tonal stage (Apple Music / Spotify style): one dominant hue of
    // the cover, deep and low-contrast. No hot spots, no competing blobs —
    // just a soft light source on a dark ground that fades out downward.
    final tint = Color.lerp(palette.darkMuted, palette.primary, 0.55) ??
        palette.primary;
    final ground =
        Color.lerp(const Color(0xFF05070B), tint, 0.50) ?? tint;
    canvas.drawRect(rect, Paint()..color = ground);

    // Heavily blurred cover wash, muted and slow: carries the cover's real
    // colour distribution without any visible shape.
    _drawRotatedTexture(
      canvas,
      textures.base,
      center: Offset(w * 0.50, h * 0.42),
      diameter: maxDim * 2.3,
      angle: phase * 0.10,
      alpha: 0.62,
      saturation: 0.72,
    );
    // One feathered sprite drifting very slowly gives the stage life.
    _drawRotatedTexture(
      canvas,
      textures.sprite,
      center: Offset(
        w * (0.32 + 0.04 * math.cos(phase * 0.45)),
        h * (0.36 + 0.04 * math.sin(phase * 0.40)),
      ),
      diameter: maxDim * 1.9,
      angle: -phase * 0.20,
      alpha: 0.38,
      saturation: 0.80,
    );

    // Soft light source, upper left of centre (where the cover sits).
    _drawPaletteBloom(
      canvas,
      rect,
      center: Offset(w * 0.30, h * 0.30),
      radius: maxDim * 0.85,
      color: palette.primary,
      alpha: 0.22,
    );

    // Depth: light at the top, falling away to near-black at the bottom.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0x00000000),
            Color(0x00000000),
            Color(0x66000000),
            Color(0xB3000000),
          ],
          stops: [0.0, 0.38, 0.72, 1.0],
        ).createShader(rect),
    );

    // Gentle vignette so the edges settle into the page.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment.center,
          radius: 1.1,
          colors: [
            Color(0x00000000),
            Color(0x00000000),
            Color(0x4D000000),
          ],
          stops: [0.0, 0.62, 1.0],
        ).createShader(rect),
    );
  }
  @override
  bool shouldRepaint(covariant _AuraPainter old) {
    return old.textures != textures ||
        old.palette != palette ||
        old.canvasSize != canvasSize ||
        old.phase != phase ||
        old.apple != apple;
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

/// Smoothstep on [0, 1] (clamped): zero slope at both ends, so gradients
/// built from it have no visible start or stop line.
double _smooth(double x) {
  final t = x.clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

/// Stretches a radial gradient horizontally about its own centre, turning
/// the circle (radius = shortest side) into an ellipse across a wide band.
class _StretchX extends GradientTransform {
  final double sx;
  final double cx;
  const _StretchX(this.sx, this.cx);

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    final x = bounds.left + bounds.width * cx;
    return Matrix4.identity()
      ..translateByDouble(x, 0, 0, 1)
      ..scaleByDouble(sx, 1, 1, 1)
      ..translateByDouble(-x, 0, 0, 1);
  }
}

/// One eased elliptical glow, centred at [at] (alignment in the band).
Widget _glow(
    Color color, double alpha, Alignment at, double radius, double stretch) {
  const n = 14;
  final ts = [for (var i = 0; i <= n; i++) i / n];
  return DecoratedBox(
    decoration: BoxDecoration(
      gradient: RadialGradient(
        center: at,
        radius: radius,
        colors: [
          for (final t in ts)
            color.withValues(alpha: alpha * (1 - _smooth(t))),
        ],
        stops: ts,
        transform: _StretchX(stretch, (at.x + 1) / 2),
      ),
    ),
  );
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
        // One hue, not lead + tail: two glows in different colours read as
        // two separate blobs. Tail only tints the lead.
        final hue = Color.lerp(lead, tail, 0.3)!;

        // Soft elliptical glows with an eased falloff, so there is no
        // visible banding. Two masks take the wash to zero at the sides,
        // top and foot: the band has no edge at all — it just lifts the
        // header's own surface.
        return IgnorePointer(
          child: AnimatedOpacity(
            opacity: palette == null ? 0 : 1,
            duration: waveMotion(context, WaveMotion.slow),
            curve: WaveMotion.standard,
            child: ShaderMask(
              blendMode: BlendMode.dstIn,
              // Side fade: without it the glow is cut flat at the band's
              // left edge, right behind the portrait.
              shaderCallback: (bounds) {
                const n = 12;
                final ts = [for (var i = 0; i <= n; i++) i / n];
                return LinearGradient(
                  colors: [
                    for (final t in ts)
                      Colors.white.withValues(
                          alpha: _smooth(t / 0.16) *
                              (1 - _smooth((t - 0.8) / 0.2))),
                  ],
                  stops: ts,
                ).createShader(bounds);
              },
              child: ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (bounds) {
                  const n = 16;
                  final ts = [for (var i = 0; i <= n; i++) i / n];
                  return LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      for (final t in ts)
                        Colors.white.withValues(
                            alpha: _smooth(t / 0.3) *
                                (1 - _smooth((t - 0.7) / 0.3))),
                    ],
                    stops: ts,
                  ).createShader(bounds);
                },
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Wide, faint fill so the band reads as one lit surface.
                    _glow(hue, a * 0.38, const Alignment(0.0, 0.2), 1.3, 2.4),
                    // Main glow, hugging the portrait and easing out right.
                    _glow(hue, a * 1.15, const Alignment(-0.85, 0.1), 1.0, 3.0),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
