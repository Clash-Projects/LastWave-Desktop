import 'dart:math' as math;

import 'audio_analysis.dart';

/// A transition placed on real audio. Both songs play at their own speed
/// from start to finish: the blend rides the outgoing song's own outro and
/// ends on its last audible moment, so nothing the listener would hear is
/// cut, sped up or stretched.
///
/// Times are seconds on each track's own timeline.
class OutroMixPlan {
  const OutroMixPlan({
    required this.mixOutStart,
    required this.overlap,
    required this.incomingCue,
    required this.reason,
  });

  /// Outgoing position where the incoming song starts and the blend begins.
  final double mixOutStart;

  /// Blend length in seconds.
  final double overlap;

  /// Where the incoming song is opened: its first sound (only leading
  /// silence is skipped).
  final double incomingCue;

  final String reason;

  /// The outgoing song's last audible moment: the blend ends here.
  double get mixOutEnd => mixOutStart + overlap;
}

class OutroMixPlanner {
  OutroMixPlanner._();

  /// Shortest blend worth doing.
  static const double minOverlap = 3;

  /// Blend for a song that stops dead instead of fading: short, so the
  /// incoming song does not cover the ending.
  static const double hardEndOverlap = 4;

  /// How far below the song's body level the outro must sit to count as
  /// its fade-out.
  static const double fadeDropDb = 4;

  /// [outgoingTail] / [incomingHead] are analyses of the last / first
  /// minute. [maxOverlap] already includes the user's setting and the
  /// short-track cap. Returns null when the windows cannot support a mix.
  static OutroMixPlan? plan({
    required TrackAnalysis outgoingTail,
    required TrackAnalysis incomingHead,
    required double outgoingDuration,
    required double incomingDuration,
    required double maxOverlap,
  }) {
    try {
      final p = _plan(
        outgoingTail: outgoingTail,
        incomingHead: incomingHead,
        outgoingDuration: outgoingDuration,
        incomingDuration: incomingDuration,
        maxOverlap: maxOverlap,
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
  /// runs must be finite, inside both tracks and no longer than allowed.
  static bool isSafePlan(OutroMixPlan p,
      {required double outgoingDuration, required double maxOverlap}) {
    bool f(double v) => v.isFinite;
    if (!f(p.mixOutStart) || !f(p.overlap) || !f(p.incomingCue)) return false;
    if (p.overlap < minOverlap - 1e-6 || p.overlap > maxOverlap + 0.01) {
      return false;
    }
    if (p.mixOutStart < 0 || p.incomingCue < 0) return false;
    if (p.mixOutEnd > outgoingDuration + 0.5) return false;
    return true;
  }

  /// Seconds of fade-out before the outgoing song's last sound: how long
  /// its level stays clearly below the body of the song. 0 for a song
  /// that stops at full level.
  static double outroLength(TrackAnalysis tail) {
    final e = tail.energyDb;
    final hop = tail.energyHop;
    if (e.length < 8 || hop <= 0) return 0;
    final end = ((tail.contentEnd - tail.windowStart) / hop)
        .floor()
        .clamp(0, e.length);
    if (end < 8) return 0;
    // Body level: the loud part of the window, well before the ending.
    final bodyEnd = math.max(4, end - (20 / hop).round());
    final body = [...e.sublist(0, math.min(bodyEnd, end))]..sort();
    final level = body[(body.length * 0.6).floor().clamp(0, body.length - 1)];
    // 1.5 s moving average so a quiet beat inside a loud chorus does not
    // read as the start of the fade.
    double smooth(int i) {
      var sum = 0.0, n = 0;
      for (var k = i - 1; k <= i + 1; k++) {
        if (k >= 0 && k < end) {
          sum += e[k];
          n++;
        }
      }
      return n == 0 ? level : sum / n;
    }

    var i = end - 1;
    while (i >= 0 && smooth(i) < level - fadeDropDb) {
      i--;
    }
    final fadeStart = tail.windowStart + (i + 1) * hop;
    return math.max(0, tail.contentEnd - fadeStart);
  }

  static OutroMixPlan? _plan({
    required TrackAnalysis outgoingTail,
    required TrackAnalysis incomingHead,
    required double outgoingDuration,
    required double incomingDuration,
    required double maxOverlap,
  }) {
    if (maxOverlap < minOverlap) return null;
    // The outgoing song's real end: its last audible moment, never past
    // the file end. Only the silent tail after it is skipped.
    final contentEnd = math.min(outgoingTail.contentEnd, outgoingDuration);
    final fade = outroLength(outgoingTail);
    final faded = fade >= minOverlap;
    final overlap = faded
        ? math.min(fade, maxOverlap)
        : math.min(hardEndOverlap, maxOverlap);
    final start = contentEnd - overlap;
    if (start < outgoingTail.windowStart) return null;
    final cue = math.max(0.0, incomingHead.audibleStart - 0.05);
    if (cue + overlap + 5 >= incomingDuration) return null;
    return OutroMixPlan(
      mixOutStart: start,
      overlap: overlap,
      incomingCue: cue,
      reason: faded
          ? 'outro fade=${fade.toStringAsFixed(1)}s'
          : 'hard end',
    );
  }
}
