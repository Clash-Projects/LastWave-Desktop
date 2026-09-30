import 'dart:async';

import 'package:dart_discord_presence/dart_discord_presence.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/stream_models.dart';
import '../../core/storage/prefs.dart';
import '../player/playback_service.dart';
import '../player/player_state.dart';

/// Discord Rich Presence ("Listening to LastWave") over local IPC.
///
/// Setup: create an application at https://discord.com/developers/
/// applications and paste its ID into [discordApplicationId] below. Under
/// Rich Presence > Art Assets you may upload `logo`, `play` and `pause`
/// icons; until then the track's own artwork URL is used as the large
/// image and missing keys are simply omitted by Discord.
///
/// Behaviour: inert until a real Application ID is set. Never throws —
/// Discord closed, pipe missing, or rate-limited all degrade to silence.
/// Progress-bar refreshes are throttled (track/play-state change or
/// 15s elapsed) so position ticks don't spam the IPC socket.
///
/// NOTE on licensing: `dart_discord_presence` is GPL-3.0. If LastWave ever
/// ships closed-source, replace this transport with a hand-rolled named-
/// pipe client; the mapping logic below stays the same.
class DiscordPresenceService {
  /// Application ID from the Discord Developer Portal (General Information).
  /// Public by design — safe to ship in source (it is not a secret; only
  /// the Client Secret / bot token must stay private).
  static const discordApplicationId = '1552563991426105414';

  static const _maxField = 120;
  static const _pushInterval = Duration(seconds: 15);
  static const _retryInterval = Duration(seconds: 60);

  final Ref _ref;
  DiscordRPC? _rpc;
  StreamSubscription? _discSub;
  StreamSubscription? _errSub;
  bool _disposed = false;
  bool _connecting = false;
  DateTime? _lastAttempt;
  String _lastKey = '';
  DateTime _lastPush = DateTime.fromMillisecondsSinceEpoch(0);
  PlayerSnapshot? _lastSnap;

  DiscordPresenceService(this._ref);

  bool get _configured =>
      discordApplicationId.isNotEmpty &&
      discordApplicationId != 'YOUR_DISCORD_APPLICATION_ID';

  bool get _enabled {
    try {
      return _ref.read(prefsProvider).discordRichPresence;
    } catch (_) {
      return true;
    }
  }

  /// Push the current snapshot once (startup / settings toggle).
  Future<void> startup() => refresh();

  Future<void> refresh() async {
    PlayerSnapshot? snap;
    try {
      snap = _ref.read(playbackServiceProvider);
    } catch (_) {
      return;
    }
    await onSnapshot(snap);
  }

  Future<void> onSnapshot(PlayerSnapshot snap) async {
    _lastSnap = snap;
    await _evaluate();
  }

  Future<void> _evaluate() async {
    if (_disposed) return;
    final snap = _lastSnap;
    // Disabled, unconfigured, or unsupported: clear anything visible.
    if (!_enabled || !_configured || !DiscordRPC.isAvailable) {
      await _clearQuiet();
      return;
    }
    if (snap == null) return;
    final track = snap.current;
    if (track == null || track.title.trim().isEmpty) {
      await _clearQuiet();
      return;
    }
    final key =
        '${track.queueKey}|playing=${snap.isPlaying}|dur=${snap.duration.inSeconds}';
    final now = DateTime.now();
    if (key == _lastKey && now.difference(_lastPush) < _pushInterval) {
      return; // Position ticks must not spam IPC.
    }
    if (!await _ensureConnected()) return;
    try {
      await _rpc?.setPresence(_build(track, snap, now));
      _lastKey = key;
      _lastPush = now;
    } catch (_) {
      // Pipe died mid-write; next snapshot retries (throttled).
      _lastAttempt = DateTime.now();
    }
  }

  DiscordPresence _build(PlayableTrack track, PlayerSnapshot snap, DateTime now) {
    final title = _clip(track.title);
    final artist = track.artist.trim().isEmpty
        ? (track.album.trim().isEmpty ? 'LastWave' : _clip(track.album))
        : _clip(track.artist);
    DiscordTimestamps? ts;
    if (snap.isPlaying && snap.duration > Duration.zero) {
      final pos =
          snap.position > snap.duration ? snap.duration : snap.position;
      final end = now.add(snap.duration - pos);
      ts = DiscordTimestamps.range(end.subtract(snap.duration), end);
    }
    final art = track.artworkUrl.trim();
    return DiscordPresence(
      type: DiscordActivityType.listening,
      details: title,
      state: artist,
      timestamps: ts,
      largeAsset: art.isNotEmpty
          ? DiscordAsset(
              url: art,
              text: track.album.trim().isEmpty ? title : _clip(track.album),
            )
          : DiscordAsset(key: 'logo', text: 'LastWave'),
      smallAsset: snap.isPlaying
          ? DiscordAsset(key: 'play', text: 'Playing')
          : DiscordAsset(key: 'pause', text: 'Paused'),
      instance: true,
    );
  }

  String _clip(String s) {
    final t = s.trim();
    return t.length > _maxField ? '${t.substring(0, _maxField - 1)}...' : t;
  }

  /// Connect if needed. Returns true when ready to send. Never throws.
  Future<bool> _ensureConnected() async {
    try {
      final rpc = _rpc;
      if (rpc != null && rpc.isConnected) return true;
      if (_connecting) return false;
      final last = _lastAttempt;
      if (last != null &&
          DateTime.now().difference(last) < _retryInterval &&
          _rpc != null) {
        return false; // Discord closed recently; back off quietly.
      }
      _connecting = true;
      _lastAttempt = DateTime.now();
      try {
        await _rpc?.dispose();
      } catch (_) {}
      await _discSub?.cancel();
      await _errSub?.cancel();
      final fresh = DiscordRPC();
      _discSub = fresh.onDisconnected.listen((_) {
        _lastKey = ''; // Force a full repush on next snapshot.
      });
      _errSub = fresh.onError.listen((_) {});
      await fresh.initialize(discordApplicationId);
      _rpc = fresh;
      return fresh.isConnected;
    } catch (_) {
      return false;
    } finally {
      _connecting = false;
    }
  }

  Future<void> _clearQuiet() async {
    _lastKey = '';
    final rpc = _rpc;
    if (rpc == null) return;
    try {
      if (rpc.isConnected) await rpc.clearPresence();
    } catch (_) {}
  }

  /// Best-effort clear + release (app quit). Never throws.
  Future<void> shutdown() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _clearQuiet();
    } catch (_) {}
    try {
      await _discSub?.cancel();
    } catch (_) {}
    try {
      await _errSub?.cancel();
    } catch (_) {}
    try {
      await _rpc?.dispose();
    } catch (_) {}
    _rpc = null;
  }

  void dispose() {
    unawaited(shutdown());
  }
}

final discordPresenceProvider = Provider<DiscordPresenceService>((ref) {
  final svc = DiscordPresenceService(ref);
  ref.listen<PlayerSnapshot>(playbackServiceProvider, (prev, next) {
    unawaited(svc.onSnapshot(next));
  });
  ref.onDispose(svc.dispose);
  return svc;
});
