import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/stream_models.dart';
import '../../core/storage/prefs.dart';
import '../player/playback_service.dart';
import '../player/player_state.dart';
import 'discord_ipc.dart';

/// Discord Rich Presence ("Listening to LastWave") over local IPC.
///
/// Setup: create an application at https://discord.com/developers/
/// applications and paste its ID into [discordApplicationId] below. No Art
/// Assets upload is required — both artwork slots are fed external https
/// URLs ([discordLogoAsset] for the brand badge, the track's cover for the
/// large image). Uploading `logo`/`play`/`pause` as Rich Presence assets in
/// the portal and pointing at those keys instead is the offline-safe
/// alternative, for a Discord that cannot reach the URLs.
///
/// Transport is a hand-rolled IPC client ([DiscordIpc]): Windows named
/// pipes (win32/ffi) or Unix domain sockets (dart:io) — no third-party
/// presence package, so no version conflicts and no license surprises.
///
/// Behaviour: pushes on track/play-state change (throttled), silent when
/// Discord is closed, pipe missing, or rate-limited. Progress-bar
/// refreshes are throttled (track/play-state change or 15s elapsed) so
/// position ticks don't spam the IPC socket. The activity is CLEARED as
/// soon as playback is not running (paused, stopped, or finished): a
/// lingering activity carries a `start` timestamp, so Discord keeps
/// counting elapsed time up and a song that ended hours ago still reads
/// as "now playing".
class DiscordPresenceService {
  /// Application ID from the Discord Developer Portal (General Information).
  /// Public by design — safe to ship in source (it is not a secret; only
  /// the Client Secret / bot token must stay private).
  static const discordApplicationId = '1552563991426105414';

  /// Brand mark for the card's small badge (and the fallback large image).
  ///
  /// Discord resolves `assets.large_image` / `assets.small_image` from a
  /// registered Rich Presence asset key OR from a plain https URL, and the
  /// track artwork already rides the URL path — so pointing the badge at the
  /// repo's logo PNG makes the branding show up with zero manual setup.
  /// Swap this for the asset key `logo` if the portal assets are ever
  /// uploaded instead.
  static const discordLogoAsset =
      'https://raw.githubusercontent.com/Clash-Projects/LastWave-Desktop/'
      'main/lastwave-logo.png';

  static const _maxField = 120;
  static const _pushInterval = Duration(seconds: 15);
  /// Grace period before clearing a non-playing activity. Every track EOF
  /// dips `isPlaying` to false while the next track resolves, so an
  /// immediate clear would blink the presence off between songs.
  static const _clearDelay = Duration(seconds: 5);
  // While music plays, a missing connection is retried at most this often:
  // a closed Discord costs ~10 fast-failed pipe opens (sub-millisecond),
  // so retrying eagerly is cheap and keeps worst-case invisibility tiny.
  static const _retryInterval = Duration(seconds: 15);

  final Ref _ref;
  DiscordIpc? _ipc;
  Timer? _heartbeat;
  bool _disposed = false;
  bool _connecting = false;
  DateTime? _lastAttempt;
  String _lastKey = '';
  DateTime _lastPush = DateTime.fromMillisecondsSinceEpoch(0);
  PlayerSnapshot? _lastSnap;
  /// Pending "not playing" clear (see [_scheduleClear]).
  Timer? _clearTimer;

  DiscordPresenceService(this._ref) {
    // Self-heal: re-evaluates on a slow tick so presence can never go
    // stale unnoticed (missed snapshot, dropped pipe, Discord restarted
    // while paused). Tick does nothing when up to date. Interval matches
    // the push throttle, so a playing track is visible within ~15s even
    // if every event-driven push was somehow missed.
    _heartbeat = Timer.periodic(_pushInterval, (_) {
      if (_disposed) return;
      unawaited(refresh());
    });
  }

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
    final current = snap;
    if (current == null) return;
    await onSnapshot(current);
  }

  Future<void> onSnapshot(PlayerSnapshot snap) async {
    _lastSnap = snap;
    await _evaluate();
  }

  Future<void> _evaluate() async {
    if (_disposed) return;
    final snap = _lastSnap;
    // Disabled, unconfigured, or unsupported: clear anything visible.
    if (!_enabled || !_configured || !DiscordIpc.isSupported) {
      await _clearQuiet();
      return;
    }
    if (snap == null) return;
    final track = snap.current;
    if (track == null || track.title.trim().isEmpty) {
      await _clearQuiet();
      return;
    }
    if (!snap.isPlaying) {
      // Paused / stopped / finished: the profile must not keep the track.
      // Pushing it as "Paused" is not enough — the activity (and its
      // `start` timestamp) stays on the profile and Discord counts elapsed
      // time up, so a song that ended while the app stayed open reads as
      // "still playing" for as long as the app runs.
      _scheduleClear();
      return;
    }
    _clearTimer?.cancel();
    _clearTimer = null;
    final key =
        '${track.queueKey}|playing=${snap.isPlaying}|dur=${snap.duration.inSeconds}|br=${snap.bitrateKbps}';
    final now = DateTime.now();
    if (key == _lastKey && now.difference(_lastPush) < _pushInterval) {
      return; // Position ticks must not spam IPC.
    }
    if (!await _ensureConnected()) return;
    final ipc = _ipc;
    if (ipc == null) return;
    try {
      if (!ipc.setActivity(_build(track, snap, now))) {
        // Pipe died mid-write: drop it so the next snapshot reconnects.
        try {
          ipc.close();
        } catch (_) {}
        _ipc = null;
        _lastAttempt = DateTime.now();
        return;
      }
      _lastKey = key;
      _lastPush = now;
    } catch (_) {
      // Pipe died mid-write; next snapshot retries (throttled).
      _lastAttempt = DateTime.now();
    }
  }

  /// Activity payload for SET_ACTIVITY (type 2 = listening). Only built
  /// while playback is running — [_evaluate] clears instead of publishing a
  /// paused activity.
  Map<String, Object?> _build(
      PlayableTrack track, PlayerSnapshot snap, DateTime now) {
    final title = _clip(track.title);
    final artist = track.artist.trim().isEmpty
        ? (track.album.trim().isEmpty ? 'LastWave' : _clip(track.album))
        : _clip(track.artist);
    Map<String, Object?>? ts;
    if (snap.duration > Duration.zero) {
      final pos =
          snap.position > snap.duration ? snap.duration : snap.position;
      final end = now.add(snap.duration - pos);
      final start = end.subtract(snap.duration);
      ts = {
        'start': start.millisecondsSinceEpoch ~/ 1000,
        'end': end.millisecondsSinceEpoch ~/ 1000,
      };
    }
    final quality = _qualityLine(snap);
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
    return {
      'type': 2,
      // Card layout: `name` stays the app, so the profile popout header
      // reads "Listening to LastWave"; the track is `details` (the large
      // line) and the artist is `state` (the subtitle).
      //
      // `status_display_type` selects what the compact line under the
      // username shows: 0 = name, 1 = state, 2 = details. Discord defaults
      // to 0, so DETAILS is what makes the member-list card show the song
      // instead of "LastWave" — the usual split of name/detail rows.
      'name': 'LastWave',
      'details': title,
      'state': artist,
      'status_display_type': 2,
      'timestamps': ?ts,
      'assets': {
        if (artIsUrl) 'large_image': art,
        if (!artIsUrl) 'large_image': discordLogoAsset,
        'large_text':
            track.album.trim().isEmpty ? title : _clip(track.album),
        // Brand badge. Discord draws `small_image` as the little overlay in
        // the card's corner, so the logo rides along with whatever artwork
        // the track supplied; its tooltip is where the audio-format line
        // went once the subtitle became the artist.
        'small_image': discordLogoAsset,
        'small_text': _clip(
            quality.isEmpty ? 'LastWave' : 'LastWave · $quality'),
      },
      'buttons': [
        {
          'label': 'Listen On LastWave',
          'url': vid.isNotEmpty
              ? 'https://www.youtube.com/watch?v=$vid'
              : '$repoUrl/releases',
        },
        {'label': 'Get LastWave', 'url': repoUrl},
      ],
      'instance': true,
    };
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
    final ipc = _ipc;
    if (ipc != null && ipc.isOpen) return true;
    if (_connecting) return false;
    final last = _lastAttempt;
    if (last != null &&
        DateTime.now().difference(last) < _retryInterval &&
        _ipc != null) {
      return false; // Discord closed recently; back off quietly.
    }
    _connecting = true;
    _lastAttempt = DateTime.now();
    try {
      try {
        _ipc?.close();
      } catch (_) {}
      _ipc = null;
      final fresh = await DiscordIpc.connect(discordApplicationId);
      if (fresh == null) return false;
      _ipc = fresh;
      return true;
    } catch (_) {
      return false;
    } finally {
      _connecting = false;
    }
  }

  /// Defers the "not playing" clear by [_clearDelay] so the `isPlaying` dip
  /// at every track EOF does not blink the presence off. No-op once clear:
  /// the 15s heartbeat re-runs [_evaluate] for the whole paused period.
  void _scheduleClear() {
    if (_clearTimer != null || _lastKey.isEmpty) return;
    _clearTimer = Timer(_clearDelay, () {
      _clearTimer = null;
      unawaited(_clearQuiet());
    });
  }

  Future<void> _clearQuiet() async {
    final had = _lastKey.isNotEmpty;
    _lastKey = '';
    final ipc = _ipc;
    // Nothing was ever pushed (startup, or an earlier clear): skip the
    // round-trip and its reply drain.
    if (ipc == null || !had) return;
    try {
      ipc.clearActivity();
    } catch (_) {}
  }

  /// Best-effort clear + release (app quit). Never throws.
  Future<void> shutdown() async {
    if (_disposed) return;
    _disposed = true;
    try {
      _heartbeat?.cancel();
    } catch (_) {}
    _heartbeat = null;
    try {
      _clearTimer?.cancel();
    } catch (_) {}
    _clearTimer = null;
    try {
      await _clearQuiet();
    } catch (_) {}
    try {
      _ipc?.close();
    } catch (_) {}
    _ipc = null;
  }

  void dispose() {
    unawaited(shutdown());
  }
}

final discordPresenceProvider = Provider<DiscordPresenceService>((ref) {
  final svc = DiscordPresenceService(ref);
  // Slice matches _evaluate's push key exactly
  // (queueKey/isPlaying/duration/bitrate): position ticks fired this 10Hz
  // and died in the key check every time. Settings toggles call refresh()
  // explicitly and the 15s heartbeat self-heals, so no push path is lost.
  // (MPRIS/SMTC must keep the full snapshot: their seek detection diffs
  // consecutive positions. This one never consumes position per tick.)
  ref.listen(
    playbackServiceProvider.select((s) => (
      s.current?.queueKey ?? '',
      s.isPlaying,
      s.duration,
      s.bitrateKbps,
    )),
    (_, _) {
      unawaited(svc.onSnapshot(ref.read(playbackServiceProvider)));
    },
  );
  ref.onDispose(svc.dispose);
  return svc;
});
