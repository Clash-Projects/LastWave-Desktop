import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'audio_analysis.dart';

enum AnalysisSide { head, tail }

/// Decodes the head / tail of a track to PCM on a hidden libmpv deck
/// and analyses it off the UI isolate.
///
/// The deck uses mpv's built-in `pcm` audio output with `untimed`, so a
/// minute of audio decodes in well under a second from local or cached
/// sources — the same decoder, network stack and headers as playback,
/// whatever the source (addon, YouTube, local file). Nothing reaches the
/// sound card. One fresh mpv instance per job: disposing it is what
/// closes (and flushes) the PCM file.
class AutomixAnalyzer {
  AutomixAnalyzer({
    required this.serialize,
    required this.log,
    String? cacheDir,
    this.wanted,
    this.decoder,
  }) : cacheDir = cacheDir ??
            '${Directory.systemTemp.path}${Platform.pathSeparator}lastwave'
                '${Platform.pathSeparator}automix' {
    _checkCrashMarker();
  }

  /// Whether a queued job is still worth running when its turn comes
  /// (the listener may have skipped ahead). Null = always.
  final bool Function(String key)? wanted;

  /// Test hook replacing the libmpv decode.
  final Future<Int16List?> Function(AnalysisSide side, String url,
      Map<String, String> headers, Duration duration)? decoder;

  /// After this many decode failures in a row the analyzer turns itself
  /// off for the session (AutoMix then mixes without analysis).
  static const int maxConsecutiveFailures = 4;
  int _consecutiveFailures = 0;

  /// Runs one native mpv call in the app-wide mpv order (Windows libmpv
  /// heap safety — see PlaybackService._serializedMpv).
  final Future<T> Function<T>(Future<T> Function() op) serialize;
  final void Function(String line) log;
  final String cacheDir;

  static const int sampleRate = 11025;
  static const Duration window = Duration(seconds: 60);
  static const Duration _jobTimeout = Duration(seconds: 45);

  final Map<String, TrackAnalysis> _mem = {};
  final Map<String, Future<TrackAnalysis?>> _inflight = {};
  final Set<String> _failed = {};
  Future<void> _queue = Future.value();
  bool _disabled = false;
  int _jobSeq = 0;

  /// Stable identity of a decoded source. The same song from a lossless
  /// addon and from YouTube has different offsets, so they never share.
  static String sourceId(String streamCacheKey) {
    if (streamCacheKey.startsWith('youtube:')) {
      return streamCacheKey.split(':').take(2).join(':');
    }
    return streamCacheKey;
  }

  static String keyFor(String queueKey, String source, AnalysisSide side) =>
      '$queueKey|$source|${side.name}';

  TrackAnalysis? cached(String key) => _mem[key];

  /// Starts (or joins) the analysis for [key]. Never throws.
  Future<TrackAnalysis?> request({
    required String key,
    required AnalysisSide side,
    required String url,
    Map<String, String> headers = const {},
    Duration duration = Duration.zero,
  }) {
    final hit = _mem[key];
    if (hit != null) return Future.value(hit);
    if (_disabled || _failed.contains(key)) return Future.value(null);
    if (url.isEmpty) return Future.value(null);
    final pending = _inflight[key];
    if (pending != null) return pending;
    if (side == AnalysisSide.tail && duration <= Duration.zero) {
      return Future.value(null);
    }
    final completer = Completer<TrackAnalysis?>();
    _inflight[key] = completer.future;
    // One job at a time: analysis is background work and must never
    // compete with the playing deck for bandwidth or CPU.
    _queue = _queue.then((_) async {
      TrackAnalysis? result;
      var skipped = false;
      try {
        result = await _fromDisk(key);
        if (result == null) {
          if (_disabled || !(wanted?.call(key) ?? true)) {
            // Skipped ahead / turned off while queued: drop the job but do
            // not mark it failed, so it can be asked for again later.
            skipped = true;
          } else {
            result = await _decodeAndAnalyse(key, side, url, headers, duration);
            if (result == null) {
              _consecutiveFailures++;
              if (_consecutiveFailures >= maxConsecutiveFailures) {
                _disabled = true;
                log('automix analysis off for this session after '
                    '$_consecutiveFailures failed decodes');
              }
            } else {
              _consecutiveFailures = 0;
            }
          }
        }
      } catch (e) {
        log('automix analysis error key=$key err=${e.runtimeType}');
        result = null;
      }
      if (result != null) {
        _mem[key] = result;
        if (_mem.length > 64) _mem.remove(_mem.keys.first);
      } else if (!skipped) {
        _failed.add(key);
      }
      _inflight.remove(key);
      if (!completer.isCompleted) completer.complete(result);
    });
    return completer.future;
  }

  Future<TrackAnalysis?> _decodeAndAnalyse(String key, AnalysisSide side,
      String url, Map<String, String> headers, Duration duration) async {
    final sw = Stopwatch()..start();
    final Int16List? pcm;
    final hook = decoder;
    if (hook != null) {
      pcm = await hook(side, url, headers, duration);
    } else {
      // Crash marker around the native decode: if the process dies in
      // here, the next launch finds it and skips analysis (see
      // _checkCrashMarker) instead of crashing the same way again.
      await _setCrashMarker(true);
      try {
        pcm = await _decode(side, url, headers, duration);
      } finally {
        await _setCrashMarker(false);
      }
    }
    if (pcm == null) return null;
    final decodeMs = sw.elapsedMilliseconds;
    final offset = side == AnalysisSide.tail
        ? _tailStart(duration).inMilliseconds / 1000.0
        : 0.0;
    final analysis = sanitizeAnalysis(
        await compute(analyzePcmWindow, PcmWindow(pcm, sampleRate, offset)));
    if (analysis == null) {
      log('automix analysis rejected key=$key (implausible values)');
      return null;
    }
    log('automix analysed key=$key side=${side.name} '
        'bpm=${analysis.bpm.toStringAsFixed(1)} '
        'conf=${analysis.confidence.toStringAsFixed(2)} '
        'audible=${analysis.audibleStart.toStringAsFixed(1)}'
        '-${analysis.contentEnd.toStringAsFixed(1)} '
        'decode_ms=$decodeMs total_ms=${sw.elapsedMilliseconds}');
    unawaited(_toDisk(key, analysis));
    return analysis;
  }

  static Duration _tailStart(Duration duration) {
    final s = duration - window;
    return s > Duration.zero ? s : Duration.zero;
  }

  Future<Int16List?> _decode(AnalysisSide side, String url,
      Map<String, String> headers, Duration duration) async {
    final dir = Directory(cacheDir);
    try {
      await dir.create(recursive: true);
    } catch (_) {}
    final pcmPath =
        '${dir.path}${Platform.pathSeparator}job-$pid-${_jobSeq++}.pcm';
    final file = File(pcmPath);
    Player? deck;
    StreamSubscription<bool>? doneSub;
    StreamSubscription<String>? errSub;
    final done = Completer<bool>();
    try {
      log('analysis deck create');
      deck = await serialize(() async {
        MediaKit.ensureInitialized();
        final p = Player(
          configuration: const PlayerConfiguration(
            vo: 'null',
            title: 'LastWave Analysis',
            bufferSize: 8 * 1024 * 1024,
          ),
        );
        final dyn = p.platform as dynamic;
        // Order matters: the output is chosen when audio first starts.
        for (final e in <String, String>{
          'ao': 'pcm',
          'ao-pcm-file': pcmPath,
          'ao-pcm-waveheader': 'no',
          'untimed': 'yes',
          'audio-samplerate': '$sampleRate',
          'audio-channels': 'mono',
          'audio-format': 's16',
          'vid': 'no',
          'replaygain': 'no',
          'af': '',
          'volume': '100',
          'stream-lavf-o': 'timeout=15000000',
        }.entries) {
          try {
            await dyn.setProperty(e.key, e.value);
          } catch (_) {}
        }
        return p;
      });
      final p = deck!;
      doneSub = p.stream.completed.listen((c) {
        if (c && !done.isCompleted) done.complete(true);
      });
      errSub = p.stream.error.listen((e) {
        // Filter / audio-device chatter is harmless here.
        final t = e.toLowerCase();
        if (t.contains('filter')) return;
        if (!done.isCompleted &&
            (t.contains('failed to open') || t.contains('tcp:'))) {
          done.complete(false);
        }
      });
      var playUrl = url;
      if (!playUrl.startsWith('http') && !playUrl.startsWith('file:')) {
        try {
          playUrl = Uri.file(playUrl).toString();
        } catch (_) {}
      }
      final media = side == AnalysisSide.head
          ? Media(playUrl, httpHeaders: headers, end: window)
          : Media(playUrl, httpHeaders: headers, start: _tailStart(duration));
      log('analysis deck open side=${side.name}');
      await serialize(() => p.open(media, play: true));
      final ok = await done.future.timeout(_jobTimeout, onTimeout: () => false);
      if (!ok) return null;
    } catch (_) {
      return null;
    } finally {
      await doneSub?.cancel();
      await errSub?.cancel();
      final p = deck;
      if (p != null) {
        // Disposing destroys the mpv core, which closes the PCM file.
        log('analysis deck dispose');
        try {
          await serialize(() async {
            try {
              await p.stop();
            } catch (_) {}
            await p.dispose();
          }).timeout(const Duration(seconds: 5));
        } catch (_) {}
      }
    }
    try {
      final bytes = await file.readAsBytes();
      final usable = bytes.length & ~1;
      // Under 8 s of audio cannot carry a tempo; the deck likely failed.
      if (usable < sampleRate * 2 * 8) return null;
      final out = Int16List(usable ~/ 2);
      out.buffer.asUint8List().setRange(0, usable, bytes);
      return out;
    } catch (_) {
      return null;
    } finally {
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  // ---- disk cache -----------------------------------------------------------

  String _path(String key) =>
      '$cacheDir${Platform.pathSeparator}${_fnv(key)}.json';

  Future<TrackAnalysis?> _fromDisk(String key) async {
    try {
      final f = File(_path(key));
      if (!await f.exists()) return null;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map<String, Object?> || j['key'] != key) return null;
      final a = sanitizeAnalysis(
          TrackAnalysis.fromJson((j['a'] as Map).cast<String, Object?>()));
      if (a == null) {
        // Corrupt / older file: drop it so it is rebuilt.
        try {
          await f.delete();
        } catch (_) {}
      }
      return a;
    } catch (_) {
      return null;
    }
  }

  Future<void> _toDisk(String key, TrackAnalysis a) async {
    try {
      await Directory(cacheDir).create(recursive: true);
      await File(_path(key))
          .writeAsString(jsonEncode({'key': key, 'a': a.toJson()}));
    } catch (_) {}
  }

  /// Turns the feature off for the session (e.g. the platform cannot
  /// create the analysis deck).
  void disable() => _disabled = true;

  bool get disabled => _disabled;

  String get _markerPath =>
      '$cacheDir${Platform.pathSeparator}decode-in-progress';

  void _checkCrashMarker() {
    if (decoder != null) return;
    try {
      final f = File(_markerPath);
      if (f.existsSync()) {
        _disabled = true;
        f.deleteSync();
        log('automix analysis off for this session: the previous run '
            'ended during an analysis decode');
      }
    } catch (_) {}
  }

  Future<void> _setCrashMarker(bool on) async {
    try {
      final f = File(_markerPath);
      if (on) {
        await Directory(cacheDir).create(recursive: true);
        await f.writeAsString('${DateTime.now().toIso8601String()} pid=$pid',
            flush: true);
      } else if (await f.exists()) {
        await f.delete();
      }
    } catch (_) {}
  }

  /// FNV-1a 32 over the key plus its length; the JSON also stores the
  /// full key, so a collision just reads as a miss.
  static String _fnv(String s) {
    var h = 0x811c9dc5;
    for (final c in utf8.encode(s)) {
      h ^= c;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return '${h.toRadixString(16)}-${s.length}';
  }
}

/// Rejects analyses with values no real track produces (NaN, a negative
/// window, an absurd tempo, an unsorted grid) — from a bad decode or a
/// corrupt cache file — and returns the rest unchanged.
TrackAnalysis? sanitizeAnalysis(TrackAnalysis? a) {
  if (a == null) return null;
  bool ok(double v) => v.isFinite;
  if (!ok(a.windowStart) || !ok(a.windowEnd) || a.windowEnd <= a.windowStart) {
    return null;
  }
  if (!ok(a.audibleStart) || !ok(a.contentEnd)) return null;
  if (a.audibleStart < a.windowStart - 0.5 ||
      a.contentEnd > a.windowEnd + 0.5 ||
      a.contentEnd < a.audibleStart) {
    return null;
  }
  if (!ok(a.confidence) || a.confidence < 0 || a.confidence > 1) return null;
  if (!ok(a.bpm) || a.bpm < 0 || a.bpm > 260) return null;
  if (a.bpm > 0 && a.bpm < 40) return null;
  for (var i = 1; i < a.beats.length; i++) {
    if (!ok(a.beats[i]) || a.beats[i] <= a.beats[i - 1]) return null;
  }
  for (var i = 1; i < a.downbeats.length; i++) {
    if (!ok(a.downbeats[i]) || a.downbeats[i] <= a.downbeats[i - 1]) {
      return null;
    }
  }
  return a;
}
