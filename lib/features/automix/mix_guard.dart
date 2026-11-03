/// Self-healing checks for the two-deck mixer.
///
/// Every bug AutoMix has had so far ended the same way: the decks were
/// left in a state nobody asked for (a primary deck stuck at volume 0, a
/// standby deck still audible, a tempo nudge never undone). Rather than
/// trusting every code path to clean up, a watchdog reads the decks once
/// a second and this pure function says what is wrong; the service then
/// applies the repairs and counts them as faults.
library;

class DeckReading {
  const DeckReading({
    required this.volume,
    required this.playing,
    required this.rate,
    this.position = Duration.zero,
  });

  /// mpv volume, 0..100.
  final double volume;
  final bool playing;
  final double rate;
  final Duration position;
}

class MixGuardInput {
  const MixGuardInput({
    required this.mixing,
    required this.armed,
    required this.ramping,
    required this.fullVolume,
    required this.expectedRate,
    required this.primary,
    this.standby,
    this.mixAge = Duration.zero,
    this.maxMixAge = const Duration(seconds: 40),
    this.resolving = false,
  });

  /// An overlap is running (both decks may be audible).
  final bool mixing;

  /// The standby deck is loaded for the next mix (must stay silent).
  final bool armed;

  /// The post-mix tempo glide is running on the primary deck.
  final bool ramping;

  /// What the primary deck's volume must be outside a mix (0..100).
  final double fullVolume;

  /// mpv `speed` the primary deck must have outside a mix / glide.
  final double expectedRate;
  final DeckReading primary;
  final DeckReading? standby;
  final Duration mixAge;
  final Duration maxMixAge;

  /// A track change is in progress; volume/rate are in flux.
  final bool resolving;
}

enum MixRepair {
  /// Primary deck is not at the listener's volume outside a mix.
  restorePrimaryVolume,

  /// Standby deck is audible or playing while no mix runs.
  silenceStandby,

  /// Primary deck kept a mix tempo after the mix ended.
  restoreRate,

  /// An overlap has run far longer than any planned mix.
  abortStuckMix,
}

List<MixRepair> checkMix(MixGuardInput i) {
  final out = <MixRepair>[];
  if (i.mixing) {
    if (i.mixAge > i.maxMixAge) out.add(MixRepair.abortStuckMix);
    return out;
  }
  if (i.resolving) return out;
  final sb = i.standby;
  if (sb != null) {
    final audible = sb.volume > 0.5;
    // Armed decks sit paused at 0; anything else is a leftover.
    if (audible || (!i.armed && sb.playing)) out.add(MixRepair.silenceStandby);
  }
  if ((i.primary.volume - i.fullVolume).abs() > 1.0) {
    out.add(MixRepair.restorePrimaryVolume);
  }
  if (!i.ramping && (i.primary.rate - i.expectedRate).abs() > 0.002) {
    out.add(MixRepair.restoreRate);
  }
  return out;
}

/// Counts AutoMix faults in a session and steps down to safer modes, so
/// a mixer that keeps misbehaving on this machine stops trying.
class MixFaultBudget {
  MixFaultBudget({this.beatLimit = 3, this.overlapLimit = 6});

  final int beatLimit;
  final int overlapLimit;
  int _faults = 0;

  int get faults => _faults;

  /// Beat-matching (tempo change, phase lock) still allowed.
  bool get beatMixAllowed => _faults < beatLimit;

  /// Any overlap still allowed (otherwise tracks change gaplessly).
  bool get overlapAllowed => _faults < overlapLimit;

  /// Records one fault; returns a message when this fault changed mode.
  String? record() {
    _faults++;
    if (_faults == beatLimit) {
      return 'beat-matching off for this session after $_faults faults';
    }
    if (_faults == overlapLimit) {
      return 'overlap off for this session after $_faults faults';
    }
    return null;
  }
}
