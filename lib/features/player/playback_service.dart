import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import '../../core/audio/stream_models.dart';
import '../downloads/download_manager.dart';
import '../innertube/innertube_api.dart';
import '../lastfm/scrobble_repository.dart';
import '../lossless/lossless_api.dart';
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
  final LosslessMusicApi _lossless;
  final ScrobbleRepository _scrobbler;
  final DownloadManager _downloads;
  final PrefsHandle _prefs;
  final SessionStore _sessions;

  Player? _player;
  final List<StreamSubscription> _subs = [];
  final Set<String> _unavailable = {};
  final Set<String> _losslessBypass = {};
  List<int> _shuffleOrder = [];
  Timer? _sleepTimer;
  DateTime? _sleepDeadline;
  Timer? _persistThrottle;
  DateTime _lastPersist = DateTime.fromMillisecondsSinceEpoch(0);

  // Scrobble bookkeeping (mirrors Android detector).
  int _scrobbleStartEpoch = 0;
  double _accumulatedSeconds = 0;
  DateTime? _lastTick;
  bool _nowPlayingSent = false;

  bool _endlessRadio = false;
  final Set<String> _radioSeeds = {};
  bool _resolving = false;

  PlaybackService(
    this._tube,
    this._lossless,
    this._scrobbler,
    this._downloads,
    this._prefs,
    this._sessions,
  ) : super(const PlayerSnapshot());

  Future<void> ensurePlayer() async {
    if (_player != null) return;
    _player = Player(configuration: const PlayerConfiguration());
    final p = _player!;
    _subs.addAll([
      p.stream.playing.listen((v) {
        state = state.copyWith(isPlaying: v);
        _onPlayingChanged(v);
      }),
      p.stream.buffering.listen((v) {
        state = state.copyWith(isBuffering: v);
      }),
      p.stream.position.listen((v) {
        state = state.copyWith(position: v);
        _tickScrobble(v);
      }),
      p.stream.buffer.listen((v) {
        state = state.copyWith(buffered: v);
      }),
      p.stream.duration.listen((v) {
        state = state.copyWith(duration: v);
      }),
      p.stream.completed.listen((done) {
        if (done) _onTrackCompleted();
      }),
      p.stream.error.listen((_) => _onPlayerError()),
    ]);
    await restoreSession();
  }

  void disposePlayer() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _sleepTimer?.cancel();
    _persistThrottle?.cancel();
    _player?.dispose();
    _player = null;
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
  }

  Future<void> addToQueue(PlayableTrack track) async {
    final queue = List<PlayableTrack>.of(state.queue)..add(track);
    _rebuildShuffleOrder(queue.length, state.currentIndex);
    state = state.copyWith(queue: queue);
    _schedulePersist();
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

  // -- transport ---------------------------------------------------------------

  Future<void> toggle() async {
    await ensurePlayer();
    await _player?.playOrPause();
  }

  Future<void> playResume() async {
    await ensurePlayer();
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
    await _resolveAndOpen(state.currentIndex, forceYoutube: true);
  }

  Future<void> stopAndClear() async {
    try {
      await _player?.stop();
    } catch (_) {}
    _endlessRadio = false;
    _sessions.clear();
    state = const PlayerSnapshot(
      shuffleEnabled: false,
      repeatMode: RepeatMode.off,
      speed: 1.0,
    );
  }

  // -- resolution ---------------------------------------------------------------

  Future<void> _resolveAndOpen(int index,
      {bool forceYoutube = false, int attempt = 0}) async {
    if (_resolving) return;
    _resolving = true;
    try {
      final track = state.queue[index];
      if (_unavailable.contains(track.mediaId) && attempt == 0) {
        await _skipUnavailable(index);
        return;
      }
      _beginScrobbleWindow(track);
      final local = _localStream(track);
      if (local != null) {
        await _open(track, local);
        return;
      }
      final stream = await _resolveRemote(track,
          forceYoutube: forceYoutube);
      if (stream == null) {
        if (attempt == 0 && !forceYoutube) {
          _losslessBypass.add(track.mediaId);
          await _resolveAndOpen(index,
              forceYoutube: true, attempt: 1);
          return;
        }
        _unavailable.add(track.mediaId);
        await _skipUnavailable(index);
        return;
      }
      await _open(track, stream);
      _maybeRefillRadio();
    } finally {
      _resolving = false;
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

  Future<ResolvedStream?> _resolveRemote(
    PlayableTrack track, {
    bool forceYoutube = false,
  }) async {
    final allowLossless = !forceYoutube &&
        !_losslessBypass.contains(track.mediaId) &&
        _prefs.preferLossless &&
        _prefs.losslessQuality != AudioQualityTiers.youtubeOnly &&
        _lossless.isConfigured &&
        track.artist.isNotEmpty &&
        track.artist.toLowerCase() != 'unknown artist';
    if (!allowLossless) {
      return _resolveYoutube(track, const {});
    }
    // Race: await lossless first, YouTube resolves in parallel
    // (mirrors Android `resolveRemoteTrackAudioStream`).
    Future<ResolvedStream?> youtube = _resolveYoutube(track, const {});
    ResolvedStream? lossless;
    try {
      lossless = await _lossless
          .resolveStream(
            title: track.title,
            artist: track.artist,
            album: track.album,
            preferredQuality: _prefs.losslessQuality,
          )
          .timeout(const Duration(seconds: 25));
    } catch (_) {
      lossless = null;
    }
    if (lossless != null) return lossless;
    try {
      return await youtube.timeout(const Duration(seconds: 30));
    } catch (_) {
      return null;
    }
  }

  Future<ResolvedStream?> _resolveYoutube(
    PlayableTrack track,
    Set<String> excluded,
  ) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        String? videoId =
            track.videoId.isNotEmpty ? track.videoId : null;
        videoId ??= (await _tube
                .findBestMatch(
                  track.title,
                  track.artist,
                  excludedVideoIds: excluded,
                )
                .timeout(const Duration(seconds: 15)))
            ?.videoId;
        if (videoId == null || videoId.isEmpty) return null;
        if (excluded.contains(videoId)) continue;
        final stream = await _tube
            .resolveAudioStream(videoId)
            .timeout(const Duration(seconds: 25));
        if (stream != null) return stream;
        _tube.reportPlaybackFailure(videoId);
        excluded = {...excluded, videoId};
      } catch (_) {
        await Future<void>.delayed(
            Duration(milliseconds: 350 * (1 << attempt)));
      }
    }
    return null;
  }

  Future<void> _open(PlayableTrack track, ResolvedStream stream) async {
    state = state.copyWith(
      stream: stream,
      bitrateKbps: stream.bitrateKbps,
      isBuffering: true,
      clearError: true,
    );
    try {
      await _player?.open(
        Media(stream.url, httpHeaders: stream.requestHeaders),
        play: true,
      );
      if (state.speed != 1.0) {
        await _player?.setRate(state.speed);
      }
    } catch (e) {
      if (stream.cacheKey.startsWith('lossless:')) {
        _losslessBypass.add(track.mediaId);
        await _resolveAndOpen(state.currentIndex,
            forceYoutube: true);
      } else {
        _tube.reportPlaybackFailure(track.videoId);
        _unavailable.add(track.mediaId);
        await _skipUnavailable(state.currentIndex);
      }
    }
  }

  void _onPlayerError() {
    final track = state.current;
    if (track == null || _resolving) return;
    if (state.stream?.cacheKey.startsWith('lossless:') ?? false) {
      _losslessBypass.add(track.mediaId);
      _resolveAndOpen(state.currentIndex, forceYoutube: true);
    } else {
      if (track.videoId.isNotEmpty) {
        _tube.reportPlaybackFailure(track.videoId);
      }
      _unavailable.add(track.mediaId);
      _skipUnavailable(state.currentIndex);
    }
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
    _flushScrobble(completed: true);
    if (state.repeatMode == RepeatMode.one) {
      seek(Duration.zero);
      playResume();
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
            _unavailable.contains(queue[candidate].mediaId)) {
          // walk forward past unavailable
          for (var i = pos + 1; i < _shuffleOrder.length; i++) {
            if (!_unavailable
                .contains(queue[_shuffleOrder[i]].mediaId)) {
              return _shuffleOrder[i];
            }
          }
          return _wrapIndex();
        }
        return candidate;
      }
      return _wrapIndex();
    }
    final next = state.currentIndex + 1;
    if (next < queue.length) {
      if (skipUnavailable &&
          _unavailable.contains(queue[next].mediaId)) {
        for (var i = next; i < queue.length; i++) {
          if (!_unavailable.contains(queue[i].mediaId)) return i;
        }
        return _wrapIndex();
      }
      return next;
    }
    return _wrapIndex();
  }

  int? _wrapIndex() {
    if (state.repeatMode == RepeatMode.all && state.queue.isNotEmpty) {
      if (state.shuffleEnabled && _shuffleOrder.isNotEmpty) {
        return _shuffleOrder.first;
      }
      return 0;
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
          : (await _tube.findBestMatch(seed.title, seed.artist))
              ?.videoId;
      if (videoId == null) return;
      final related =
          await _tube.fetchRelatedSongs(videoId, limit: 25);
      final existing =
          state.queue.map((t) => t.queueKey).toSet();
      final fresh = related
          .where((t) =>
              !_isDisallowedRadioTitle(t.title) &&
              !existing.contains(
                  '${t.title.toLowerCase()}|${t.artist.toLowerCase()}') &&
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
    _flushScrobble(completed: false);
    _scrobbleStartEpoch =
        DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _accumulatedSeconds = 0;
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

  void _tickScrobble(Duration position) {
    final last = _lastTick;
    final now = DateTime.now();
    if (last != null && state.isPlaying) {
      _accumulatedSeconds +=
          now.difference(last).inMilliseconds / 1000.0;
    }
    _lastTick = now;
  }

  void _flushScrobble({required bool completed}) {
    final track = state.current;
    if (track == null || _scrobbleStartEpoch == 0) return;
    final durationSec = state.duration.inSeconds;
    final threshold = durationSec > 0
        ? ([durationSec * 0.5, 240].reduce((a, b) => a < b ? a : b))
            .clamp(30, 1 << 30)
            .toInt()
        : 30;
    final playedEnough =
        _accumulatedSeconds >= 30 && _accumulatedSeconds >= threshold * 0.5 ||
            (completed && _accumulatedSeconds >= 30);
    if (playedEnough) {
      unawaited(_scrobbler.scrobble(
        artist: track.artist,
        track: track.title,
        album: track.album,
        timestampSec: _scrobbleStartEpoch,
      ));
    }
    _scrobbleStartEpoch = 0;
    _accumulatedSeconds = 0;
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
    );
  }
}

/// Thin prefs/session adapters to keep the service testable.
class PrefsHandle {
  final bool preferLossless;
  final int losslessQuality;
  const PrefsHandle({
    required this.preferLossless,
    required this.losslessQuality,
  });
}

class SessionStore {
  final AppDatabase _db;
  SessionStore(this._db);
  Map<String, dynamic> load() => _db.loadPlaybackSession();
  void save(Map<String, dynamic> payload) =>
      _db.savePlaybackSession(payload);
  void clear() => _db.clearPlaybackSession();
}

final playbackServiceProvider =
    StateNotifierProvider<PlaybackService, PlayerSnapshot>((ref) {
  final service = PlaybackService(
    ref.watch(innerTubeProvider),
    ref.watch(losslessApiProvider),
    ref.watch(scrobbleRepositoryProvider),
    ref.watch(downloadManagerProvider.notifier),
    PrefsHandle(
      preferLossless: ref.watch(prefsProvider).preferLossless,
      losslessQuality: ref.watch(prefsProvider).losslessQuality,
    ),
    SessionStore(ref.watch(databaseProvider)),
  );
  ref.onDispose(service.disposePlayer);
  return service;
});
