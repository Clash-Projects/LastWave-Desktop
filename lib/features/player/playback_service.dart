import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import '../../core/artwork/official_artwork_service.dart';
import '../../core/audio/stream_models.dart';
import '../audio_output/pcm_format.dart';
import '../audio_output/wasapi_engine.dart';
import '../downloads/download_manager.dart';
import '../addons/addon_api.dart';
import '../innertube/innertube_api.dart';
import '../lastfm/scrobble_repository.dart';
import '../lossless/lossless_source.dart';
import 'player_state.dart';
import '../../core/storage/app_database.dart';
import '../../core/storage/prefs.dart';
import '../search/shared_providers.dart';

/// Desktop playback service built on media_kit (MPV).
///
/// Reproduces LastWave-native `MusicPlayer` product behaviour:
/// - local download → lossless vs YouTube race → retry → skip
/// - queue with shuffle/repeat/speed/sleep, endless radio refill
/// - session persistence + scrobble thresholds
/// - stream failure backoff (client cooldown + unavailable set)
class PlaybackService extends StateNotifier<PlayerSnapshot> {
  final InnerTubeMusicApi _tube;
  final LosslessSource _lossless;
  final void Function(String notice)? _onAddonQuota;
  final ScrobbleRepository _scrobbler;
  final DownloadManager _downloads;
  final PrefsHandle _prefs;
  final SessionStore _sessions;
  final OfficialArtworkService _artworkService;

  Player? _player;
  final List<StreamSubscription> _subs = [];
  final List<PlayerLog> _mpvLogTail = [];
  static const int _mpvLogTailMax = 50;
  final Set<String> _unavailable = {};
  final Set<String> _losslessBypass = {};
  List<int> _shuffleOrder = [];
  Timer? _sleepTimer;
  DateTime? _sleepDeadline;
  Timer? _persistThrottle;
  DateTime _lastPersist = DateTime.fromMillisecondsSinceEpoch(0);
  // UI position emission gate: mpv fires time-pos per frame (60Hz+)
  // and every emission rebuilds all position watchers (dock bar,
  // karaoke, time labels, mini player). Karaoke interpolates
  // wall-clock between updates and bars read smooth at 10Hz, so the
  // state snapshot is throttled. Scrobble uses wall-clock deltas so
  // 10Hz keeps identical accuracy; prefetch fires once per track.
  DateTime _lastPositionEmit = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastBufferedEmit = DateTime.fromMillisecondsSinceEpoch(0);

  // Scrobble bookkeeping (mirrors Android detector).
  int _scrobbleStartEpoch = 0;
  double _accumulatedSeconds = 0;
  DateTime? _lastTick;
  bool _nowPlayingSent = false;
  PlayableTrack? _scrobbleTrack;
  int _scrobbleDurationSec = 0;
  bool _scrobbledThisWindow = false;
  // YT Music history push shares the scrobble window: a single ping
  // per window, fired alongside the scrobble, gated by the settings
  // flag. Android parity: repeats would file duplicate entries.
  bool _ytHistoryPushedThisWindow = false;
  // One client playback nonce per scrobble window.
  String _ytHistoryCpn = '';
  // Pre-signed watchtime bases by videoId (from the player response
  // that resolved the stream). Memory-only, capped: tokens are bound
  // to the live session.
  final Map<String, String> _watchtimeUrls = {};

  void _stashWatchtimeUrl(String videoId, String url) {
    try {
      if (videoId.isEmpty || url.isEmpty) return;
      _watchtimeUrls.remove(videoId);
      _watchtimeUrls[videoId] = url;
      while (_watchtimeUrls.length > 24) {
        _watchtimeUrls.remove(_watchtimeUrls.keys.first);
      }
    } catch (_) {}
  }

  void _rememberWatchtime(String videoId, ResolvedStream stream) {
    _stashWatchtimeUrl(videoId, stream.watchtimeUrl);
  }

  bool _endlessRadio = false;
  final Set<String> _radioSeeds = {};
  bool _resolving = false;
  int _resolvingIndex = -1;
  int _resolveGeneration = 0;
  int _playbackAttempt = 0;
  int _failedGeneration = -1;
  String _activeQueueKey = '';
  bool _lockSoftwareVolume = false;
  bool exclusiveApplied = false;
  String? wasapiError;
  String? _forcedAoFormat;
  final ResolvedStreamCache _playCache = ResolvedStreamCache();
  final Map<String, Future<ResolvedStream?>> _resolveInflight = {};
  final Set<String> _prefetchInflight = {};
  String _prefetchSeedKey = '';

  // -- first-audio clock (debug timing only) -------------------------------
  //
  // `open()` returning — and even `playing=true` — is NOT audible sound.
  // mpv flips pause=no (media_kit's `playing`) as soon as loadfile is
  // accepted, then prerolls cache (`paused-for-cache`) before the first
  // frame renders. The only signal close to "sound coming out" is the
  // position clock advancing past zero, so that's what arms this clock:
  // resolve-start → first position > 0 for the same generation.
  DateTime? _audioClockStart;
  String _audioClockKey = '';
  int _audioClockGeneration = -1;
  DateTime? _audioOpenDoneAt;

  // -- native mpv serialization -------------------------------------------
  //
  // Windows libmpv corrupts its heap when stop/open/property writes
  // overlap: the first track plays, the next transition dies in ntdll
  // with 0xc0000005 and no Dart log (the await never returns). Every
  // stream-lifecycle native call goes through [_serializedMpv] so only
  // one is ever in flight. Hot-path transport (seek/volume/rate) stays
  // direct — serializing those would queue-jank playback.
  Future<void> _mpvTail = Future.value();

  Future<T> _serializedMpv<T>(Future<T> Function() op) {
    final run = _mpvTail.then((_) => op());
    _mpvTail = run.then((_) {}, onError: (_) {});
    return run;
  }

  /// True when mpv currently holds a DASH manifest. DASH teardown on
  /// Windows lags the stop call (segment fetches still in flight), so
  /// the next open waits for idle first — otherwise loadfile races
  /// the dying demuxer and corrupts the heap.
  bool _lastWasDash = false;

  /// Crash-surviving breadcrumb file (`<temp>/lastwave/mpv-ops.log`).
  /// Written synchronously with flush BEFORE each native op, so the
  /// last line names the call that killed the process. Never logs
  /// URLs, cookies, or headers — op names and stream shapes only.
  String? _crumbPath;

  void _crumb(String line) {
    try {
      final path = _crumbPath;
      if (path == null) return;
      File(path).writeAsStringSync(
        '${DateTime.now().toIso8601String()} $line\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {}
  }

  /// Debug-only per-stage timing breadcrumb. Shape/timing only —
  /// never URLs, headers, or tokens. Correlate stages by [key].
  void _logTiming(String line) {
    if (!kDebugMode) return;
    debugPrint('LastWave-Timing $line');
  }

  /// Fires once per resolve: the first position tick past zero is the
  /// first rendered frame — the closest signal to audible sound.
  /// (NOT `playing=true`: mpv unpauses on loadfile-accept, before the
  /// cache preroll finishes.) Consumed via [_audioClockGeneration] so
  /// later ticks and seeks never re-log. Ticks arriving before open is
  /// issued belong to the outgoing track (mpv keeps playing it until
  /// the stop/open lands) — they must not fire the new clock, which is
  /// exactly the `time_to_audio_ms=7 post_open_ms=-1` ghost.
  void _maybeLogFirstAudio(Duration position) {
    try {
      if (!kDebugMode) return;
      if (position <= Duration.zero) return;
      if (_audioClockGeneration != _resolveGeneration) return;
      if (_audioOpenDoneAt == null) return;
      final start = _audioClockStart;
      if (start == null || _audioClockKey.isEmpty) return;
      if (state.current?.queueKey != _audioClockKey) return;
      final now = DateTime.now();
      final totalMs = now.difference(start).inMilliseconds;
      final openDone = _audioOpenDoneAt;
      final postOpenMs =
          openDone != null ? now.difference(openDone).inMilliseconds : -1;
      _logTiming('audio key=$_audioClockKey time_to_audio_ms=$totalMs '
          'post_open_ms=$postOpenMs');
      _audioClockGeneration = -1;
    } catch (_) {}
  }

  PlaybackService(
    this._tube,
    this._lossless,
    this._scrobbler,
    this._downloads,
    this._prefs,
    this._sessions, [
    OfficialArtworkService? artworkService,
    this._onAddonQuota,
  ])  : _artworkService = artworkService ?? OfficialArtworkService(),
        super(const PlayerSnapshot());

  Future<void> ensurePlayer() async {
    if (_player != null) return;
    // Limusic parity (Dart side): one persistent audio-only libmpv
    // instance with on-disk demuxer cache + gapless. media_kit already
    // defaults to vo=null (audio-only) + 32MiB buffer; we set the rest
    // best-effort via mpv properties. No Rust/C++ involved.
    // 16MiB demuxer buffer: lossless 24/192 peaks ~9Mbps, so this
    // still holds ~14s of the heaviest stream while halving the
    // 32MiB RSS cost (was the single biggest native allocation).
    _player = Player(
      configuration: const PlayerConfiguration(
        vo: 'null',
        title: 'LastWave',
        bufferSize: 16 * 1024 * 1024,
      ),
    );
    final created = _player!;
    try {
      final platform = created.platform;
      if (platform != null) {
        final dyn = platform as dynamic;
        try {
          await dyn.setProperty('gapless-audio', 'yes');
        } catch (_) {}
        try {
          await dyn.setProperty('cache', 'yes');
        } catch (_) {}
        try {
          await dyn.setProperty('cache-on-disk', 'yes');
        } catch (_) {}
        try {
          await dyn.setProperty(
              'demuxer-max-back-bytes', '${4 * 1024 * 1024}');
        } catch (_) {}
        try {
          await dyn.setProperty('vid', 'no');
        } catch (_) {}
        try {
          // Stall tolerance for slow stream starts (loopback assembly
          // waits on CDN first bytes; mpv otherwise aborts the open
          // after ~5s and forces a wasteful retry cycle). Applies to
          // YouTube too — strictly more patient, never less.
          await dyn.setProperty('stream-lavf-o', 'timeout=15000000');
        } catch (_) {}
      }
    } catch (_) {}
    // Crash-surviving trail: mpv logs to disk continuously and Dart
    // appends one line per native op — both outlive a segfault,
    // unlike stdout. All best-effort; never blocks startup.
    try {
      final trailDir = Directory(
          '${Directory.systemTemp.path}${Platform.pathSeparator}lastwave');
      trailDir.createSync(recursive: true);
      _crumbPath =
          '${trailDir.path}${Platform.pathSeparator}mpv-ops.log';
      try {
        File(_crumbPath!).writeAsStringSync(
            '--- player created ${DateTime.now().toIso8601String()} ---\n',
            flush: true);
      } catch (_) {}
      try {
        final dyn = created.platform as dynamic;
        await dyn.setProperty('log-file',
            '${trailDir.path}${Platform.pathSeparator}mpv.log');
      } catch (_) {}
    } catch (_) {}
    final p = _player!;
    _subs.addAll([
      p.stream.playing.listen((v) {
        state = state.copyWith(isPlaying: v);
        _onPlayingChanged(v);
      }),
      p.stream.buffering.listen((v) {
        if (state.error != null) return;
        state = state.copyWith(isBuffering: _resolving || v);
      }),
      p.stream.position.listen((v) {
        _maybeLogFirstAudio(v);
        if (_resolving || state.error != null) return;
        if (state.position == v) return;
        final now = DateTime.now();
        if (now.difference(_lastPositionEmit).inMilliseconds < 100) {
          return;
        }
        _lastPositionEmit = now;
        // Gated to 10Hz: identical scrobble accuracy (wall-clock delta),
        // prefetch is once-per-track. Saves 60Hz DateTime+prefs wakes.
        _tickScrobble(v);
        _maybePrefetchFromPosition(v);
        state = state.copyWith(position: v);
      }),
      p.stream.buffer.listen((v) {
        if (_resolving || state.error != null) return;
        if (state.buffered == v) return;
        final now = DateTime.now();
        // Always land the completed value so the buffered bar can never
        // stick one gate behind at 100%; intermediate chunks stay 10Hz.
        final complete =
            state.duration > Duration.zero && v >= state.duration;
        if (!complete &&
            now.difference(_lastBufferedEmit).inMilliseconds < 100) {
          return;
        }
        _lastBufferedEmit = now;
        state = state.copyWith(buffered: v);
      }),
      p.stream.duration.listen((v) {
        if (_resolving || state.error != null) return;
        state = state.copyWith(duration: v);
        // Keep scrobble duration in sync with the track that owns the
        // current window — not the next track that has already been
        // written to state during resolve.
        if (_scrobbleTrack != null &&
            _scrobbleTrack!.queueKey == state.current?.queueKey) {
          _scrobbleDurationSec = v.inSeconds;
        }
      }),
      p.stream.volume.listen((v) {
        if (_lockSoftwareVolume) return;
        state = state.copyWith(volume: (v / 100).clamp(0.0, 1.0));
      }),
      p.stream.completed.listen((done) {
        if (done) _onTrackCompleted();
      }),
      p.stream.log.listen((PlayerLog l) {
        if (kDebugMode) {
          _mpvLogTail.add(l);
          if (_mpvLogTail.length > _mpvLogTailMax) {
            _mpvLogTail.removeRange(0, _mpvLogTail.length - _mpvLogTailMax);
          }
        }
      }),
      p.stream.error.listen((e) {
        if (kDebugMode) {
          debugPrint('LastWave-Player: mpv error: $e');
          _dumpMpvLog('p.stream.error');
        }
        unawaited(_onPlayerError());
      }),
      p.stream.audioParams.listen((_) {
        unawaited(_refreshAoFormat());
      }),
    ]);
    await restoreSession();
  }

  /// Ordered teardown for app quit: awaits the queued mpv stop/dispose
  /// so no texture callbacks fire after the Flutter view is destroyed
  /// (release-only `flutter_windows+1e220` crash on close).
  Future<void> disposePlayer() async {
    // Flush any past-threshold window before tearing down (manual pause/
    // app close would otherwise leave it only as “Scrobbling now”).
    _flushScrobble(completed: false);
    _resolveGeneration++;
    _resolving = false;
    _resolvingIndex = -1;
    _activeQueueKey = '';
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _sleepTimer?.cancel();
    _persistThrottle?.cancel();
    // Queue teardown behind any in-flight open: disposing mid-loadfile
    // is the same heap race as overlapping stop/open (Alt+F4 path).
    // Awaited (not fire-and-forget): the quit path must not destroy
    // the native window while the mpv dispose is still in flight.
    final player = _player;
    _player = null;
    if (player != null) {
      try {
        await _serializedMpv(() async {
          try {
            await player.stop();
          } catch (_) {}
          try {
            await player.dispose();
          } catch (_) {}
        }).timeout(const Duration(seconds: 2), onTimeout: () {});
      } catch (_) {}
    }
  }

  // -- queue API ---------------------------------------------------------------

  Future<void> play(
    PlayableTrack track, {
    String sourceLabel = '',
    bool startRadio = false,
  }) async {
    await playQueue([track], 0,
        sourceLabel: sourceLabel, endlessRadio: startRadio);
  }

  Future<void> playQueue(
    List<PlayableTrack> tracks,
    int startIndex, {
    String sourceLabel = '',
    bool startShuffled = false,
    bool endlessRadio = false,
  }) async {
    await ensurePlayer();
    if (tracks.isEmpty) return;
    var index = startIndex.clamp(0, tracks.length - 1);
    var queue = List<PlayableTrack>.of(tracks);
    var shuffle = state.shuffleEnabled;
    if (startShuffled) {
      shuffle = true;
      queue = List.of(tracks)..shuffle();
      index = queue.indexWhere(
          (t) => t.mediaId == tracks[startIndex].mediaId);
      if (index < 0) index = 0;
    }
    _endlessRadio = endlessRadio;
    _radioSeeds.clear();
    _unavailable.clear();
    _losslessBypass.clear();
    _prefetchSeedKey = '';
    _rebuildShuffleOrder(queue.length, index);
    state = state.copyWith(
      queue: queue,
      currentIndex: index,
      current: queue[index],
      sourceLabel: sourceLabel,
      shuffleEnabled: shuffle,
      isBuffering: true,
      clearError: true,
      position: Duration.zero,
      duration: Duration.zero,
    );
    await _resolveAndOpen(index);
  }

  Future<void> playNext(PlayableTrack track) async {
    final queue = List<PlayableTrack>.of(state.queue);
    final at =
        state.currentIndex >= 0 ? state.currentIndex + 1 : queue.length;
    queue.insert(at, track);
    _rebuildShuffleOrder(queue.length, state.currentIndex);
    state = state.copyWith(queue: queue);
    _schedulePersist();
    _prefetchNeighbors();
  }

  Future<void> addToQueue(PlayableTrack track) async {
    final queue = List<PlayableTrack>.of(state.queue)..add(track);
    _rebuildShuffleOrder(queue.length, state.currentIndex);
    state = state.copyWith(queue: queue);
    _schedulePersist();
    _prefetchNeighbors();
  }

  Future<void> removeAt(int index) async {
    final queue = List<PlayableTrack>.of(state.queue);
    if (index < 0 || index >= queue.length) return;
    queue.removeAt(index);
    var currentIndex = state.currentIndex;
    if (index < currentIndex) {
      currentIndex--;
    } else if (index == currentIndex) {
      if (queue.isEmpty) {
        await stopAndClear();
        return;
      }
      currentIndex = currentIndex.clamp(0, queue.length - 1);
      state = state.copyWith(
          queue: queue, currentIndex: currentIndex, current: queue[currentIndex]);
      await _resolveAndOpen(currentIndex);
      return;
    }
    _rebuildShuffleOrder(queue.length, currentIndex);
    state = state.copyWith(queue: queue, currentIndex: currentIndex);
    _schedulePersist();
  }

  Future<void> clearUpcoming() async {
    if (state.currentIndex < 0) return;
    final queue = state.queue.sublist(0, state.currentIndex + 1);
    state = state.copyWith(queue: queue);
    _schedulePersist();
  }

  /// Reorder queue via drag: updates actual playback queue and keeps
  /// current index pointing at the same track. No re-resolve.
  Future<void> moveInQueue(int oldIndex, int newIndex) async {
    final queue = List<PlayableTrack>.of(state.queue);
    if (oldIndex < 0 ||
        oldIndex >= queue.length ||
        newIndex < 0 ||
        newIndex > queue.length) {
      return;
    }
    if (oldIndex == newIndex ||
        oldIndex == newIndex - 1) {
      return;
    }
    final current = state.current;
    final item = queue.removeAt(oldIndex);
    var adjusted = newIndex;
    if (newIndex > oldIndex) adjusted -= 1;
    queue.insert(adjusted.clamp(0, queue.length), item);
    var currentIndex = current == null
        ? state.currentIndex
        : queue.indexWhere((t) => t.queueKey == current.queueKey);
    if (currentIndex < 0) currentIndex = state.currentIndex.clamp(0, queue.length - 1);
    _rebuildShuffleOrder(queue.length, currentIndex);
    state = state.copyWith(
      queue: queue,
      currentIndex: currentIndex,
      current: queue.isEmpty ? null : queue[currentIndex.clamp(0, queue.length - 1)],
    );
    _schedulePersist();
  }

  // -- transport ---------------------------------------------------------------

  Future<void> toggle() async {
    await ensurePlayer();
    if (state.error != null) {
      await retry();
      return;
    }
    // Session restore loads queue/current but no Media in mpv — playOrPause
    // on an empty player is a no-op (user hits play and nothing happens;
    // next/prev/new track work because they re-resolve). Detect that case
    // and open the restored track instead.
    if (state.current != null && state.stream == null) {
      final resumeAt = state.position;
      await _resolveAndOpen(state.currentIndex);
      if (resumeAt > Duration.zero) {
        // Best-effort: resume where the session left off.
        await seek(resumeAt);
      }
      return;
    }
    await _player?.playOrPause();
  }

  Future<void> playResume() async {
    await ensurePlayer();
    if (state.current != null && state.stream == null) {
      final resumeAt = state.position;
      await _resolveAndOpen(state.currentIndex);
      if (resumeAt > Duration.zero) {
        await seek(resumeAt);
      }
      return;
    }
    await _player?.play();
  }

  Future<void> pause() async {
    await _player?.pause();
    _schedulePersist();
  }

  Future<void> seek(Duration position) async {
    await _player?.seek(position);
    state = state.copyWith(position: position);
  }

  Future<void> setVolume(double volume, {bool software = true}) async {
    final v = volume.clamp(0.0, 1.0);
    state = state.copyWith(volume: v);
    if (!software || _lockSoftwareVolume) {
      await _player?.setVolume(100);
      return;
    }
    await _player?.setVolume(v * 100);
  }

  /// Apply WASAPI exclusive / device to the existing libmpv player.
  /// PCM still flows through media_kit; this only sets mpv AO properties.
  Future<void> configureWasapi({
    required bool exclusive,
    String mpvDevice = 'auto',
    bool lockSoftwareVolume = false,
    PcmFormat? outputFormat,
  }) async {
    await ensurePlayer();
    if (!Platform.isWindows) {
      _lockSoftwareVolume = false;
      exclusiveApplied = false;
      wasapiError = null;
      _forcedAoFormat = null;
      unawaited(_refreshAoFormat());
      return;
    }
    _lockSoftwareVolume = lockSoftwareVolume;
    final player = _player;
    if (player == null) {
      exclusiveApplied = false;
      wasapiError = 'Player unavailable';
      return;
    }
    exclusiveApplied = false;
    wasapiError = null;
    _forcedAoFormat =
        exclusive && outputFormat != null ? mpvSampleFormat(outputFormat.bitDepth) : null;
    _crumb('configureWasapi exclusive=$exclusive device=$mpvDevice');
    await _serializedMpv(() async {
      final dyn = player.platform as dynamic;
      try {
        await dyn.setProperty('ao', 'wasapi');
      } catch (_) {}
      try {
        await dyn.setProperty('audio-exclusive', exclusive ? 'yes' : 'no');
      } catch (e) {
        if (exclusive) {
          wasapiError = 'Exclusive Mode denied: $e';
        }
      }
      // weak = keep the device open only when the next file matches.
      // yes would resample to hold the old exclusive format open.
      try {
        await dyn.setProperty(
            'gapless-audio', exclusive ? 'weak' : 'yes');
      } catch (_) {}
      // audio-format accepts only real format names — writing 'no'
      // (the old shared-mode default) errors out of mpv on every
      // call and fires a spurious p.stream.error → re-resolve.
      // Skip when unset; mpv keeps its negotiated default.
      final forced = _forcedAoFormat;
      if (forced != null) {
        try {
          await dyn.setProperty('audio-format', forced);
        } catch (e) {
          if (exclusive) {
            wasapiError = 'audio-format failed: $e';
          }
        }
      }
      if (exclusive) {
        try {
          await dyn.setProperty('af', '');
        } catch (_) {}
        try {
          await dyn.setProperty('replaygain', 'no');
        } catch (_) {}
        try {
          await dyn.setProperty('audio-normalize-downmix', 'no');
        } catch (_) {}
      }
      exclusiveApplied = exclusive && wasapiError == null;
      try {
        if (mpvDevice.isEmpty || mpvDevice == 'auto') {
          await player.setAudioDevice(AudioDevice.auto());
        } else {
          await player.setAudioDevice(AudioDevice(mpvDevice, ''));
        }
      } catch (_) {}
      if (lockSoftwareVolume) {
        await player.setVolume(100);
      }
    }).catchError((e) {
      exclusiveApplied = false;
      wasapiError = 'WASAPI init failed: $e';
    });
    if (outputFormat != null && exclusive) {
      state = state.copyWith(
        outputFormat: outputFormat,
        outputIsFloat: false,
      );
    }
    unawaited(_refreshAoFormat());
  }

  Future<void> _refreshAoFormat() async {
    final player = _player;
    if (player == null) return;
    try {
      final dyn = player.platform as dynamic;
      final raw = await dyn.getProperty('audio-out-params') as String? ?? '';
      if (raw.isEmpty) return;
      if (mpvFormatIsFloat(RegExp(r'format=([^\s,}]+)').firstMatch(raw)?.group(1))) {
        final rateMatch = RegExp(r'samplerate=(\d+)').firstMatch(raw);
        final rate = int.tryParse(rateMatch?.group(1) ?? '') ?? 0;
        state = state.copyWith(
          outputIsFloat: true,
          outputFormat: rate > 0
              ? PcmFormat(
                  sampleRateHz: rate,
                  bitDepth: 32,
                  channels: 2,
                )
              : state.outputFormat,
        );
        wasapiLog('AO is float — not bit-perfect');
        return;
      }
      final parsed = pcmFromMpvOutParams(raw, forcedFormat: _forcedAoFormat);
      if (parsed == null) return;
      state = state.copyWith(outputFormat: parsed, outputIsFloat: false);
    } catch (_) {}
  }

  Future<void> next() async {
    final nextIndex = _nextIndex();
    if (nextIndex == null) return;
    state = state.copyWith(
      currentIndex: nextIndex,
      current: state.queue[nextIndex],
      isBuffering: true,
      clearError: true,
      position: Duration.zero,
      duration: Duration.zero,
    );
    await _resolveAndOpen(nextIndex);
  }

  Future<void> previous() async {
    if (state.position > const Duration(seconds: 5)) {
      await seek(Duration.zero);
      return;
    }
    final prevIndex = _prevIndex();
    if (prevIndex == null) {
      await seek(Duration.zero);
      return;
    }
    state = state.copyWith(
      currentIndex: prevIndex,
      current: state.queue[prevIndex],
      isBuffering: true,
      clearError: true,
      position: Duration.zero,
      duration: Duration.zero,
    );
    await _resolveAndOpen(prevIndex);
  }

  Future<void> seekToQueueItem(int index) async {
    if (index < 0 || index >= state.queue.length) return;
    state = state.copyWith(
      currentIndex: index,
      current: state.queue[index],
      isBuffering: true,
      clearError: true,
      position: Duration.zero,
      duration: Duration.zero,
    );
    await _resolveAndOpen(index);
  }

  Future<void> toggleShuffle() async {
    final enabled = !state.shuffleEnabled;
    _rebuildShuffleOrder(state.queue.length, state.currentIndex);
    state = state.copyWith(shuffleEnabled: enabled);
    _schedulePersist();
  }

  Future<void> cycleRepeat() async {
    final next = switch (state.repeatMode) {
      RepeatMode.off => RepeatMode.all,
      RepeatMode.all => RepeatMode.one,
      RepeatMode.one => RepeatMode.off,
    };
    state = state.copyWith(repeatMode: next);
    _schedulePersist();
  }

  Future<void> setSpeed(double speed) async {
    await _player?.setRate(speed);
    state = state.copyWith(speed: speed);
    _schedulePersist();
  }

  Future<void> cycleSpeed() async {
    const steps = [0.75, 1.0, 1.25, 1.5, 2.0];
    var idx = steps.indexWhere((s) => s >= state.speed);
    idx = (idx + 1) % steps.length;
    await setSpeed(steps[idx]);
  }

  void setSleepTimer(Duration? duration) {
    _sleepTimer?.cancel();
    if (duration == null) {
      _sleepDeadline = null;
      state = state.copyWith(clearSleep: true);
      return;
    }
    _sleepDeadline = DateTime.now().add(duration);
    state = state.copyWith(sleepRemaining: duration);
    _sleepTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        final remaining = _sleepDeadline?.difference(DateTime.now());
        if (remaining == null || remaining.isNegative) {
          _sleepTimer?.cancel();
          _sleepDeadline = null;
          state = state.copyWith(clearSleep: true);
          pause();
        } else {
          state = state.copyWith(sleepRemaining: remaining);
        }
      },
    );
  }

  Future<void> retry() async {
    if (state.currentIndex < 0) return;
    state = state.copyWith(clearError: true, isBuffering: true);
    _unavailable.remove(state.current!.queueKey);
    _losslessBypass.remove(state.current!.queueKey);
    _invalidatePlayCache(state.current!);
    await _resolveAndOpen(state.currentIndex, forceRefresh: true);
  }

  Future<void> stopAndClear() async {
    _flushScrobble(completed: false);
    _resolveGeneration++;
    _resolving = false;
    _resolvingIndex = -1;
    _activeQueueKey = '';
    _crumb('stop requested (stopAndClear)');
    try {
      await _serializedMpv(() async {
        await _player?.stop();
      });
    } catch (_) {}
    _lastWasDash = false;
    _endlessRadio = false;
    _sessions.clear();
    _playCache.clear();
    _resolveInflight.clear();
    _prefetchInflight.clear();
    _prefetchSeedKey = '';
    try {
      _lossless.clearStreamCache();
    } catch (_) {}
    state = const PlayerSnapshot(
      shuffleEnabled: false,
      repeatMode: RepeatMode.off,
      speed: 1.0,
    );
  }

  // -- resolution (Limusic fast path) ------------------------------------
  //
  // Local files first, then the preferred lossless tier, then YouTube.
  // Generation and queue identity reject stale results after track changes.

  Future<void> _resolveAndOpen(int index,
      {bool forceYoutube = false,
      bool forceRefresh = false,
      int attempt = 0}) async {
    if (index < 0 || index >= state.queue.length) return;
    // Prevent duplicate resolver requests for the same index.
    if (_resolving &&
        _resolvingIndex == index &&
        _activeQueueKey == state.queue[index].queueKey &&
        attempt == 0 &&
        !forceRefresh &&
        !forceYoutube) {
      return;
    }
    final generation = ++_resolveGeneration;
    _resolving = true;
    _resolvingIndex = index;
    _playbackAttempt = attempt;
    final totalSw = Stopwatch()..start();
    int resolveMs = 0;
    try {
      final track = state.queue[index];
      final wantedQueueKey = track.queueKey;
      _activeQueueKey = wantedQueueKey;
      // Arm the first-audio clock: resolve-start → first playing=true.
      _audioClockStart = DateTime.now();
      _audioClockKey = wantedQueueKey;
      _audioClockGeneration = generation;
      _audioOpenDoneAt = null;
      final cacheKey = _playCacheKey(track, forceYoutube);
      final cached = !forceRefresh ? _playCache.get(cacheKey) : null;
      state = state.copyWith(
        isBuffering: true,
        clearError: true,
        stream: cached,
        clearStream: cached == null,
        position: Duration.zero,
        buffered: Duration.zero,
        duration: Duration.zero,
        bitrateKbps: cached?.bitrateKbps ?? 0,
      );
      if (generation != _resolveGeneration) return;
      if (_unavailable.contains(track.queueKey) && attempt == 0) {
        await _skipUnavailable(index);
        return;
      }
      _beginScrobbleWindow(track);
      _prefetchNeighbors();
      final local = _localStream(track);
      if (local != null) {
        _resolving = false;
        final localOpenSw = Stopwatch()..start();
        await _open(track, local, generation, wantedQueueKey);
        localOpenSw.stop();
        totalSw.stop();
        _logTiming('play key=$wantedQueueKey path=local '
            'mpv_open_ms=${localOpenSw.elapsedMilliseconds} '
            'total_ms=${totalSw.elapsedMilliseconds}');
        return;
      }
      if (cached == null) {
        // Cut audio fast, but serialized: a stop racing an in-flight
        // open corrupts the Windows libmpv heap.
        _crumb('stop requested resolve=$index key=$wantedQueueKey');
        try {
          await _serializedMpv(() async {
            await _player?.stop();
          });
        } catch (_) {}
      }
      final resolveSw = Stopwatch()..start();
      final stream = cached ??
          await _resolveRemote(track,
              forceYoutube: forceYoutube, forceRefresh: forceRefresh);
      resolveSw.stop();
      resolveMs = cached != null ? 0 : resolveSw.elapsedMilliseconds;
      // Stale guard: generation + track identity must still match.
      if (generation != _resolveGeneration) return;
      if (index >= state.queue.length ||
          state.queue[index].queueKey != wantedQueueKey) {
        return;
      }
      if (stream == null) {
        // Retry YouTube-only only when the first pass could have taken
        // the lossless path — otherwise it repeats the identical
        // best-effort search (up to ~15s of spinner for nothing) on
        // tracks that simply have no match yet.
        if (attempt == 0 &&
            !forceYoutube &&
            _wouldTryLossless(track, false)) {
          await _resolveAndOpen(index,
              forceYoutube: true, attempt: 1);
          return;
        }
        _unavailable.add(track.queueKey);
        await _skipUnavailable(index);
        return;
      }
      _resolving = false;
      final openSw = Stopwatch()..start();
      await _open(track, stream, generation, wantedQueueKey);
      openSw.stop();
      totalSw.stop();
      if (generation == _resolveGeneration) {
        _logTiming('play key=$wantedQueueKey path=remote '
            'playcache_hit=${cached != null} '
            'resolve_ms=$resolveMs '
            'mpv_open_ms=${openSw.elapsedMilliseconds} '
            'total_ms=${totalSw.elapsedMilliseconds}');
      }
      if (generation != _resolveGeneration) return;
      _prefetchNeighbors();
      _maybeRefillRadio();
    } catch (_) {
      if (generation != _resolveGeneration) return;
      state = state.copyWith(
        isPlaying: false,
        isBuffering: false,
        clearStream: true,
        error: 'Could not load this track. Press Play to retry.',
      );
    } finally {
      if (generation == _resolveGeneration) {
        _resolving = false;
        _resolvingIndex = -1;
      }
    }
  }

  ResolvedStream? _localStream(PlayableTrack track) {
    String? path;
    if (track.playbackUrl.isNotEmpty &&
        File(track.playbackUrl).existsSync()) {
      path = track.playbackUrl;
    } else {
      path = _downloads.localPathFor(track.title, track.artist);
    }
    if (path == null) return null;
    final ext = path.split('.').last.toLowerCase();
    final isLossless = ext == 'flac' || ext == 'wav';
    return ResolvedStream(
      url: Uri.file(path).toString(),
      mimeType: ext == 'flac'
          ? 'audio/flac'
          : ext == 'mp3'
              ? 'audio/mpeg'
              : 'audio/mp4',
      bitrateKbps: isLossless ? 1411 : 256,
      audioCodec: isLossless ? 'FLAC' : ext.toUpperCase(),
      cacheKey: 'local:${track.queueKey}',
      isLossless: isLossless,
    );
  }

  String _playCacheKey(PlayableTrack track, bool forceYoutube) =>
      '${track.queueKey}|${forceYoutube ? 'yt' : _prefs.losslessQuality}|${_prefs.preferLossless}';

  void _invalidatePlayCache(PlayableTrack track) {
    _playCache.invalidateWhere((key) => key.startsWith('${track.queueKey}|'));
    try {
      _lossless.invalidateStream(title: track.title, artist: track.artist);
    } catch (_) {}
  }

  Future<ResolvedStream?> _resolveRemote(
    PlayableTrack track, {
    bool forceYoutube = false,
    bool forceRefresh = false,
  }) async {
    final cacheKey = _playCacheKey(track, forceYoutube);
    if (!forceRefresh) {
      final hit = _playCache.get(cacheKey);
      if (hit != null) return hit;
      final pending = _resolveInflight[cacheKey];
      if (pending != null) return pending;
    }
    final future = _resolveRemoteUncached(track,
        forceYoutube: forceYoutube, forceRefresh: forceRefresh);
    _resolveInflight[cacheKey] = future;
    try {
      final stream = await future;
      if (stream != null &&
          (stream.isLossless || forceYoutube || !_prefs.preferLossless)) {
        _playCache.put(cacheKey, stream);
      }
      return stream;
    } finally {
      _resolveInflight.remove(cacheKey);
    }
  }

  /// True when a resolve pass for [track] would attempt the lossless
  /// backend before YouTube. Shared by the resolver and the retry
  /// gate below so they never disagree.
  bool _wouldTryLossless(PlayableTrack track, bool forceYoutube) {
    return !forceYoutube &&
        !_losslessBypass.contains(track.queueKey) &&
        _prefs.preferLossless &&
        _prefs.losslessQuality != AudioQualityTiers.youtubeOnly &&
        _lossless.isConfigured &&
        track.artist.isNotEmpty &&
        track.artist.toLowerCase() != 'unknown artist';
  }

  Future<ResolvedStream?> _resolveRemoteUncached(
    PlayableTrack track, {
    bool forceYoutube = false,
    bool forceRefresh = false,
  }) async {
    final allowLossless = _wouldTryLossless(track, forceYoutube);
    final key = track.queueKey;
    if (!allowLossless) {
      final ytOnlySw = Stopwatch()..start();
      final ytOnly = await _resolveYoutube(track, const {},
          forceRefresh: forceRefresh);
      ytOnlySw.stop();
      _logTiming('resolve key=$key path=youtube-only '
          'youtube_ms=${ytOnlySw.elapsedMilliseconds} hit=${ytOnly != null}');
      return ytOnly;
    }
    int losslessMs = 0;
    try {
      final losslessSw = Stopwatch()..start();
      final stream = await _lossless.resolveStream(
        title: track.title,
        artist: track.artist,
        album: track.album,
        preferredQuality: _prefs.losslessQuality,
      );
      losslessSw.stop();
      losslessMs = losslessSw.elapsedMilliseconds;
      if (stream != null) {
        _logTiming('resolve key=$key path=lossless-hit '
            'lossless_ms=$losslessMs');
        return stream;
      }
      // Silent misses are the #1 "why YouTube?" confusion: log the
      // lossless fallthrough in debug so the next report shows which
      // tier failed instead of only the YouTube hit below.
      if (kDebugMode) {
        debugPrint('LastWaveAddon stage=miss '
            'title="${track.title}" artist="${track.artist}" '
            'album="${track.album}" quality=${_prefs.losslessQuality} '
            '-> falling through to YouTube');
      }
    } on AddonQuotaException catch (e) {
      // Daily addon quota spent: tell the UI once, then fall through
      // to YouTube like any other backend miss.
      try {
        _onAddonQuota?.call(e.message);
      } catch (_) {}
    } catch (_) {
      // The backend failed; continue with YouTube for this request.
    }
    final ytSw = Stopwatch()..start();
    final yt = await _resolveYoutube(track, const {},
        forceRefresh: forceRefresh);
    ytSw.stop();
    _logTiming('resolve key=$key path=lossless-miss+youtube '
        'lossless_ms=$losslessMs youtube_ms=${ytSw.elapsedMilliseconds} '
        'hit=${yt != null}');
    return yt;
  }

  Future<ResolvedStream?> _resolveYoutube(
    PlayableTrack track,
    Set<String> excluded, {
    bool forceRefresh = false,
  }) async {
    // Instant playback: a valid videoId goes straight to the resolver
    // (disk/memory cache or one fast InnerTube client). No search,
    // no lyrics/artwork/Last.fm/recommendation gating.
    if (track.videoId.isNotEmpty &&
        !excluded.contains(track.videoId)) {
      try {
        final directSw = Stopwatch()..start();
        final stream = await _tube.resolveAudioStream(track.videoId,
            forceRefresh: forceRefresh);
        directSw.stop();
        _logTiming('youtube key=${track.queueKey} path=direct-videoId '
            'stream_ms=${directSw.elapsedMilliseconds} '
            'hit=${stream != null}');
        if (stream != null) {
          _rememberWatchtime(track.videoId, stream);
          return stream;
        }
      } catch (_) {}
      // Real failure (e.g. 403): drop the cached URL and try one
      // limited re-match below instead of fanning out.
      try {
        _tube.reportPlaybackFailure(track.videoId);
      } catch (_) {}
      excluded = {...excluded, track.videoId};
    }
    for (var attempt = 0; attempt < 2; attempt++) {
      int matchMs = 0;
      try {
        // Best-effort: strict → primary-artist (collab billing like
        // "A; B; C") → title-only. Home feed tracks carry Last.fm
        // billing that fails the strict artist gate on songs that
        // plainly exist on YouTube. Budgets live inside (5s/tier);
        // the outer cap is a safety net only.
        final matchSw = Stopwatch()..start();
        final match = await _tube
            .findBestEffortMatchOrNull(
              track.title,
              track.artist,
              excludedVideoIds: excluded,
            )
            .timeout(const Duration(seconds: 20), onTimeout: () => null);
        matchSw.stop();
        matchMs = matchSw.elapsedMilliseconds;
        final videoId = match?.videoId;
        if (videoId == null || videoId.isEmpty) {
          _logTiming('youtube key=${track.queueKey} attempt=$attempt '
              'match_ms=$matchMs result=no-match');
          return null;
        }
        if (excluded.contains(videoId)) continue;
        // Persist the match so the next play is instant.
        _adoptVideoId(track, videoId, match!);
        final streamSw = Stopwatch()..start();
        final stream = await _tube.resolveAudioStream(videoId,
            forceRefresh: forceRefresh && attempt == 0);
        streamSw.stop();
        _logTiming('youtube key=${track.queueKey} attempt=$attempt '
            'match_ms=$matchMs stream_ms=${streamSw.elapsedMilliseconds} '
            'hit=${stream != null}');
        if (stream != null) {
          _rememberWatchtime(videoId, stream);
          return stream;
        }
        _tube.reportPlaybackFailure(videoId);
        excluded = {...excluded, videoId};
      } catch (_) {}
    }
    return null;
  }

  /// Write a newly matched videoId back into the queue entry so future
  /// plays hit the instant path without another search.
  void _adoptVideoId(
      PlayableTrack track, String videoId, YouTubeMusicTrack match) {
    try {
      final idx = state.queue
          .indexWhere((t) => t.mediaId == track.mediaId);
      if (idx < 0) return;
      final cur = state.queue[idx];
      if (cur.videoId.isNotEmpty) return;
      final updated = cur.copyWith(
        videoId: videoId,
        artworkUrl: OfficialArtworkService.isOfficialArtwork(cur.artworkUrl)
            ? cur.artworkUrl
            : (match.artworkUrl.isNotEmpty ? match.artworkUrl : cur.artworkUrl),
      );
      final queue = List<PlayableTrack>.of(state.queue);
      queue[idx] = updated;
      state = state.copyWith(
        queue: queue,
        current: idx == state.currentIndex ? updated : state.current,
      );
    } catch (_) {}
  }

  /// Warm previous, next, and next+1 stream URLs plus studio artwork.
  /// Does not open mpv and never injects a playlist item.
  void _prefetchNeighbors() {
    try {
      final indices = <int>{};
      void add(int? i) {
        if (i != null && i != state.currentIndex) indices.add(i);
      }

      add(_neighborIndex(1));
      add(_neighborIndex(-1));
      add(_neighborIndex(2));
      for (final i in indices) {
        unawaited(_prefetchIndex(i));
      }
    } catch (_) {}
  }

  int? _neighborIndex(int delta) {
    final queue = state.queue;
    if (queue.isEmpty || state.currentIndex < 0 || delta == 0) return null;
    if (state.shuffleEnabled && _shuffleOrder.isNotEmpty) {
      final pos = _shuffleOrder.indexOf(state.currentIndex);
      if (pos < 0) return null;
      final next = pos + delta;
      if (next >= 0 && next < _shuffleOrder.length) {
        return _shuffleOrder[next];
      }
      if (state.repeatMode == RepeatMode.all && queue.isNotEmpty) {
        return delta > 0 ? _shuffleOrder.first : _shuffleOrder.last;
      }
      return null;
    }
    final i = state.currentIndex + delta;
    if (i >= 0 && i < queue.length) return i;
    if (state.repeatMode == RepeatMode.all && queue.isNotEmpty) {
      return delta > 0 ? 0 : queue.length - 1;
    }
    return null;
  }

  Future<void> _prefetchIndex(int index) async {
    if (index < 0 || index >= state.queue.length) return;
    final track = state.queue[index];
    if (_unavailable.contains(track.queueKey)) return;
    if (_localStream(track) != null) {
      _prefetchArtwork(track);
      return;
    }
    final cacheKey = _playCacheKey(track, false);
    if (_playCache.get(cacheKey) != null) {
      _prefetchArtwork(track);
      if (track.videoId.isNotEmpty) {
        _tube.prefetchNextTrack(track.videoId);
      }
      return;
    }
    if (!_prefetchInflight.add(track.queueKey)) return;
    try {
      final stream = await _resolveRemote(track);
      if (stream != null && stream.artworkUrl.isNotEmpty) {
        OfficialArtworkService.instance.rememberTrack(
          title: track.title,
          artist: track.artist,
          artworkUrl: stream.artworkUrl,
          album: stream.albumTitle.isNotEmpty ? stream.albumTitle : track.album,
        );
      }
      _prefetchArtwork(track);
    } catch (_) {
    } finally {
      _prefetchInflight.remove(track.queueKey);
    }
  }

  void _prefetchArtwork(PlayableTrack track) {
    if (OfficialArtworkService.isOfficialArtwork(track.artworkUrl)) return;
    unawaited(_artworkService
        .resolveOfficialArtwork(
      title: track.title,
      artist: track.artist,
      album: track.album,
    )
        .then((_) {}, onError: (_) {}));
  }

  void _maybePrefetchFromPosition(Duration position) {
    final duration = state.duration;
    if (duration.inSeconds < 8) return;
    final remaining = duration - position;
    if (position.inMilliseconds < duration.inMilliseconds * 0.55 &&
        remaining > const Duration(seconds: 28)) {
      return;
    }
    final key = state.current?.queueKey ?? '';
    if (key.isEmpty || key == _prefetchSeedKey) return;
    _prefetchSeedKey = key;
    _prefetchNeighbors();
  }

  Future<void> _open(PlayableTrack track, ResolvedStream stream,
      int generation, String wantedQueueKey) async {
    // Stale resolver callbacks must never replace the active track.
    if (generation != _resolveGeneration) return;
    if (_activeQueueKey != wantedQueueKey) return;
    if (state.current?.queueKey != wantedQueueKey &&
        (state.currentIndex < 0 ||
            state.currentIndex >= state.queue.length ||
            state.queue[state.currentIndex].queueKey !=
                wantedQueueKey)) {
      return;
    }

    // Upgrade track artwork if lossless stream supplied official studio artwork
    var effectiveTrack = track;
    if (stream.artworkUrl.isNotEmpty && stream.artworkUrl != track.artworkUrl) {
      effectiveTrack = effectiveTrack.copyWith(
        artworkUrl: stream.artworkUrl,
        album: stream.albumTitle.isNotEmpty && effectiveTrack.album.isEmpty
            ? stream.albumTitle
            : effectiveTrack.album,
      );
      final idx = state.queue.indexWhere((t) => t.queueKey == wantedQueueKey);
      if (idx >= 0) {
        final q = List<PlayableTrack>.of(state.queue);
        q[idx] = effectiveTrack;
        state = state.copyWith(
          queue: q,
          current: idx == state.currentIndex ? effectiveTrack : state.current,
        );
      }
    }
    if (OfficialArtworkService.isOfficialArtwork(effectiveTrack.artworkUrl)) {
      OfficialArtworkService.instance.rememberTrack(
        title: effectiveTrack.title,
        artist: effectiveTrack.artist,
        artworkUrl: effectiveTrack.artworkUrl,
        album: effectiveTrack.album,
      );
    }

    state = state.copyWith(
      current: state.currentIndex >= 0 &&
              state.currentIndex < state.queue.length &&
              state.queue[state.currentIndex].queueKey == wantedQueueKey
          ? effectiveTrack
          : state.current,
      stream: stream,
      bitrateKbps: stream.bitrateKbps,
      isBuffering: true,
      clearError: true,
    );

    // Fetch official studio artwork in the background if current artwork is not official
    if (!OfficialArtworkService.isOfficialArtwork(effectiveTrack.artworkUrl)) {
      _resolveOfficialArtworkInBackground(effectiveTrack, wantedQueueKey, generation);
    }

    try {
      // Pre-open breadcrumb: runs BEFORE the native call, so it
      // survives a segfault. Shape only (kind/ext/mime) — never URLs.
      final rawUrl = stream.url;
      final kind = rawUrl.startsWith('http')
          ? 'remote'
          : (rawUrl.startsWith('file:') ||
                  rawUrl.contains(':\\') ||
                  rawUrl.startsWith('/'))
              ? 'local-file'
              : 'other';
      final ext = rawUrl.split('?').first.split('.').last;
      _crumb('open key=$wantedQueueKey kind=$kind ext=$ext '
          'mime=${stream.mimeType} lossless=${stream.isLossless} '
          'cache=${stream.cacheKey}');
      // Materialized manifests arrive as raw `C:\…` paths; mpv opens
      // them, but the backslash form poisons the DASH demux handoff
      // on Windows — always use a file:// URI (mirrors _localStream).
      var playUrl = rawUrl;
      if (kind == 'local-file' && !rawUrl.startsWith('file:')) {
        try {
          playUrl = Uri.file(rawUrl).toString();
          _crumb('open key=$wantedQueueKey file-uri=yes');
        } catch (_) {}
      }
      final wasDash = _lastWasDash;
      final isDash = stream.mimeType.contains('dash');
      int stopMs = 0;
      int loadMs = 0;
      await _serializedMpv(() async {
        // Always tear down before loading: opening over a live stream
        // (or racing its teardown) corrupts the Windows libmpv heap —
        // first track plays, the next dies in ntdll.
        final stopSw = Stopwatch()..start();
        try {
          await _player?.stop();
        } catch (_) {}
        stopSw.stop();
        stopMs = stopSw.elapsedMilliseconds;
        if (generation != _resolveGeneration) return;
        if (_activeQueueKey != wantedQueueKey) return;
        if (wasDash) {
          // Proven crash window (mpv.log): the previous DASH demuxer
          // is still unwinding when loadfile arrives — the second
          // manifest dies mid-probe ~10ms after open. Bounded grace.
          _crumb('open key=$wantedQueueKey dash-grace');
          await Future.delayed(const Duration(milliseconds: 500));
          if (generation != _resolveGeneration) return;
          if (_activeQueueKey != wantedQueueKey) return;
        }
        // Stamp open-issue BEFORE the call, not after it returns:
        // mpv events (pause=no) and the open() reply travel on separate
        // channels, so playing/position can beat the reply — a stamp
        // taken after `await open()` is fundamentally racy (-1).
        if (generation == _resolveGeneration &&
            _activeQueueKey == wantedQueueKey) {
          _audioOpenDoneAt = DateTime.now();
        }
        final loadSw = Stopwatch()..start();
        await _player?.open(
          Media(playUrl, httpHeaders: stream.requestHeaders),
          play: true,
        );
        loadSw.stop();
        loadMs = loadSw.elapsedMilliseconds;
        _lastWasDash = isDash;
      });
      _logTiming('mpv key=$wantedQueueKey kind=$kind '
          'stop_ms=$stopMs load_ms=$loadMs dash_grace=${wasDash ? 500 : 0}');
      if (generation != _resolveGeneration) return;
      if (_activeQueueKey != wantedQueueKey) return;
      if (state.speed != 1.0) {
        await _player?.setRate(state.speed);
      }
    } catch (e, st) {
      if (kDebugMode) {
        final host = Uri.tryParse(stream.url)?.host ?? '?';
        debugPrint(
            'LastWave-Player: open failed ($host, cache=${stream.cacheKey}): $e');
        debugPrint('LastWave-Player: open stack: $st');
        _dumpMpvLog('_open.exception');
      }
      if (generation != _resolveGeneration) return;
      await _onPlayerError();
    }
  }

  void _dumpMpvLog(String trigger) {
    if (!kDebugMode) return;
    debugPrint('LastWave-Player: mpv log tail ($trigger):');
    for (final l in _mpvLogTail) {
      debugPrint('  [${l.prefix}/${l.level}] ${l.text}');
    }
    _mpvLogTail.clear();
  }

  void _resolveOfficialArtworkInBackground(
      PlayableTrack track, String wantedQueueKey, int generation) {
    unawaited(_artworkService
        .resolveOfficialArtwork(
      title: track.title,
      artist: track.artist,
      album: track.album,
    )
        .then((result) {
      if (result == null || result.artworkUrl.isEmpty) return;
      if (generation != _resolveGeneration) return;
      if (_activeQueueKey != wantedQueueKey) return;

      final idx = state.queue.indexWhere((t) => t.queueKey == wantedQueueKey);
      if (idx < 0) return;

      final cur = state.queue[idx];
      final updated = cur.copyWith(
        artworkUrl: result.artworkUrl,
        album: cur.album.isEmpty && result.albumTitle.isNotEmpty
            ? result.albumTitle
            : cur.album,
      );

      final q = List<PlayableTrack>.of(state.queue);
      q[idx] = updated;
      state = state.copyWith(
        queue: q,
        current: idx == state.currentIndex ? updated : state.current,
      );
      _schedulePersist();
    }, onError: (_) {}));
  }

  Future<void> _onPlayerError() async {
    final track = state.current;
    final generation = _resolveGeneration;
    if (track == null || _resolving || state.error != null ||
        _activeQueueKey != track.queueKey ||
        _failedGeneration == generation) {
      return;
    }
    _failedGeneration = generation;
    _invalidatePlayCache(track);
    final streamKey = state.stream?.cacheKey ?? '';
    if (streamKey.startsWith('lossless:') || streamKey.startsWith('tidal:')) {
      await _resolveAndOpen(state.currentIndex, forceYoutube: true);
      return;
    }
    if (track.videoId.isNotEmpty) {
      _tube.reportPlaybackFailure(track.videoId);
    }
    if (streamKey.startsWith('addon:') && _playbackAttempt == 0) {
      // Addon streams fail transiently (slow mint, segment blip) and
      // a manual replay usually plays lossless — so retry the SAME
      // tier once (fresh mint, settled session) before YouTube.
      // Terminates: the retry runs at attempt 1, which falls through.
      _crumb('retry same-tier key=${track.queueKey}');
      await _resolveAndOpen(state.currentIndex,
          forceRefresh: true, attempt: 1);
      return;
    }
    if (_playbackAttempt <= 1) {
      _crumb('retry youtube key=${track.queueKey}');
      await _resolveAndOpen(state.currentIndex,
          forceYoutube: true, forceRefresh: true, attempt: 2);
      return;
    }
    _unavailable.add(track.queueKey);
    await _skipUnavailable(state.currentIndex);
  }
  Future<void> _skipUnavailable(int failedIndex) async {
    final nextIndex = _nextIndex(skipUnavailable: true);
    if (nextIndex == null) {
      state = state.copyWith(
        isBuffering: false,
        isPlaying: false,
        error: 'Track unavailable — end of playable queue.',
      );
      return;
    }
    state = state.copyWith(
      currentIndex: nextIndex,
      current: state.queue[nextIndex],
      isBuffering: true,
      clearError: true,
      position: Duration.zero,
      duration: Duration.zero,
    );
    await _resolveAndOpen(nextIndex);
  }

  void _onTrackCompleted() {
    if (_resolving || state.error != null) return;
    _flushScrobble(completed: true);
    if (state.duration - state.position > const Duration(seconds: 10)) {
      // mpv reported clean EOF far from the known end: a truncated
      // stream, not a finished song (addon live-stream closed early:
      // Titli died at ~71s of 147s with success reason 2 and the queue
      // skipped ahead). Run the error path instead of advancing — for
      // addon tracks that replays the now-complete file (same-tier
      // retry), otherwise it falls through to YouTube. Repeat-one is
      // covered too: its replay below would loop the broken prefix.
      _crumb('premature eof pos=${state.position.inSeconds}s '
          'dur=${state.duration.inSeconds}s key=${state.current?.queueKey}');
      unawaited(_onPlayerError());
      return;
    }
    if (state.repeatMode == RepeatMode.one) {
      final loopTrack = state.current;
      seek(Duration.zero);
      playResume();
      if (loopTrack != null) {
        // Re-arm a fresh scrobble window for the looped play.
        _beginScrobbleWindow(loopTrack);
      }
      return;
    }
    final nextIndex = _nextIndex();
    if (nextIndex == null) {
      state = state.copyWith(isPlaying: false);
      _schedulePersist();
      return;
    }
    state = state.copyWith(
      currentIndex: nextIndex,
      current: state.queue[nextIndex],
      isBuffering: true,
      position: Duration.zero,
      duration: Duration.zero,
    );
    _resolveAndOpen(nextIndex);
  }

  int? _nextIndex({bool skipUnavailable = false}) {
    final queue = state.queue;
    if (queue.isEmpty || state.currentIndex < 0) return null;
    if (state.shuffleEnabled && _shuffleOrder.isNotEmpty) {
      final pos = _shuffleOrder.indexOf(state.currentIndex);
      if (pos >= 0 && pos + 1 < _shuffleOrder.length) {
        final candidate = _shuffleOrder[pos + 1];
        if (skipUnavailable &&
            _unavailable.contains(queue[candidate].queueKey)) {
          // walk forward past unavailable
          for (var i = pos + 1; i < _shuffleOrder.length; i++) {
            if (!_unavailable
                .contains(queue[_shuffleOrder[i]].queueKey)) {
              return _shuffleOrder[i];
            }
          }
          return _wrapIndex(skipUnavailable: skipUnavailable);
        }
        return candidate;
      }
      return _wrapIndex(skipUnavailable: skipUnavailable);
    }
    final next = state.currentIndex + 1;
    if (next < queue.length) {
      if (skipUnavailable &&
          _unavailable.contains(queue[next].queueKey)) {
        for (var i = next; i < queue.length; i++) {
          if (!_unavailable.contains(queue[i].queueKey)) return i;
        }
        return _wrapIndex(skipUnavailable: skipUnavailable);
      }
      return next;
    }
    return _wrapIndex(skipUnavailable: skipUnavailable);
  }

  int? _wrapIndex({bool skipUnavailable = false}) {
    if (state.repeatMode != RepeatMode.all) return null;
    final order = state.shuffleEnabled && _shuffleOrder.isNotEmpty
        ? _shuffleOrder
        : List<int>.generate(state.queue.length, (index) => index);
    for (final index in order) {
      if (!skipUnavailable ||
          !_unavailable.contains(state.queue[index].queueKey)) {
        return index;
      }
    }
    return null;
  }
  int? _prevIndex() {
    if (state.shuffleEnabled && _shuffleOrder.isNotEmpty) {
      final pos = _shuffleOrder.indexOf(state.currentIndex);
      if (pos > 0) return _shuffleOrder[pos - 1];
      return null;
    }
    if (state.currentIndex > 0) return state.currentIndex - 1;
    return null;
  }

  void _rebuildShuffleOrder(int length, int currentIndex) {
    _shuffleOrder =
        List<int>.generate(length, (i) => i)..shuffle();
    if (currentIndex >= 0 && currentIndex < length) {
      _shuffleOrder.remove(currentIndex);
      _shuffleOrder.insert(0, currentIndex);
    }
  }

  // -- endless radio ---------------------------------------------------------------

  Future<void> _maybeRefillRadio() async {
    if (!_endlessRadio) return;
    final remaining = state.queue.length - state.currentIndex - 1;
    if (remaining > 6) return;
    final seed = state.current;
    if (seed == null || _radioSeeds.contains(seed.mediaId)) return;
    _radioSeeds.add(seed.mediaId);
    try {
      final videoId = seed.videoId.isNotEmpty
          ? seed.videoId
          : (await _tube.findBestMatchOrNull(seed.title, seed.artist))
              ?.videoId;
      if (videoId == null) return;
      final related =
          await _tube.fetchRelatedSongs(videoId, limit: 25);
      final current = state.queue;
      final fresh = related
          .where((t) =>
              !_isDisallowedRadioTitle(t.title) &&
              !_isRadioDuplicate(t, current) &&
              !_radioSeeds.contains(t.videoId))
          .take(10)
          .map((t) => PlayableTrack(
                title: t.title,
                artist: t.artist,
                album: t.album,
                artworkUrl: t.artworkUrl,
                videoId: t.videoId,
              ))
          .toList();
      if (fresh.isEmpty) return;
      final queue = [...state.queue, ...fresh];
      _rebuildShuffleOrder(queue.length, state.currentIndex);
      state = state.copyWith(queue: queue);
      _schedulePersist();
    } catch (_) {}
  }

  bool _isDisallowedRadioTitle(String title) {
    final t = title.toLowerCase();
    return t.contains('mashup') ||
        t.contains('jukebox') ||
        t.contains('megamix') ||
        t.contains('nonstop') ||
        t.contains('all songs') ||
        t.contains('compilation');
  }

  /// Radio duplicate check with fuzzy matching: exact lowercase keys
  /// miss artist variants ("X - Topic", feat. credits) and title
  /// suffixes, which then play the same song twice in a row. Same
  /// 85/50 thresholds as the library matching in `fillMissingMetadata`.
  bool _isRadioDuplicate(
      YouTubeMusicTrack t, List<PlayableTrack> queue) {
    final key =
        '${t.title.toLowerCase()}|${t.artist.toLowerCase()}';
    final base = InnerTubeMusicApi.baseTitle(t.title);
    for (final q in queue) {
      if (q.queueKey == key) return true;
      if (InnerTubeMusicApi.similarity(
              InnerTubeMusicApi.baseTitle(q.title), base) <
          85) {
        continue;
      }
      final qa = q.artist.toLowerCase();
      final ta = t.artist.toLowerCase();
      if (qa.isNotEmpty &&
          ta.isNotEmpty &&
          (qa.contains(ta) ||
              ta.contains(qa) ||
              InnerTubeMusicApi.similarity(qa, ta) >= 50)) {
        return true;
      }
    }
    return false;
  }

  // -- scrobbling ---------------------------------------------------------------

  void _onPlayingChanged(bool playing) {
    _lastTick = playing ? DateTime.now() : null;
    if (!playing) {
      _schedulePersist();
    } else if (state.current != null && !_nowPlayingSent) {
      _sendNowPlaying(state.current!);
    }
  }

  void _beginScrobbleWindow(PlayableTrack track) {
    // On-device play log for the keyless-guest taste algorithm.
    // Runs for every listener (not just Last.fm users); the DB call
    // is a single indexed insert, never on the audio path.
    try {
      _sessions.recordLocalPlay(track.title, track.artist);
    } catch (_) {}
    _flushScrobble(completed: false);
    _scrobbleTrack = track;
    _scrobbleDurationSec = state.duration.inSeconds;
    // If the new track already has a known duration in state (rare,
    // e.g. replay), prefer it; otherwise keep 0 and let the duration
    // listener fill it in.
    if (_scrobbleTrack!.queueKey == state.current?.queueKey) {
      _scrobbleDurationSec = state.duration.inSeconds;
    }
    _scrobbleStartEpoch =
        DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _accumulatedSeconds = 0;
    _scrobbledThisWindow = false;
    _ytHistoryPushedThisWindow = false;
    _ytHistoryCpn = '';
    _nowPlayingSent = false;
    _lastTick = DateTime.now();
    _sendNowPlaying(track);
  }

  void _sendNowPlaying(PlayableTrack track) {
    _nowPlayingSent = true;
    unawaited(_scrobbler.updateNowPlaying(
      artist: track.artist,
      track: track.title,
      album: track.album,
    ));
  }

  /// Push the window's track into the YT Music watch history: a single
  /// ping per window, fired alongside the scrobble so only real
  /// listens sync. Android parity: repeats would file duplicates.
  /// Failures reset the flag so the flush site retries once.
  /// No-throw throughout.
  void _maybePushYtHistory(
      PlayableTrack track, int watchedSeconds,
      {int durationSeconds = 0}) {
    if (_ytHistoryPushedThisWindow) return;
    if (!_prefs.syncYtHistory) return;
    // Claim the window before the async resolve so concurrent sites
    // (threshold + flush) don't double-search. Failures below reset
    // the flag for a retry at the next site.
    _ytHistoryPushedThisWindow = true;
    unawaited(
        _pushYtHistoryAsync(track, watchedSeconds, durationSeconds));
  }

  Future<void> _pushYtHistoryAsync(
      PlayableTrack track, int watchedSeconds, int durationSeconds) async {
    var videoId = _windowVideoId(track);
    if (videoId.isEmpty) {
      // Lossless-first plays may never have matched a YouTube video.
      // Resolve on demand (disk-cached after the first match, so one
      // search per track ever) and adopt it — future plays then take
      // the instant path everywhere, not just history.
      try {
        final match = await _tube
            .findBestMatchOrNull(track.title, track.artist)
            .timeout(const Duration(seconds: 10));
        videoId = match?.videoId ?? '';
        if (videoId.isNotEmpty) _adoptVideoId(track, videoId, match!);
      } catch (_) {
        videoId = '';
      }
    }
    if (videoId.isEmpty) {
      _ytHistoryPushedThisWindow = false;
      return;
    }
    // No usable base yet: fetch one minted under the account
    // (Android parity — anonymous direct-client bases are accepted
    // but filed nowhere). One authenticated player call per window.
    var watchUrl = _watchtimeUrls[videoId] ?? '';
    if (watchUrl.isEmpty) {
      try {
        watchUrl = await _tube
            .fetchAuthenticatedPlaybackUrl(videoId)
            .timeout(const Duration(seconds: 30));
        if (watchUrl.isNotEmpty) {
          _stashWatchtimeUrl(videoId, watchUrl);
        } else if (kDebugMode) {
          debugPrint('YtHistory: authed fetch yielded no base $videoId');
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint(
              'YtHistory: authed fetch threw ${e.runtimeType} $videoId');
        }
        watchUrl = '';
      }
    }
    final ok = await _tube.recordWatchHistory(
        videoId: videoId,
        watchedSeconds: watchedSeconds,
        durationSeconds: durationSeconds,
        cpn: _historyCpn(),
        watchUrl: watchUrl);
    if (!ok) _ytHistoryPushedThisWindow = false;
  }

  /// One client playback nonce per scrobble window.
  String _historyCpn() {
    if (_ytHistoryCpn.isEmpty) {
      _ytHistoryCpn = InnerTubeMusicApi.newWatchCpn();
    }
    return _ytHistoryCpn;
  }

  /// videoId for the window's track. The `_scrobbleTrack` snapshot may
  /// predate match adoption (immutable copy), so prefer the live queue
  /// entry, which `_adoptVideoId` keeps current.
  String _windowVideoId(PlayableTrack track) {
    if (track.videoId.isNotEmpty) return track.videoId;
    try {
      for (final q in state.queue) {
        if (q.queueKey == track.queueKey && q.videoId.isNotEmpty) {
          return q.videoId;
        }
      }
    } catch (_) {}
    return '';
  }

  void _tickScrobble(Duration position) {
    final last = _lastTick;
    final now = DateTime.now();
    if (last != null && state.isPlaying) {
      _accumulatedSeconds +=
          now.difference(last).inMilliseconds / 1000.0;
    }
    _lastTick = now;
    // Eager scrobble at threshold so manual pause still appears in
    // history (Last.fm otherwise expires “Scrobbling now” on pause).
    if (_scrobbleStartEpoch != 0 &&
        !_scrobbledThisWindow &&
        _scrobbleTrack != null &&
        state.isPlaying) {
      final durationSec = _scrobbleDurationSec > 0
          ? _scrobbleDurationSec
          : state.duration.inSeconds;
      if (durationSec > 0) {
        final percent = _prefs.scrobblePercent.clamp(25, 90);
        final threshold =
            (durationSec * percent / 100).round().clamp(30, 240);
        if (_accumulatedSeconds >= threshold) {
          _scrobbledThisWindow = true;
          final t = _scrobbleTrack!;
          unawaited(_scrobbler.scrobble(
            artist: t.artist,
            track: t.title,
            album: t.album,
            timestampSec: _scrobbleStartEpoch,
          ));
          _maybePushYtHistory(t, threshold, durationSeconds: durationSec);
        }
      } else if (_accumulatedSeconds >= 30) {
        // Duration still unknown — fall back to Last.fm’s 30s floor
        // so long tracks don’t wait indefinitely on metadata.
        _scrobbledThisWindow = true;
        final t = _scrobbleTrack!;
        unawaited(_scrobbler.scrobble(
          artist: t.artist,
          track: t.title,
          album: t.album,
          timestampSec: _scrobbleStartEpoch,
        ));
        _maybePushYtHistory(t, 30);
      }
    }
  }

  void _flushScrobble({required bool completed}) {
    final track = _scrobbleTrack ?? state.current;
    if (track == null || _scrobbleStartEpoch == 0) return;
    if (_scrobbledThisWindow) {
      // Already scrobbled eagerly at threshold — just tear down window.
      // Still attempt the YT push: the eager push may have failed and
      // reset its flag (success is a no-op here).
      _maybePushYtHistory(track, _accumulatedSeconds.round(),
          durationSeconds: _scrobbleDurationSec);
      _scrobbleStartEpoch = 0;
      _accumulatedSeconds = 0;
      _scrobbleTrack = null;
      _scrobbleDurationSec = 0;
      _scrobbledThisWindow = false;
      return;
    }
    // Duration belongs to the scrobble window, not necessarily
    // state.duration (which may already be 0 for the next track).
    final durationSec = _scrobbleDurationSec > 0
        ? _scrobbleDurationSec
        : state.duration.inSeconds;
    final percent = _prefs.scrobblePercent.clamp(25, 90);
    // Last.fm rule: min(duration*percent/100, 240) clamped to at least 30s.
    final threshold = durationSec > 0
        ? (durationSec * percent / 100).round().clamp(30, 240)
        : 30;
    final playedEnough = _accumulatedSeconds >= threshold ||
        (completed && _accumulatedSeconds >= 30);
    if (playedEnough) {
      unawaited(_scrobbler.scrobble(
        artist: track.artist,
        track: track.title,
        album: track.album,
        timestampSec: _scrobbleStartEpoch,
      ));
      _maybePushYtHistory(track, _accumulatedSeconds.round(),
          durationSeconds: durationSec);
    }
    _scrobbleStartEpoch = 0;
    _accumulatedSeconds = 0;
    _scrobbleTrack = null;
    _scrobbleDurationSec = 0;
    _scrobbledThisWindow = false;
  }

  // -- persistence ---------------------------------------------------------------

  void _schedulePersist() {
    final now = DateTime.now();
    if (now.difference(_lastPersist) < const Duration(seconds: 2)) {
      _persistThrottle?.cancel();
      _persistThrottle = Timer(
        const Duration(seconds: 2),
        () => _schedulePersist(),
      );
      return;
    }
    _lastPersist = now;
    _persistNow();
  }

  void _persistNow() {
    if (state.queue.isEmpty || state.currentIndex < 0) return;
    final start =
        (state.currentIndex - 50).clamp(0, state.queue.length);
    final end =
        (start + 200).clamp(0, state.queue.length);
    _sessions.save({
      'version': 2,
      'queue': state.queue
          .sublist(start, end)
          .map((t) => t.toJson())
          .toList(),
      'currentIndex': state.currentIndex - start,
      'positionMs': state.position.inMilliseconds,
      'sourceLabel': state.sourceLabel,
      'endless': _endlessRadio,
      'shuffle': state.shuffleEnabled,
      'repeat': state.repeatMode.index,
      'speed': state.speed,
    });
  }

  Future<void> restoreSession() async {
    final data = _sessions.load();
    final queueJson = data['queue'];
    if (queueJson is! List || queueJson.isEmpty) return;
    final queue = queueJson
        .whereType<Map<String, dynamic>>()
        .map(PlayableTrack.fromJson)
        .where((t) => t.title.isNotEmpty)
        .toList();
    if (queue.isEmpty) return;
    final index = ((data['currentIndex'] as num?)?.toInt() ?? 0)
        .clamp(0, queue.length - 1);
    _endlessRadio = data['endless'] == true;
    _rebuildShuffleOrder(queue.length, index);
    state = state.copyWith(
      queue: queue,
      currentIndex: index,
      current: queue[index],
      sourceLabel: data['sourceLabel']?.toString() ?? '',
      shuffleEnabled: data['shuffle'] == true,
      repeatMode: RepeatMode
          .values[((data['repeat'] as num?)?.toInt() ?? 0)
              .clamp(0, RepeatMode.values.length - 1)],
      speed: ((data['speed'] as num?)?.toDouble() ?? 1.0),
      position: Duration(
          milliseconds: ((data['positionMs'] as num?)?.toInt() ?? 0)
              .clamp(0, 1 << 31)),
    );
  }
}

/// Thin prefs/session adapters to keep the service testable.
/// Wraps live [Prefs] so scrobble thresholds and lossless choices
/// reflect SharedPreferences changes without recreating the service.
class PrefsHandle {
  final Prefs _prefs;
  PrefsHandle(this._prefs);
  bool get preferLossless => _prefs.preferLossless;
  int get losslessQuality => _prefs.losslessQuality;
  int get scrobblePercent => _prefs.scrobblePercent;
  bool get scrobblerEnabled => _prefs.scrobblerEnabled;
  bool get syncYtHistory => _prefs.syncYtHistory;
}

class SessionStore {
  final AppDatabase _db;
  SessionStore(this._db);
  Map<String, dynamic> load() => _db.loadPlaybackSession();
  void save(Map<String, dynamic> payload) =>
      _db.savePlaybackSession(payload);
  void clear() => _db.clearPlaybackSession();
  void recordLocalPlay(String title, String artist) =>
      _db.recordLocalPlay(title: title, artist: artist);
}

final playbackServiceProvider =
    StateNotifierProvider<PlaybackService, PlayerSnapshot>((ref) {
  final service = PlaybackService(
    ref.watch(innerTubeProvider),
    ref.watch(losslessApiProvider),
    ref.watch(scrobbleRepositoryProvider),
    ref.watch(downloadManagerProvider.notifier),
    PrefsHandle(ref.watch(prefsProvider)),
    SessionStore(ref.watch(databaseProvider)),
    ref.watch(officialArtworkServiceProvider),
    (notice) {
      try {
        ref.read(addonNoticeProvider.notifier).state = notice;
      } catch (_) {}
    },
  );
  ref.onDispose(() {
    unawaited(service.disposePlayer());
  });
  return service;
});
