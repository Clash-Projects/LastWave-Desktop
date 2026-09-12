import 'dart:async';

/// Last.fm rate-limit guard.
///
/// Ported from LastWave-native `data/network/LastFmRateGuard.kt`:
/// a short cooldown is applied after HTTP 429/503 so clients back off
/// instead of hammering the API.
class LastFmRateGuard {
  DateTime? _cooldownUntil;

  bool get isCoolingDown {
    final until = _cooldownUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  Duration get remaining {
    final until = _cooldownUntil;
    if (until == null) return Duration.zero;
    final d = until.difference(DateTime.now());
    return d.isNegative ? Duration.zero : d;
  }

  void onRequestLimited({Duration extra = const Duration(seconds: 2)}) {
    final now = DateTime.now();
    final base = _cooldownUntil != null && _cooldownUntil!.isAfter(now)
        ? _cooldownUntil!
        : now;
    _cooldownUntil = base.add(extra);
  }

  void onRequestSucceeded() {
    _cooldownUntil = null;
  }

  Future<void> awaitClearance() async {
    final wait = remaining;
    if (wait > Duration.zero) {
      await Future<void>.delayed(wait);
    }
  }
}

/// Maps Last.fm error codes to friendly messages.
/// Ported from `LastFmErrors.friendlyMessage` in LastWave-native.
String lastFmFriendlyMessage(int? code, String raw) {
  switch (code) {
    case 2:
      return 'Invalid service — please try again later.';
    case 3:
      return 'Invalid method — this build may be outdated.';
    case 4:
      return 'Authentication failed — reconnect Last.fm.';
    case 5:
      return 'Invalid API signature — reconnect Last.fm.';
    case 6:
      return 'This track is not loved on Last.fm.';
    case 7:
      return 'Invalid session key — reconnect Last.fm.';
    case 8:
      return 'Operation failed — please retry.';
    case 9:
      return 'Invalid session — reconnect Last.fm.';
    case 10:
      return 'Invalid API key.';
    case 11:
      return 'Service is offline — try again later.';
    case 13:
      return 'Invalid method signature.';
    case 14:
      return 'Unauthorized token — approve access again.';
    case 15:
      return 'This app is temporarily suspended.';
    case 16:
      return 'Service is down for maintenance.';
    case 26:
      return 'Suspended API key.';
    case 29:
      return 'Rate limited — backing off.';
    default:
      return raw.isEmpty ? 'Last.fm request failed.' : raw;
  }
}
