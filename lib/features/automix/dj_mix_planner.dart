import 'dart:math' as math;

import 'audio_analysis.dart';

/// How a planned blend is played.
enum DjMixStyle {
  /// Incoming tempo matched to the outgoing one and held on its beat;
  /// basses swapped at the midpoint.
  beatmatch,

  /// Tempos too far apart to match: both play at their own speed, the
  /// incoming one starts on an outgoing downbeat, the outgoing one drains
  /// its lows while the incoming one opens up its highs.
  filter,
}

/// A DJ blend placed on real audio, in each track's own seconds.
///
/// The blend ends where the outgoing song's outro begins (its last bar at
/// full energy) and lets the incoming song's intro play underneath, so the
/// incoming song reaches its own full energy as the blend ends.
class DjMixPlan {
  const DjMixPlan({
    required this.mixOutStart,
    required this.blendSec,
    required this.incomingCue,
    required this.incomingStartAt,
    required this.rate,
    required this.bars,
    required this.style,
    required this.reason,
  });

  /// Outgoing position (a downbeat) where the blend starts.
  final double mixOutStart;

  /// Blend length in seconds of OUTGOING time.
  final double blendSec;

  /// Incoming position that lines up with [mixOutStart] (a downbeat).
  final double incomingCue;

  /// Where the incoming deck is opened: a muted pre-roll before
  /// [incomingCue] lets the phase lock settle before it is heard.
  final double incomingStartAt;

  /// Incoming playback-rate multiplier while blending (1 = untouched).
  final double rate;

  final int bars;
  final DjMixStyle style;
  final String reason;

  bool get beatmatched => style == DjMixStyle.beatmatch;

  double get mixOutEnd => mixOutStart + blendSec;

  /// Outgoing position at which the incoming deck must start playing.
  double get triggerAt => mixOutStart - (incomingCue - incomingStartAt) / rate;

  /// Where the incoming track should be at outgoing position [outPos].
  double expectedIncoming(double outPos) =>
      incomingCue + (outPos - mixOutStart) * rate;
}

/// EQ gains in dB for both decks at one moment of a blend.
class DjEq {
  const DjEq(this.outLow, this.outHigh, this.inLow, this.inHigh);
  final double outLow;
  final double outHigh;
  final double inLow;
  final double inHigh;

  static const flat = DjEq(0, 0, 0, 0);
}

class DjMixPlanner {
  DjMixPlanner._();

  /// How far the incoming song may be slowed down / sped up to match.
  /// Within ±8% a tempo change is not heard; beyond it the pair gets a
  /// filter blend at both songs' own speed instead of a stretched one.
  static const double maxSlowDown = 0.08;
  static const double maxSpeedUp = 0.08;

  /// Both beat grids must be at least this clear before the incoming song
  /// is retimed: matching a doubtful grid only adds wobble.
  static const double beatmatchConfidence = 0.25;

  /// Most of the outgoing song's outro / incoming song's intro a blend may
  /// skip, so a long outro or intro is never thrown away wholesale.
  static const double maxOutroSkip = 12;
  static const double maxIntroSkip = 10;

  /// Longest blend in seconds, whatever the bar count: 16 bars at a slow
  /// tempo ran 39-45 s, swallowing a big part of both songs.
  static const double maxBlendSec = 24;

  /// Most of the outgoing song a blend may cover, so a short song keeps
  /// its body (Filam, 106 s, was blended from 56 s).
  static const double maxShareOfSong = 0.2;

  /// Below this beat confidence a 16-bar request is played as 8 bars: a
  /// long overlap on a shaky grid sounds like mush.
  static const double longBlendConfidence = 0.4;

  /// A song counts as "at full energy" within this many dB of its peak.
  static const double fullEnergyDb = 4.4;

  /// Bass cut on the side that is not carrying the low end.
  static const double bassKillDb = -12;

  /// Treble trim crossed over the blend.
  static const double trebleTrimDb = -8;

  static const double preroll = 2.0;

  /// [bars] is the listener's choice (8 or 16). Returns null when the
  /// outgoing song has no usable beat grid (the player then crossfades at
  /// the end) or the windows cannot hold the blend.
  static DjMixPlan? plan({
    required TrackAnalysis outgoingTail,
    required TrackAnalysis incomingHead,
    required double outgoingDuration,
    required double incomingDuration,
    required int bars,
    bool allowTempo = true,
    double? earliestStart,
  }) {
    try {
      final requested = bars >= 16 ? 16 : 8;
      for (final b in requested == 16 ? const [16, 8] : const [8]) {
        final p = _plan(
          out: outgoingTail,
          inc: incomingHead,
          outDur: outgoingDuration,
          inDur: incomingDuration,
          bars: b,
          allowTempo: allowTempo,
          earliestStart: earliestStart,
        );
        if (p != null && isSafePlan(p, outgoingDuration: outgoingDuration)) {
          return p;
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Whatever the analysis said, a plan the engine runs must be finite,
  /// inside both tracks and within the tempo limits.
  static bool isSafePlan(DjMixPlan p, {required double outgoingDuration}) {
    bool f(double v) => v.isFinite;
    if (!f(p.mixOutStart) ||
        !f(p.blendSec) ||
        !f(p.incomingCue) ||
        !f(p.incomingStartAt) ||
        !f(p.rate)) {
      return false;
    }
    if (p.blendSec < 2 || p.blendSec > 60) return false;
    if (!rateAllowed(p.rate)) return false;
    if (!p.beatmatched && p.rate != 1.0) return false;
    if (p.mixOutStart < 0 || p.triggerAt < 0) return false;
    if (p.mixOutEnd > outgoingDuration + 0.05) return false;
    if (p.incomingCue < 0 || p.incomingStartAt < 0) return false;
    if (p.incomingStartAt > p.incomingCue + 1e-6) return false;
    if (p.incomingCue - p.incomingStartAt > preroll + 1e-6) return false;
    return true;
  }

  static bool rateAllowed(double rate) => rate >= 1
      ? rate - 1 <= maxSpeedUp + 1e-9
      : 1 - rate <= maxSlowDown + 1e-9;

  /// End of the outgoing song's last stretch at full energy: where its
  /// outro begins. Null when the window never reaches full energy.
  static double? outroStart(TrackAnalysis t) {
    final e = t.energyDb;
    if (e.length < 3) return null;
    final thr = e.reduce(math.max) - fullEnergyDb;
    for (var i = e.length - 2; i >= 0; i--) {
      if (e[i] >= thr && e[i + 1] >= thr) {
        return math.min(t.contentEnd, t.windowStart + (i + 2) * t.energyHop);
      }
    }
    return null;
  }

  /// Start of the incoming song's first stretch at full energy: where its
  /// intro ends. Null when the window never reaches full energy.
  static double? introEnd(TrackAnalysis t) {
    final e = t.energyDb;
    if (e.length < 3) return null;
    final thr = e.reduce(math.max) - fullEnergyDb;
    for (var i = 0; i < e.length - 1; i++) {
      if (e[i] >= thr && e[i + 1] >= thr) return t.windowStart + i * t.energyHop;
    }
    return null;
  }

  static DjMixPlan? _plan({
    required TrackAnalysis out,
    required TrackAnalysis inc,
    required double outDur,
    required double inDur,
    required int bars,
    required bool allowTempo,
    double? earliestStart,
  }) {
    if (!out.hasBeat) return null;
    final outBeat = out.beatPeriod;
    final bar = 4 * outBeat;

    // ---- tempo ----------------------------------------------------------
    var rate = 1.0;
    var style = DjMixStyle.filter;
    if (allowTempo &&
        inc.hasBeat &&
        out.confidence >= beatmatchConfidence &&
        inc.confidence >= beatmatchConfidence) {
      var best = double.infinity;
      // Half / double time count as the same groove.
      for (final m in const [0.5, 1.0, 2.0]) {
        final r = out.bpm / (inc.bpm * m);
        if ((r - 1).abs() < (best - 1).abs()) best = r;
      }
      if (rateAllowed(best)) {
        rate = best;
        style = DjMixStyle.beatmatch;
      }
    }
    // A shaky grid keeps to 8 bars. A filter blend only needs the
    // outgoing grid (the incoming song is placed on its own downbeat).
    final conf = style == DjMixStyle.beatmatch
        ? math.min(out.confidence, inc.confidence)
        : out.confidence;
    if (bars == 16 && conf < longBlendConfidence) return null;
    final blendSec = bars * bar;
    // Too long for this tempo or this song: the caller tries 8 bars.
    if (blendSec > maxBlendSec || blendSec > outDur * maxShareOfSong) {
      return null;
    }

    // ---- outgoing: end on the outro, start on a downbeat ----------------
    final contentEnd = math.min(out.contentEnd, outDur);
    final outro =
        math.max(outroStart(out) ?? contentEnd, contentEnd - maxOutroSkip);
    final latestStart = math.min(outro, contentEnd) - blendSec;
    final outGrid = out.downbeats.isNotEmpty ? out.downbeats : out.beats;
    double? start;
    for (final d in outGrid.reversed) {
      if (d <= latestStart + 0.02) {
        start = d;
        break;
      }
    }
    // The listener jumped past the natural mix point: start on the first
    // downbeat from [earliestStart] instead, if the blend still fits before
    // the song's last sound (the caller then tries 8 bars).
    if (earliestStart != null && (start == null || start < earliestStart)) {
      start = null;
      for (final d in outGrid) {
        if (d >= earliestStart) {
          start = d;
          break;
        }
      }
      if (start == null || start + blendSec > contentEnd + 0.05) return null;
    }
    if (start == null || start < out.windowStart + 0.5) return null;

    // ---- incoming: intro underneath, full energy as the blend ends ------
    final inGrid = inc.downbeats.isNotEmpty ? inc.downbeats : inc.beats;
    final firstDown = inGrid.isEmpty
        ? null
        : inGrid.firstWhere((d) => d >= inc.audibleStart - 0.08,
            orElse: () => inGrid.last);
    double cue;
    if (style == DjMixStyle.beatmatch && firstDown != null) {
      final ie = introEnd(inc);
      final full = inGrid.firstWhere(
          (d) => d >= math.max(ie ?? firstDown, firstDown) - 0.08,
          orElse: () => firstDown);
      cue = math.min(full - blendSec * rate, firstDown + maxIntroSkip);
      if (cue < firstDown) {
        cue = firstDown;
      } else {
        // Snap to the incoming downbeat it should already sit on.
        final target = cue;
        cue = inGrid.reduce(
            (a, b) => (a - target).abs() <= (b - target).abs() ? a : b);
        if (cue < firstDown) cue = firstDown;
      }
    } else {
      // Filter mix: the incoming song starts on its first downbeat (or its
      // first sound) exactly on the outgoing downbeat.
      cue = firstDown ?? math.max(0.0, inc.audibleStart - 0.05);
    }
    if (cue + blendSec * rate + 5 >= inDur) return null;
    final startAt = math.max(0.0, cue - (style == DjMixStyle.beatmatch ? preroll : 0));

    return DjMixPlan(
      mixOutStart: start,
      blendSec: blendSec,
      incomingCue: cue,
      incomingStartAt: startAt,
      rate: rate,
      bars: bars,
      style: style,
      reason: style == DjMixStyle.beatmatch
          ? 'beatmatch ${out.bpm.toStringAsFixed(1)}->${inc.bpm.toStringAsFixed(1)}'
          : 'filter ${out.bpm.toStringAsFixed(1)}->'
              '${inc.hasBeat ? inc.bpm.toStringAsFixed(1) : '?'}',
    );
  }

  /// Deck gains (outgoing, incoming) at [progress] (0..1) through a blend.
  ///
  /// Beatmatched: the incoming song comes up over the first 60% while the
  /// outgoing one holds full level for the first 40%, then lets go. With
  /// the basses swapped and the treble crossed, two matched grooves at full
  /// level sound like one. Otherwise: equal power on a straight angle, so
  /// loudness stays level and both songs stay clearly audible across the
  /// whole blend instead of crossing over quickly in the middle.
  static (double, double) gains({
    required bool beatmatched,
    required double progress,
  }) {
    final p = progress.clamp(0.0, 1.0);
    double smooth(double x) {
      final t = x.clamp(0.0, 1.0);
      return t * t * (3 - 2 * t);
    }

    if (beatmatched) {
      return (
        math.cos(smooth((p - 0.4) / 0.6) * math.pi / 2),
        math.sin(smooth(p / 0.6) * math.pi / 2),
      );
    }
    final a = p * math.pi / 2;
    return (math.cos(a), math.sin(a));
  }

  /// Deck EQ at [progress] (0..1) through the blend.
  ///
  /// Beatmatch: the basses swap over one bar at the midpoint so two kick
  /// drums never play at full weight together; the treble crosses over the
  /// whole blend. Filter mix: the outgoing deck drains its lows across the
  /// blend while the incoming one opens its highs, with the same one-bar
  /// bass handover at the midpoint.
  static DjEq eqAt(DjMixPlan p, double progress) =>
      eqFor(beatmatched: p.beatmatched, bars: p.bars, progress: progress);

  /// [eqAt] without a plan: the plain end-of-song crossfade uses the filter
  /// shape with an 8-bar-wide swap.
  static DjEq eqFor({
    required bool beatmatched,
    required int bars,
    required double progress,
  }) {
    final t = progress.clamp(0.0, 1.0);
    double smooth(double x) {
      final v = x.clamp(0.0, 1.0);
      return v * v * (3 - 2 * v);
    }

    final barFrac = 1 / bars;
    final swap = smooth((t - (0.5 - barFrac / 2)) / barFrac);
    if (beatmatched) {
      return DjEq(
        bassKillDb * swap,
        trebleTrimDb * smooth(t),
        bassKillDb * (1 - swap),
        trebleTrimDb * (1 - smooth(t)),
      );
    }
    return DjEq(
      bassKillDb * math.max(smooth(t), swap),
      0,
      bassKillDb * (1 - swap),
      bassKillDb * (1 - smooth(t)),
    );
  }
}

/// What the phase lock wants done to the incoming deck this tick.
class DjLockAction {
  const DjLockAction({this.seekTo, this.rate});

  /// Jump the (still muted) incoming deck here, in seconds.
  final double? seekTo;

  /// New playback rate for the incoming deck (absolute, includes speed).
  final double? rate;

  static const none = DjLockAction();
}

/// Keeps the incoming deck on the outgoing deck's beat grid.
///
/// mpv's playback clock advances in audio-buffer chunks, so one position
/// reading is ±30 ms noisy. The lock [sample]s every tick and acts every
/// [interval] on the averaged error: while the incoming deck is still muted
/// a large error is fixed with a seek; after that only small speed nudges
/// (≤3%, kept in pitch by scaletempo), so the two grooves stay locked
/// without anything being heard to jump.
class DjBeatLock {
  DjBeatLock(this.plan, {required this.speed});

  final DjMixPlan plan;
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

  /// Mean absolute phase error while audible, seconds.
  double get meanAudibleError => _count == 0 ? 0 : _absSum / _count;

  void sample(double outPos, double inPos) {
    if (!plan.beatmatched || inPos <= 0 || outPos <= 0) return;
    _sum += inPos - plan.expectedIncoming(outPos);
    _n++;
    _lastOut = outPos;
  }

  DjLockAction step(DateTime now) {
    if (!plan.beatmatched) return DjLockAction.none;
    if (now.difference(_lastStep) < interval || _n < 4) {
      return DjLockAction.none;
    }
    _lastStep = now;
    final err = _sum / _n;
    _sum = 0;
    _n = 0;
    final audible = _lastOut >= plan.mixOutStart;
    if (audible) {
      _absSum += err.abs();
      _count++;
    }
    if (!audible &&
        err.abs() > 0.12 &&
        now.difference(_lastSeek) > const Duration(seconds: 1)) {
      _lastSeek = now;
      return DjLockAction(seekTo: plan.expectedIncoming(_lastOut) + 0.03);
    }
    // Remove the error over ~1 s; ignore what is inside the noise floor.
    final e = err.abs() < 0.008 ? 0.0 : err;
    final corr = (-e).clamp(-0.03, 0.03);
    final rate = speed * plan.rate * (1 + corr);
    if ((rate - _lastRate).abs() > 0.0005) {
      _lastRate = rate;
      return DjLockAction(rate: rate);
    }
    return DjLockAction.none;
  }
}
