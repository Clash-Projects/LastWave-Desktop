import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/stream_models.dart';
import '../player/playback_service.dart';
import '../player/player_state.dart';
import 'jam_client.dart';

/// Bridges Jam playback events to the existing player.
///
/// AutoMix is not part of the protocol and is never read or written here.
/// If the socket is down, this does nothing and local playback continues.
final jamSyncProvider = Provider<void>((ref) {
  final bridge = _JamBridge();
  final sub = ref.read(jamControllerProvider.notifier).remote.listen((event) {
    unawaited(_apply(ref, bridge, event));
  });
  ref.onDispose(sub.cancel);
  ref.listen<PlayerSnapshot>(playbackServiceProvider, (previous, next) {
    _broadcast(ref, bridge, previous, next);
    _publishQueue(ref, bridge);
  });
  // Becoming admin (or joining as admin) republishes the queue.
  ref.listen<JamSnapshot>(jamControllerProvider, (previous, next) {
    final was = previous != null && previous.phase == JamPhase.active && previous.isMainHost;
    final now = next.phase == JamPhase.active && next.isMainHost;
    if (now && !was) {
      bridge.lastQueueKey = null;
      _publishQueue(ref, bridge, immediate: true);
    }
  });
  ref.onDispose(() => bridge.queueTimer?.cancel());
});

class _JamBridge {
  int quietUntil = 0;
  String? lastTrack;
  bool? lastPlaying;
  int lastPosition = 0;
  int lastWall = 0;
  String? lastQueueKey;
  Timer? queueTimer;
}

bool _canControl(JamSnapshot session) =>
    session.isHost || session.roomMode == jamModeCollaborative;

String _trackKey(PlayableTrack track) =>
    track.videoId.isNotEmpty ? track.videoId : track.title;

Future<void> _apply(Ref ref, _JamBridge bridge, JamRemote event) async {
  final session = ref.read(jamControllerProvider);
  if (session.phase != JamPhase.active) return;
  final from = switch (event) {
    JamRemotePlay(:final fromUserId) => fromUserId,
    JamRemotePause(:final fromUserId) => fromUserId,
    JamRemoteSeek(:final fromUserId) => fromUserId,
    JamRemoteTrack(:final fromUserId) => fromUserId,
    JamRemoteFull() => null,
  };
  if (from != null && from == session.userId) return;
  final player = ref.read(playbackServiceProvider.notifier);
  final local = ref.read(playbackServiceProvider);
  switch (event) {
    case JamRemoteTrack(:final track, :final isPlaying, :final positionMs):
      await _change(player, local, bridge, track, isPlaying, positionMs);
    case JamRemoteFull(
        :final track,
        :final isPlaying,
        :final positionMs,
        :final serverTimeMs,
      ):
      if (track == null) return;
      final latency = _latency(serverTimeMs);
      await _change(
        player,
        local,
        bridge,
        track,
        isPlaying,
        positionMs + latency,
      );
    case JamRemotePlay(:final positionMs, :final serverTimeMs):
      final target = positionMs + _latency(serverTimeMs);
      bridge.quietUntil = _now() + 800;
      if (local.current == null && session.track != null) {
        await _change(player, local, bridge, session.track!, true, target);
        return;
      }
      if ((local.position.inMilliseconds - target).abs() > 1500) {
        await player.seek(Duration(milliseconds: target));
      }
      if (!local.isPlaying) await player.playResume();
    case JamRemotePause(:final positionMs):
      bridge.quietUntil = _now() + 800;
      if (local.isPlaying) await player.pause();
      if ((local.position.inMilliseconds - positionMs).abs() > 1500) {
        await player.seek(Duration(milliseconds: positionMs));
      }
    case JamRemoteSeek(:final positionMs):
      bridge.quietUntil = _now() + 800;
      if ((local.position.inMilliseconds - positionMs).abs() > 1500) {
        await player.seek(Duration(milliseconds: positionMs));
      }
  }
}

Future<void> _change(
  PlaybackService player,
  PlayerSnapshot local,
  _JamBridge bridge,
  JamTrack track,
  bool isPlaying,
  int positionMs,
) async {
  final current = local.current;
  final same = current != null &&
      ((current.videoId.isNotEmpty && current.videoId == track.id) ||
          (current.title.toLowerCase() == track.title.toLowerCase() &&
              (current.artist.isEmpty ||
                  track.artist.isEmpty ||
                  current.artist.toLowerCase() == track.artist.toLowerCase())));
  bridge.quietUntil = _now() + (same ? 800 : 2500);
  bridge.lastTrack = track.id.isNotEmpty ? track.id : track.title;
  bridge.lastPlaying = isPlaying;
  bridge.lastPosition = positionMs;
  if (!same) {
    final youtube = RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(track.id);
    await player.play(
      PlayableTrack(
        title: track.title,
        artist: track.artist,
        album: track.album ?? '',
        artworkUrl: track.artworkUrl ?? '',
        videoId: youtube ? track.id : '',
        duration: Duration(milliseconds: track.durationMs ?? 0),
      ),
      sourceLabel: 'LastWave Jam',
    );
    if (positionMs > 800) {
      await player.seek(Duration(milliseconds: positionMs));
    }
    if (!isPlaying) await player.pause();
    return;
  }
  if ((local.position.inMilliseconds - positionMs).abs() > 1500) {
    await player.seek(Duration(milliseconds: positionMs));
  }
  if (isPlaying && !local.isPlaying) {
    await player.playResume();
  } else if (!isPlaying && local.isPlaying) {
    await player.pause();
  }
}

void _broadcast(
  Ref ref,
  _JamBridge bridge,
  PlayerSnapshot? previous,
  PlayerSnapshot next,
) {
  final session = ref.read(jamControllerProvider);
  if (session.phase != JamPhase.active) return;
  if (!_canControl(session)) return;
  final now = _now();
  if (now < bridge.quietUntil) return;
  final current = next.current;
  if (current == null) return;
  final jam = ref.read(jamControllerProvider.notifier);
  final key = _trackKey(current);
  final position = next.position.inMilliseconds;
  if (key != bridge.lastTrack) {
    bridge.lastTrack = key;
    bridge.lastPlaying = next.isPlaying;
    bridge.lastPosition = position;
    bridge.lastWall = now;
    bridge.quietUntil = now + 1000;
    jam.broadcastTrack(
      JamTrack(
        id: key,
        title: current.title,
        artist: current.artist,
        album: current.album,
        artworkUrl: current.artworkUrl,
        durationMs: current.duration.inMilliseconds,
      ),
      positionMs: position,
      isPlaying: next.isPlaying,
    );
    return;
  }
  if (next.isPlaying != bridge.lastPlaying) {
    if (!next.isPlaying && next.isBuffering) return;
    bridge.lastPlaying = next.isPlaying;
    bridge.lastPosition = position;
    bridge.lastWall = now;
    bridge.quietUntil = now + 800;
    if (next.isPlaying) {
      jam.broadcastPlay(position);
    } else {
      jam.broadcastPause(position);
    }
    return;
  }
  if (previous == null) return;
  final wall = now - bridge.lastWall;
  final expected = bridge.lastPosition + (next.isPlaying ? wall : 0);
  if ((position - expected).abs() > 2000 && wall < 4000) {
    bridge.lastPosition = position;
    bridge.lastWall = now;
    bridge.quietUntil = now + 800;
    jam.broadcastSeek(position);
    return;
  }
  bridge.lastPosition = position;
  bridge.lastWall = now;
}

/// Publishes the admin's upcoming queue (debounced, only when it changed).
void _publishQueue(Ref ref, _JamBridge bridge, {bool immediate = false}) {
  final session = ref.read(jamControllerProvider);
  if (session.phase != JamPhase.active || !session.isMainHost) return;
  final player = ref.read(playbackServiceProvider);
  final start = player.currentIndex + 1;
  final upcoming = start >= 0 && start < player.queue.length
      ? player.queue.sublist(start)
      : <PlayableTrack>[];
  final tracks = [
    for (final t in upcoming.take(5))
      JamTrack(
        id: _trackKey(t),
        title: t.title,
        artist: t.artist,
        album: t.album,
        artworkUrl: t.artworkUrl,
        durationMs: t.duration.inMilliseconds,
      ),
  ];
  final key = tracks.map((t) => t.id).join('|');
  if (key == bridge.lastQueueKey) return;
  void send() {
    bridge.lastQueueKey = key;
    ref.read(jamControllerProvider.notifier).broadcastQueue(tracks);
  }

  bridge.queueTimer?.cancel();
  if (immediate) {
    send();
  } else {
    bridge.queueTimer = Timer(const Duration(milliseconds: 600), send);
  }
}

int _latency(int serverTimeMs) {
  if (serverTimeMs <= 0) return 0;
  final now = DateTime.now().millisecondsSinceEpoch;
  final delta = now - serverTimeMs;
  if (delta <= 0) return 0;
  return delta > 3000 ? 3000 : delta;
}

int _now() => DateTime.now().millisecondsSinceEpoch;
