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
/// Behaviour: pushes on track/play-state change (throttled), silent when
/// Discord is closed, pipe missing, or rate-limited. Progress-bar
/// refreshes are throttled (track/play-state change or 15s elapsed) so
/// position ticks don't spam the IPC socket.
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
        '${track.queueKey}|playing=${snap.isPlaying}|dur=${snap.duration.inSeconds}|br=${snap.bitrateKbps}';
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
    final quality = _qualityLine(snap);
    final rawState = quality.isEmpty ? artist : '$artist\n$quality';
    final state =
        rawState.length > 125 ? '${rawState.substring(0, 124)}...' : rawState;
    final art = track.artworkUrl.trim();
    // External assets need http(s) — local file paths can't load in
    // Discord, so those fall back to the uploaded `logo` key.
    final artIsUrl =
        art.startsWith('http://') || art.startsWith('https://');
    // Discord buttons are plain URLs — they cannot detect the app. Listen
    // opens the track itself so the clicker can hear it right away; Get
    // always opens the repo.
    const repoUrl = 'https://github.com/Clash-Projects/LastWave-Desktop';
    final vid = track.videoId.trim();
    return DiscordPresence(
      type: DiscordActivityType.listening,
      details: title,
      state: state,
      timestamps: ts,
      largeAsset: artIsUrl
          ? DiscordAsset(
              url: art,
              text: track.album.trim().isEmpty ? title : _clip(track.album),
            )
          : DiscordAsset(key: 'logo', text: 'LastWave'),
      smallAsset: snap.isPlaying
          ? DiscordAsset(key: 'play', text: 'Playing')
          : DiscordAsset(key: 'pause', text: 'Paused'),
      buttons: [
        DiscordButton(
          label: 'Listen On LastWave',
          url: vid.isNotEmpty
              ? 'https://www.youtube.com/watch?v=$vid'
              : '$repoUrl/releases',
        ),
        const DiscordButton(label: 'Get LastWave', url: repoUrl),
      ],
      instance: true,
    );
  }

  /// "Hi-Res Lossless · FLAC · 4608 kbps · 24-bit · 96 kHz · Stereo".
  /// Only known parts are included — never fabricated.
  String _qualityLine(PlayerSnapshot snap) {
    final parts = <String>[];
    final stream = snap.stream;
    final out = snap.outputFormat;
    final depth = (out?.bitDepth ?? 0) > 0
        ? out!.bitDepth
        : (stream?.bitDepth ?? 0);
    final rateKhz = (out?.sampleRateHz ?? 0) > 0
        ? out!.sampleRateHz / 1000.0
        : (stream?.samplingRateKhz ?? 0);
    if (stream?.isLossless ?? false) {
      parts.add(
          (rateKhz > 48 || depth > 16) ? 'Hi-Res Lossless' : 'Lossless');
    }
    final codec = (stream?.audioCodec ?? '').trim();
    if (codec.isNotEmpty) parts.add(codec.toUpperCase());
    if (snap.bitrateKbps > 0) parts.add('${snap.bitrateKbps} kbps');
    if (depth > 0) parts.add('$depth-bit');
    if (rateKhz > 0) parts.add(_rateLabel(rateKhz));
    final ch = out?.channels ?? 0;
    if (ch == 1) {
      parts.add('Mono');
    } else if (ch == 2) {
      parts.add('Stereo');
    } else if (ch > 2) {
      parts.add('$ch-ch');
    }
    return parts.join(' · ');
  }

  String _rateLabel(double khz) {
    if ((khz - khz.round()).abs() < 0.05) return '${khz.round()} kHz';
    return '${khz.toStringAsFixed(1)} kHz';
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
