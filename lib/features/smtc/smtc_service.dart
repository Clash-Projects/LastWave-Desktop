import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../player/playback_service.dart';
import '../player/player_state.dart';

/// SMTC status codes consumed by `windows/runner/smtc_channel.cpp`.
const smtcStatusStopped = 0;
const smtcStatusPlaying = 1;
const smtcStatusPaused = 2;
const smtcStatusChanging = 3;

/// Positions that moved further than playback time explains count as a
/// seek (mirrors the MPRIS Seeked threshold).
const smtcSeekThreshold = Duration(seconds: 3);

/// Maps a snapshot to the SMTC playback status.
///
/// `Stopped` only when there is no track; buffering while playing reports
/// `Changing` so the flyout shows a spinner instead of flickering.
int smtcStatusFor(PlayerSnapshot snap) {
  if (snap.current == null) return smtcStatusStopped;
  if (snap.isPlaying && snap.isBuffering) return smtcStatusChanging;
  return snap.isPlaying ? smtcStatusPlaying : smtcStatusPaused;
}

/// Builds the `update` payload for [next], or null when nothing worth
/// pushing changed.
///
/// The shell extrapolates position from `rate` (0 while paused), so
/// position is only pushed on track/status/seek changes — never per tick.
Map<String, Object>? smtcUpdateFor(PlayerSnapshot? prev, PlayerSnapshot next) {
  final track = next.current;
  final hasTrack = track != null;
  final status = smtcStatusFor(next);
  final canGo = hasTrack;

  bool changed = prev == null;
  if (!changed) {
    final prevTrack = prev.current;
    changed =
        prevTrack?.mediaId != track?.mediaId ||
        prev.duration != next.duration ||
        prevTrack?.artworkUrl != track?.artworkUrl ||
        smtcStatusFor(prev) != status ||
        prev.speed != next.speed ||
        (prev.current == null) != (track == null);
  }
  if (!changed && prev != null) {
    // User seek on the same track: position jumped further than the
    // snapshot cadence explains while the play state held steady.
    final delta = (next.position - prev.position).abs();
    changed = prev.current?.mediaId == track?.mediaId &&
        delta > smtcSeekThreshold &&
        prev.isPlaying == next.isPlaying;
  }
  if (!changed) return null;

  return {
    'title': track?.title ?? '',
    'artist': track?.artist ?? '',
    'album': track?.album ?? '',
    'artUrl': track?.artworkUrl ?? '',
    'status': status,
    'positionMs': next.position.inMilliseconds,
    'durationMs': next.duration.inMilliseconds,
    // The shell advances the timeline itself at this rate; 0 freezes it.
    'rate': next.isPlaying ? next.speed : 0.0,
    'hasTrack': hasTrack,
    'canNext': canGo,
    'canPrev': canGo,
  };
}

/// Windows System Media Transport Controls endpoint — the Windows
/// counterpart to the MPRIS service on Linux.
///
/// Pushes now-playing metadata + transport state to the native
/// `lastwave/smtc` channel (volume flyout, lock screen, Bluetooth,
/// hardware media keys) and routes button presses back into
/// [PlaybackService]. Windows only; every failure degrades to silence.
class SmtcService {
  final Ref _ref;
  final MethodChannel _channel = const MethodChannel('lastwave/smtc');
  PlayerSnapshot? _last;
  bool _handlerSet = false;
  bool _disposed = false;

  SmtcService(this._ref);

  PlaybackService get _player => _ref.read(playbackServiceProvider.notifier);

  Future<void> startup() async {
    if (!Platform.isWindows || _disposed) return;
    if (!_handlerSet) {
      _handlerSet = true;
      _channel.setMethodCallHandler(_onNativeCall);
    }
    _last = null;
    onSnapshot(_ref.read(playbackServiceProvider));
  }

  void onSnapshot(PlayerSnapshot snap) {
    if (!Platform.isWindows || _disposed) return;
    final update = smtcUpdateFor(_last, snap);
    _last = snap;
    if (update == null) return;
    unawaited(_channel.invokeMethod('update', update).catchError((_) {}));
  }

  Future<dynamic> _onNativeCall(MethodCall call) async {
    if (call.method != 'onButton') return null;
    final player = _player;
    try {
      switch (call.arguments as String?) {
        case 'play':
          await player.playResume();
        case 'pause':
          await player.pause();
        case 'toggle':
          await player.toggle();
        case 'stop':
          // No quit-via-SMTC (MPRIS CanQuit=false parity): stop = pause.
          await player.pause();
        case 'next':
          await player.next();
        case 'previous':
          await player.previous();
      }
    } catch (_) {}
    return null;
  }

  void dispose() {
    _disposed = true;
    _last = null;
  }
}

final smtcProvider = Provider<SmtcService>((ref) {
  final svc = SmtcService(ref);
  ref.listen<PlayerSnapshot>(
      playbackServiceProvider, (prev, next) => svc.onSnapshot(next));
  ref.onDispose(svc.dispose);
  return svc;
});
