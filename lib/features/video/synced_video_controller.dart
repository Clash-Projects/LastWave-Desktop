import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/audio/stream_models.dart';
import '../player/playback_service.dart';
import 'music_video_settings.dart';
import 'synced_video_repository.dart';
import 'video_match.dart';

/// Drives the muted music video behind Now Playing and keeps it locked to
/// the audio clock — whatever the audio is (YouTube Opus or lossless).
///
/// The audio player is the master; the video only ever follows it:
///  * big gaps (user seek, buffering, track start) → precise seek,
///  * small drift → the video's rate is nudged until it is back on time,
///  * audio paused → video paused on the matching frame.
/// The video position is `audio position + offset`, where the offset comes
/// from measuring the song against the video's own soundtrack (see
/// [SyncedVideoRepository.measureOffsetMs]).
///
/// Nothing is shown unless the timing is trustworthy: a measured offset,
/// the track's own video, a known intro length, or an edit of the same
/// length as the song. Otherwise the cover art stays.
class SyncedVideoController extends ChangeNotifier {
  SyncedVideoController(this._ref);

  final Ref _ref;

  Player? _player;
  VideoController? _controller;
  VideoController? get controller => _controller;

  int _attached = 0;
  bool _enabled = true;
  int _quality = 0;
  PlayableTrack? _track;
  SyncedVideoBundle? _bundle;
  MusicVideoStream? _stream;
  int _gen = 0;
  bool _mediaOpen = false;
  bool _ready = false;
  bool _inRange = true;
  bool _allowed = false;
  int _offsetMs = 0;
  bool _confident = false;
  Timer? _syncTimer;
  Timer? _releaseTimer;
  DateTime _cooldownUntil = DateTime.fromMillisecondsSinceEpoch(0);
  double _rate = 1.0;
  bool _disposed = false;
  String? _staleAudioUrl;
  Future<void> _tail = Future.value();

  /// True while the video should be on screen in place of the cover.
  bool get visible =>
      _attached > 0 &&
      _enabled &&
      _ready &&
      _allowed &&
      _inRange &&
      _controller != null;

  /// Height of the picture currently playing, for diagnostics/labels.
  String get currentQualityLabel => _stream?.label ?? '';

  // -- inputs -----------------------------------------------------------

  void attach() {
    _attached++;
    _releaseTimer?.cancel();
    _evaluate();
  }

  void detach() {
    if (_attached > 0) _attached--;
    if (_attached > 0) return;
    _stopSyncTimer();
    unawaited(
      _serialized(() async {
        try {
          await _player?.pause();
        } catch (_) {}
      }),
    );
    // Leaving Now Playing for a while releases the decoder; coming back
    // quickly resumes the same stream without a reload.
    _releaseTimer?.cancel();
    _releaseTimer = Timer(const Duration(seconds: 20), () {
      if (_attached == 0) _closeMedia();
    });
    _notify();
  }

  void setEnabled(bool enabled) {
    if (_enabled == enabled) return;
    _enabled = enabled;
    if (!enabled) _closeMedia();
    _evaluate();
  }

  void setQuality(int height) {
    if (_quality == height) return;
    _quality = height;
    if (_bundle != null && _attached > 0 && _enabled) {
      final next = pickVideoStreamForQuality(_bundle!.streams, height);
      if (next != null && next.url != _stream?.url) {
        unawaited(_startPlayback(_gen));
      }
    }
  }

  void onTrackChanged(PlayableTrack? track) {
    if (track?.queueKey == _track?.queueKey) return;
    _track = track;
    // The snapshot still carries the previous song's stream until the new
    // one resolves; measuring against it would save a wrong offset.
    _staleAudioUrl = _ref.read(playbackServiceProvider).stream?.url;
    _gen++;
    _bundle = null;
    _stream = null;
    _ready = false;
    _allowed = false;
    _inRange = true;
    _offsetMs = 0;
    _confident = false;
    _stopSyncTimer();
    _closeMedia();
    _evaluate();
  }

  /// The audio source can change under the same track (YouTube fallback
  /// replaced by lossless, quality switch); its timeline may differ.
  void onAudioStreamChanged() {
    if (_bundle != null && _track != null) _computeOffset(_gen, _bundle!);
  }

  // -- pipeline ---------------------------------------------------------

  void _evaluate() {
    if (_disposed) return;
    final track = _track;
    if (_attached == 0 || !_enabled || track == null) {
      _notify();
      return;
    }
    final gen = _gen;
    if (_bundle == null) {
      unawaited(_load(gen, track));
    } else if (!_mediaOpen) {
      // Quality may have changed while the page was closed.
      unawaited(_startPlayback(gen));
    } else if (_ready) {
      _startSyncTimer();
    }
    _notify();
  }

  bool _loading = false;

  Future<void> _load(int gen, PlayableTrack track) async {
    if (_loading) return;
    _loading = true;
    try {
      // The playing audio's length helps match a video when the track row
      // never had one — but only once the audio belongs to this track.
      final snap = _ref.read(playbackServiceProvider);
      final audioReady =
          snap.current?.queueKey == track.queueKey &&
          snap.stream != null &&
          snap.stream!.url != _staleAudioUrl &&
          snap.duration > Duration.zero;
      final bundle = await _ref
          .read(syncedVideoRepositoryProvider)
          .resolve(
            track,
            fallbackDurationMs: audioReady
                ? snap.duration.inMilliseconds
                : null,
          );
      if (gen != _gen || _disposed || bundle == null) return;
      _bundle = bundle;
      _computeOffset(gen, bundle);
      if (_attached > 0 && _enabled) await _startPlayback(gen);
    } finally {
      _loading = false;
      // A track change while resolving is picked up on the next pass.
      if (gen != _gen && !_disposed) _evaluate();
    }
  }

  String _audioKey(ResolvedStream audio, PlayableTrack track) {
    final ck = audio.cacheKey;
    if (ck.startsWith('youtube:')) {
      final parts = ck.split(':');
      if (parts.length > 1 && parts[1].isNotEmpty) return 'yt:${parts[1]}';
    }
    return '${audio.isLossless ? 'lossless' : 'src'}:${track.queueKey}';
  }

  void _computeOffset(int gen, SyncedVideoBundle bundle) {
    final track = _track;
    if (track == null) return;
    var audio = _ref.read(playbackServiceProvider).stream;
    if (audio != null && audio.url == _staleAudioUrl) audio = null;
    final repo = _ref.read(syncedVideoRepositoryProvider);
    if (audio == null) {
      _offsetMs = bundle.introOffsetMs;
      _confident = false;
      _refreshAllowed();
      return;
    }
    final audioKey = _audioKey(audio, track);
    // The audio is this very video's soundtrack: same timeline.
    if (audioKey == 'yt:${bundle.videoId}') {
      _offsetMs = 0;
      _confident = true;
      _refreshAllowed();
      return;
    }
    final key = '$audioKey|${bundle.videoId}';
    if (repo.hasSavedOffset(key)) {
      final saved = repo.savedOffset(key);
      _offsetMs = saved ?? bundle.introOffsetMs;
      _confident = saved != null;
      _refreshAllowed();
      return;
    }
    _offsetMs = bundle.introOffsetMs;
    _confident = false;
    _refreshAllowed();
    final source = audio;
    unawaited(() async {
      final measured = await repo.measureOffsetMs(
        key: key,
        songUrl: source.url,
        songHeaders: source.requestHeaders,
        videoId: bundle.videoId,
        songVideoId: track.videoId,
      );
      if (gen != _gen || _disposed || measured == null) return;
      _offsetMs = measured;
      _confident = true;
      _cooldownUntil = DateTime.fromMillisecondsSinceEpoch(0);
      _refreshAllowed();
      _notify();
    }());
  }

  /// Whether the timing can be trusted enough to show the picture.
  void _refreshAllowed() {
    final bundle = _bundle;
    var allowed = false;
    if (bundle != null) {
      if (_confident || bundle.introOffsetMs > 0) {
        allowed = true;
      } else {
        // Same-length edits share the song's timeline.
        final videoMs = _player?.state.duration.inMilliseconds ?? 0;
        final audioMs = _ref
            .read(playbackServiceProvider)
            .duration
            .inMilliseconds;
        allowed =
            videoMs > 0 && audioMs > 0 && (videoMs - audioMs).abs() <= 4000;
      }
    }
    if (allowed != _allowed) {
      _allowed = allowed;
      _notify();
    }
  }

  Future<void> _ensurePlayer() async {
    if (_player != null && _controller != null) return;
    MediaKit.ensureInitialized();
    final player = Player(
      configuration: const PlayerConfiguration(
        muted: true,
        title: 'LastWave Music Video',
        logLevel: MPVLogLevel.error,
        bufferSize: 64 * 1024 * 1024,
      ),
    );
    _player = player;
    _controller = VideoController(
      player,
      configuration: VideoControllerConfiguration(
        // Same platform split as the motion-art player: Linux presents
        // through the software path (no cross-context EGL stalls) and
        // decodes in software; Windows/macOS use their hardware paths.
        enableHardwareAcceleration: !Platform.isLinux,
        hwdec: Platform.isLinux ? 'no' : 'auto-safe',
      ),
    );
    try {
      await _controller!.platform.future.timeout(const Duration(seconds: 6));
    } catch (_) {}
    final native = player.platform;
    if (native is NativePlayer) {
      final props = <String, String>{
        // A silent follower: no audio device, no subtitles.
        'ao': 'null',
        'aid': 'no',
        'sid': 'no',
        'keep-open': 'yes',
        // Land seeks on the exact frame (the sync target is exact), and
        // never decode frames that are already late: staying current beats
        // showing every frame of a backdrop.
        'hr-seek': 'yes',
        'hr-seek-framedrop': 'yes',
        'framedrop': 'decoder+vo',
        // No audio clock to chase; pace by the wall clock.
        'video-sync': 'desync',
        // Read well ahead so a slow patch of network never starves decode,
        // and after a stall refill a few seconds before resuming rather
        // than stuttering on every packet.
        'cache': 'yes',
        'demuxer-readahead-secs': '30',
        'cache-secs': '60',
        'demuxer-max-back-bytes': '${8 * 1024 * 1024}',
        'cache-pause': 'yes',
        'cache-pause-wait': '3',
        if (Platform.isLinux) 'vd-lavc-fast': 'yes',
      };
      for (final e in props.entries) {
        try {
          await native.setProperty(e.key, e.value);
        } catch (_) {}
      }
    }
    _notify();
  }

  int _startToken = 0;

  /// Tries the ranked candidates in turn — verified to serve bytes, then
  /// opened and checked to decode — until one is on screen. A link that
  /// fails moves on to the next best, never silently to a worse picture
  /// than necessary and never to a wrong video.
  Future<void> _startPlayback(int gen) async {
    final bundle = _bundle;
    if (bundle == null || _attached == 0 || !_enabled) return;
    final token = ++_startToken;
    bool stale() =>
        gen != _gen ||
        token != _startToken ||
        _disposed ||
        _attached == 0 ||
        !_enabled;
    final repo = _ref.read(syncedVideoRepositoryProvider);
    final ranked = rankVideoStreams(bundle.streams, _quality);
    var failures = 0;
    for (final stream in ranked) {
      if (stale()) return;
      if (failures >= 4) break;
      if (!await repo.probeVideoStream(stream)) {
        failures++;
        continue;
      }
      if (stale()) return;
      if (await _openStream(gen, token, stream)) return;
      failures++;
    }
    if (stale()) return;
    // Nothing played: links may have expired, so resolve afresh next time.
    final track = _track;
    if (track != null) repo.invalidate(track);
    _bundle = null;
    _closeMedia();
  }

  Future<bool> _openStream(int gen, int token, MusicVideoStream stream) async {
    bool stale() => gen != _gen || token != _startToken || _disposed;
    _stream = stream;
    _ready = false;
    // Marks the media as requested so a second evaluate does not reopen.
    _mediaOpen = true;
    _stopSyncTimer();
    _notify();
    var opened = false;
    await _serialized(() async {
      if (stale()) return;
      await _ensurePlayer();
      final player = _player;
      if (player == null || stale()) return;
      try {
        await player.stop();
      } catch (_) {}
      if (stale()) return;
      await player.open(
        Media(stream.url, httpHeaders: stream.requestHeaders),
        play: false,
      );
      _rate = 1.0;
      _correcting = false;
      try {
        await player.setRate(1.0);
      } catch (_) {}
      opened = true;
    });
    if (!opened || stale()) return false;
    final player = _player!;

    // Real picture dimensions mean the stream is decodable.
    final decodable = await _waitFor(
      () => (player.state.width ?? 0) > 0,
      const Duration(seconds: 15),
    );
    if (stale()) return false;
    if (!decodable) return false;

    // Land on the audio's current frame, then let a few seconds buffer so
    // the first moments on screen do not stall.
    final target = _targetMs();
    if (target > 0) {
      try {
        await player.seek(Duration(milliseconds: target));
      } catch (_) {}
    }
    await _waitFor(
      () =>
          !player.state.buffering &&
          player.state.buffer - player.state.position >=
              const Duration(milliseconds: 2500),
      const Duration(seconds: 7),
    );
    if (stale()) return false;
    _refreshAllowed();
    _ready = true;
    _cooldownUntil = DateTime.fromMillisecondsSinceEpoch(0);
    if (_attached > 0) _startSyncTimer();
    _notify();
    return true;
  }

  Future<bool> _waitFor(bool Function() test, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_disposed) return false;
      if (test()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    return test();
  }

  int _targetMs() {
    final audio = _ref.read(playbackServiceProvider.notifier).livePosition;
    return audio.inMilliseconds + _offsetMs;
  }

  void _closeMedia() {
    _stopSyncTimer();
    final wasOpen = _mediaOpen;
    _mediaOpen = false;
    _ready = false;
    if (!wasOpen) return;
    unawaited(
      _serialized(() async {
        try {
          await _player?.stop();
        } catch (_) {}
      }),
    );
    _notify();
  }

  // -- sync loop --------------------------------------------------------

  void _startSyncTimer() {
    if (_syncTimer?.isActive == true) return;
    _syncTimer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => _syncTick(),
    );
  }

  void _stopSyncTimer() {
    _syncTimer?.cancel();
    _syncTimer = null;
  }

  bool _ticking = false;
  bool _correcting = false;
  DateTime _lastRateAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Drift (video position minus where it should be) that starts and stops
  /// a rate correction, and the size past which only a seek will do.
  static const int _driftStartMs = 70;
  static const int _driftStopMs = 20;
  static const int _driftSeekMs = 500;

  Future<void> _syncTick() async {
    final player = _player;
    if (_ticking || !_ready || player == null || _disposed) return;
    _ticking = true;
    try {
      final snap = _ref.read(playbackServiceProvider);
      final target = _targetMs();
      final videoMs = player.state.duration.inMilliseconds;
      final inRange = target >= 0 && (videoMs <= 0 || target < videoMs - 80);
      if (inRange != _inRange) {
        _inRange = inRange;
        _notify();
      }
      if (!_allowed) _refreshAllowed();
      if (!inRange || !_allowed) {
        if (player.state.playing) await player.pause();
        return;
      }

      final now = DateTime.now();
      final drift = player.state.position.inMilliseconds - target;
      final audioRunning = snap.isPlaying && !snap.isBuffering;

      if (!audioRunning) {
        if (player.state.playing) await player.pause();
        // Paused scrubbing: keep the still frame on the audio position.
        if (drift.abs() > 80 && now.isAfter(_cooldownUntil)) {
          _cooldownUntil = now.add(const Duration(milliseconds: 350));
          await player.seek(Duration(milliseconds: target));
        }
        return;
      }

      // A stalled stream is refilling its buffer. Seeking or re-timing it
      // now only throws the buffer away and stalls it again — that loop is
      // what turned a slow patch of network into a stuttering picture. Let
      // it catch up; the next tick corrects whatever drift remains.
      if (player.state.buffering) return;
      if (!player.state.playing) await player.play();
      if (now.isBefore(_cooldownUntil)) return;

      final base = snap.speed <= 0 ? 1.0 : snap.speed;
      if (drift.abs() > _driftSeekMs) {
        // Seek a touch ahead: the seek itself takes time to land.
        _cooldownUntil = now.add(const Duration(milliseconds: 1500));
        _correcting = false;
        await _setRate(player, base, now, force: true);
        await player.seek(Duration(milliseconds: target + 80));
        return;
      }

      // Small drift is closed by running slightly fast or slow. Hysteresis
      // keeps it from hunting around zero, and rate changes are rationed:
      // each one restarts mpv's frame pacing, so tweaking the speed every
      // tick was itself a source of judder.
      if (_correcting) {
        if (drift.abs() <= _driftStopMs) {
          _correcting = false;
          await _setRate(player, base, now, force: true);
          return;
        }
      } else if (drift.abs() > _driftStartMs) {
        _correcting = true;
      }
      if (_correcting) {
        // Video ahead (drift > 0) → slow down; behind → speed up.
        final factor = (1 - drift / 2500).clamp(0.94, 1.06);
        await _setRate(player, base * factor, now);
      } else {
        await _setRate(player, base, now);
      }
    } catch (_) {
    } finally {
      _ticking = false;
    }
  }

  Future<void> _setRate(
    Player player,
    double rate,
    DateTime now, {
    bool force = false,
  }) async {
    if (!force &&
        (now.difference(_lastRateAt).inMilliseconds < 400 ||
            (rate - _rate).abs() < 0.01)) {
      return;
    }
    if ((rate - _rate).abs() < 0.001) return;
    _lastRateAt = now;
    _rate = rate;
    await player.setRate(rate);
  }

  // -- plumbing ---------------------------------------------------------

  Future<void> _serialized(Future<void> Function() fn) {
    final run = _tail.then((_) async {
      try {
        await fn();
      } catch (e) {
        if (kDebugMode) debugPrint('[video-sync] $e');
      }
    });
    _tail = run;
    return run;
  }

  bool _notifyPending = false;

  void _notify() {
    if (_notifyPending || _disposed) return;
    _notifyPending = true;
    scheduleMicrotask(() {
      _notifyPending = false;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _stopSyncTimer();
    _releaseTimer?.cancel();
    final player = _player;
    _player = null;
    _controller = null;
    unawaited(() async {
      try {
        await player?.dispose();
      } catch (_) {}
    }());
    super.dispose();
  }
}

final syncedVideoControllerProvider =
    ChangeNotifierProvider<SyncedVideoController>((ref) {
      final controller = SyncedVideoController(ref);
      controller._enabled = ref.read(musicVideoEnabledProvider);
      controller._quality = ref.read(musicVideoQualityProvider);
      controller._track = ref.read(playbackServiceProvider).current;
      ref.listen<bool>(
        musicVideoEnabledProvider,
        (_, v) => controller.setEnabled(v),
      );
      ref.listen<int>(
        musicVideoQualityProvider,
        (_, v) => controller.setQuality(v),
      );
      ref.listen<PlayableTrack?>(
        playbackServiceProvider.select((s) => s.current),
        (_, t) => controller.onTrackChanged(t),
      );
      ref.listen<ResolvedStream?>(
        playbackServiceProvider.select((s) => s.stream),
        (prev, next) {
          if (prev?.url != next?.url) controller.onAudioStreamChanged();
        },
      );
      return controller;
    });
