import 'dart:math' as math;

import 'audio_analysis.dart';

/// A transition placed on real audio: where the outgoing track hands
/// over, where the incoming one enters, and how fast it plays meanwhile.
///
/// Times are seconds on each track's own timeline.
class BeatMixPlan {
  const BeatMixPlan({
    required this.mixOutStart,
    required this.overlap,
    required this.incomingCue,
    required this.incomingStartAt,
    required this.rate,
    required this.beatMatched,
    required this.beats,
    required this.reason,
  });

  /// Outgoing position where the blend starts (a downbeat when matched).
  final double mixOutStart;

  /// Blend length in seconds of OUTGOING time.
  final double overlap;

  /// Incoming position that lines up with [mixOutStart].
  final double incomingCue;

  /// Where the incoming deck is opened: a muted pre-roll before
  /// [incomingCue] gives the phase lock time to settle before it is heard.
  final double incomingStartAt;

  /// Incoming playback-rate multiplier while blending (1 = untouched).
  final double rate;

  final bool beatMatched;

  /// Overlap length in outgoing beats (0 when not beat-matched).
  final int beats;
  final String reason;

  /// Outgoing position at which the incoming deck must start playing.
  double get triggerAt => mixOutStart - (incomingCue - incomingStartAt) / rate;

  /// Where the incoming track should be at outgoing position [outPos].
  double expectedIncoming(double outPos) =>
      incomingCue + (outPos - mixOutStart) * rate;

  double get mixOutEnd => mixOutStart + overlap;
}

class BeatMixPlanner {
  BeatMixPlanner._();

  /// Largest tempo change applied to the incoming track. ±6% is about a
  /// semitone of pitch if it were not corrected; with scaletempo it stays
  /// in key and is hard to notice.
  static const double maxRateChange = 0.06;
  /// Needs the beat phase ≈3.6σ clear of every other phase; noise and
  /// sustained pads stay under ~2.5σ.
  static const double minConfidence = 0.2;
  static const double preroll = 3.0;

  /// [outgoingTail] / [incomingHead] are analyses of the last / first
  /// minute. [maxOverlap] already includes the user's setting and the
  /// short-track cap. Returns null when the windows cannot support a mix.
  static BeatMixPlan? plan({
    required TrackAnalysis outgoingTail,
    required TrackAnalysis incomingHead,
    required double outgoingDuration,
    required double incomingDuration,
    required double maxOverlap,
    bool allowTempo = true,
  }) {
    try {
      final p = _plan(
        outgoingTail: outgoingTail,
        incomingHead: incomingHead,
        outgoingDuration: outgoingDuration,
        incomingDuration: incomingDuration,
        maxOverlap: maxOverlap,
        allowTempo: allowTempo,
      );
      return p != null &&
              isSafePlan(p,
                  outgoingDuration: outgoingDuration, maxOverlap: maxOverlap)
          ? p
          : null;
    } catch (_) {
      return null;
    }
  }

  /// Last line of defence: whatever the analysis said, a plan the engine
  /// runs must be finite, inside both tracks, no longer than allowed, and
  /// within the tempo limit.
  static bool isSafePlan(BeatMixPlan p,
      {required double outgoingDuration, required double maxOverlap}) {
    bool f(double v) => v.isFinite;
    if (!f(p.mixOutStart) ||
        !f(p.overlap) ||
        !f(p.incomingCue) ||
        !f(p.incomingStartAt) ||
        !f(p.rate)) {
      return false;
    }
    if (p.overlap < 3 || p.overlap > maxOverlap + 0.01) return false;
    if ((p.rate - 1).abs() > maxRateChange + 1e-6) return false;
    if (!p.beatMatched && p.rate != 1.0) return false;
    if (p.triggerAt < 0 || p.mixOutStart < 0) return false;
    if (p.mixOutEnd > outgoingDuration + 0.5) return false;
    if (p.incomingCue < 0 || p.incomingStartAt < 0) return false;
    if (p.incomingStartAt > p.incomingCue + 1e-6) return false;
    if (p.incomingCue - p.incomingStartAt > preroll + 1e-6) return false;
    return true;
  }

  static BeatMixPlan? _plan({
    required TrackAnalysis outgoingTail,
    required TrackAnalysis incomingHead,
    required double outgoingDuration,
    required double incomingDuration,
    required double maxOverlap,
    required bool allowTempo,
  }) {
    if (maxOverlap < 4) return null;
    final out = outgoingTail;
    final inc = incomingHead;
    // The outgoing track's real end: its last audible moment, never past
    // the file end.
    final contentEnd = math.min(out.contentEnd, outgoingDuration);
    final cueFloor = inc.audibleStart;

    // ---- tempo ------------------------------------------------------------
    var rate = 1.0;
    var matched = false;
    if (allowTempo &&
        out.hasBeat &&
        inc.hasBeat &&
        out.confidence >= minConfidence &&
        inc.confidence >= minConfidence) {
      // Half / double time count as the same groove.
      var best = double.infinity;
      for (final m in const [0.5, 1.0, 2.0]) {
        final r = out.bpm / (inc.bpm * m);
        if ((r - 1).abs() < (best - 1).abs()) best = r;
      }
      if ((best - 1).abs() <= maxRateChange) {
        rate = best;
        matched = true;
      }
    }

    if (matched) {
      final beat = out.beatPeriod;
      // Phrase-sized overlaps: 32, 16 or 8 beats, the longest that fits.
      var beats = 0;
      for (final b in const [32, 16, 8]) {
        if (b * beat <= maxOverlap + 0.01) {
          beats = b;
          break;
        }
      }
      if (beats > 0) {
        final overlap = beats * beat;
        final latest = contentEnd - overlap;
        final grid = out.downbeats.isNotEmpty ? out.downbeats : out.beats;
        double? start;
        for (final d in grid.reversed) {
          if (d <= latest + 0.02 && d >= out.windowStart + 1) {
            start = d;
            break;
          }
        }
        // Incoming enters on its first downbeat with real sound.
        final inGrid = inc.downbeats.isNotEmpty ? inc.downbeats : inc.beats;
        double? cue;
        for (final d in inGrid) {
          if (d >= cueFloor - 0.08) {
            cue = d;
            break;
          }
        }
        if (start != null &&
            cue != null &&
            cue + overlap * rate + 5 < incomingDuration) {
          final startAt = math.max(0.0, cue - preroll);
          return BeatMixPlan(
            mixOutStart: start,
            overlap: overlap,
            incomingCue: cue,
            incomingStartAt: startAt,
            rate: rate,
            beatMatched: true,
            beats: beats,
            reason: 'beatmatch ${out.bpm.toStringAsFixed(1)}->'
                '${inc.bpm.toStringAsFixed(1)}',
          );
        }
      }
    }

    // ---- not beat-matchable: still skip dead air on both sides ----------
    final overlap = maxOverlap;
    final start = contentEnd - overlap;
    if (start < out.windowStart) return null;
    final cue = math.max(0.0, cueFloor - 0.05);
    if (cue + overlap + 5 >= incomingDuration) return null;
    return BeatMixPlan(
      mixOutStart: start,
      overlap: overlap,
      incomingCue: cue,
      incomingStartAt: cue,
      rate: 1.0,
      beatMatched: false,
      beats: 0,
      reason: out.hasBeat && inc.hasBeat ? 'tempo-far' : 'no-beat',
    );
  }
}

/// What the phase lock wants done to the incoming deck this tick.
class BeatLockAction {
  const BeatLockAction({this.seekTo, this.rate});

  /// Jump the (still muted) incoming deck here, in seconds.
  final double? seekTo;

  /// New playback rate for the incoming deck (absolute, includes speed).
  final double? rate;

  static const none = BeatLockAction();
}

/// Keeps the incoming deck on the outgoing deck's beat grid.
///
/// mpv's playback clock advances in audio-buffer chunks, so a single
/// position reading is ±30 ms noisy. The lock therefore [sample]s every
/// tick and only acts every [interval] on the averaged error: while the
/// incoming deck is still muted a large error is fixed with a seek;
/// after that only small speed nudges (≤3%, kept in pitch by scaletempo)
/// so nothing is ever heard to jump or wobble.
class BeatLock {
  BeatLock(this.plan, {required this.speed});

  final BeatMixPlan plan;
  final double speed;

  static const Duration interval = Duration(milliseconds: 500);

  double _sum = 0;
  int _n = 0;
  double _lastOut = 0;
  double _lastRate = 0;
  DateTime _lastStep = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastSeek = DateTime.fromMillisecondsSinceEpoch(0);
  double _absSum = 0;
  int _count = 0;
  double _lastError = 0;

  /// Mean absolute (averaged) phase error while audible, seconds.
  double get meanAudibleError => _count == 0 ? 0 : _absSum / _count;
  double get lastError => _lastError;

  void sample(double outPos, double inPos) {
    if (!plan.beatMatched || inPos <= 0 || outPos <= 0) return;
    _sum += inPos - plan.expectedIncoming(outPos);
    _n++;
    _lastOut = outPos;
  }

  BeatLockAction step(DateTime now) {
    if (!plan.beatMatched) return BeatLockAction.none;
    if (now.difference(_lastStep) < interval || _n < 4) {
      return BeatLockAction.none;
    }
    _lastStep = now;
    final err = _sum / _n;
    _sum = 0;
    _n = 0;
    _lastError = err;
    final audible = _lastOut >= plan.mixOutStart;
    if (audible) {
      _absSum += err.abs();
      _count++;
    }
    if (!audible &&
        err.abs() > 0.12 &&
        now.difference(_lastSeek) > const Duration(seconds: 1)) {
      _lastSeek = now;
      return BeatLockAction(seekTo: plan.expectedIncoming(_lastOut) + 0.03);
    }
    // Remove the error over ~1 s; ignore what is inside the noise floor.
    final e = err.abs() < 0.008 ? 0.0 : err;
    final corr = (-e * 1.0).clamp(-0.03, 0.03);
    final rate = speed * plan.rate * (1 + corr);
    if ((rate - _lastRate).abs() > 0.0005) {
      _lastRate = rate;
      return BeatLockAction(rate: rate);
    }
    return BeatLockAction.none;
  }
}
