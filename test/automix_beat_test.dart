import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/automix/audio_analysis.dart';
import 'package:lastwave_desktop/features/automix/dj_mix_planner.dart';

const sr = 11025;

/// Kick on every beat (accented on "the one"), off-beat hats, a pad.
Int16List drums({
  required double bpm,
  required double seconds,
  double intro = 0,
  double tail = 0,
  double phase = 0,
  int seed = 1,
}) {
  final rnd = math.Random(seed);
  final n = (seconds * sr).round();
  final x = Float64List(n);
  final beat = 60 / bpm;
  var i = 0;
  for (var t = intro + phase; t < seconds - tail; t += beat, i++) {
    final s = (t * sr).round();
    for (var k = 0; k < (0.15 * sr) && s + k < n; k++) {
      final tt = k / sr;
      x[s + k] += math.sin(2 * math.pi * (55 + 90 * math.exp(-tt * 30)) * tt) *
          math.exp(-tt * 12) *
          (i % 4 == 0 ? 1.0 : 0.7);
    }
    final h = ((t + beat / 2) * sr).round();
    for (var k = 0; k < (0.03 * sr) && h + k < n; k++) {
      x[h + k] += (rnd.nextDouble() * 2 - 1) * 0.15 * math.exp(-k / sr * 120);
    }
  }
  for (var k = (intro * sr).round(); k < ((seconds - tail) * sr).round(); k++) {
    x[k] += 0.1 * math.sin(2 * math.pi * 220 * k / sr);
  }
  var peak = 1e-9;
  for (final v in x) {
    peak = math.max(peak, v.abs());
  }
  return Int16List.fromList([for (final v in x) (v / peak * 26000).round()]);
}

void main() {
  group('analysis', () {
    test('finds tempo, downbeat and audible start of a head window', () {
      final a = analyzePcm(drums(bpm: 126, seconds: 60, intro: 2.5), sr);
      expect(a.bpm, closeTo(126, 0.3));
      expect(a.confidence, greaterThan(0.5));
      expect(a.audibleStart, closeTo(2.5, 0.06));
      // The accented kick at 2.5s must be a downbeat.
      expect(a.downbeats.any((d) => (d - 2.5).abs() < 0.04), isTrue);
    });

    test('tail window reports times on the track timeline', () {
      final a = analyzePcm(drums(bpm: 100, seconds: 60, tail: 7), sr,
          offsetSeconds: 180);
      expect(a.bpm, closeTo(100, 0.3));
      expect(a.contentEnd, closeTo(233, 0.2));
      expect(a.beats.first, greaterThanOrEqualTo(180));
    });

    test('noise has no confident beat', () {
      final r = math.Random(3);
      final pcm = Int16List.fromList(
          List.generate(sr * 30, (_) => ((r.nextDouble() * 2 - 1) * 8000).round()));
      final a = analyzePcm(pcm, sr);
      expect(a.hasBeat && a.confidence >= 0.2, isFalse);
    });

    test('json round trip', () {
      final a = analyzePcm(drums(bpm: 120, seconds: 20), sr);
      final b = TrackAnalysis.fromJson(a.toJson())!;
      expect(b.bpm, a.bpm);
      expect(b.downbeats, a.downbeats);
    });
  });

  group('dj planner', () {
    // Last minute: full level, then a quiet [outro].
    Int16List withOutro(Int16List pcm, {required double outro}) {
      final out = Int16List.fromList(pcm);
      for (var k = out.length - (outro * sr).round(); k < out.length; k++) {
        out[k] = (out[k] * 0.25).round();
      }
      return out;
    }

    // First minute: a quiet [intro], then full level.
    Int16List withIntro(Int16List pcm, {required double intro}) {
      final out = Int16List.fromList(pcm);
      for (var k = 0; k < (intro * sr).round(); k++) {
        out[k] = (out[k] * 0.25).round();
      }
      return out;
    }

    final tail = analyzePcm(withOutro(drums(bpm: 124, seconds: 60), outro: 12),
        sr, offsetSeconds: 140);
    final head = analyzePcm(
        withIntro(drums(bpm: 128, seconds: 60, intro: 1), intro: 16), sr);

    DjMixPlan planFor({int bars = 16, bool allowTempo = true, TrackAnalysis? inc}) =>
        DjMixPlanner.plan(
          outgoingTail: tail,
          incomingHead: inc ?? head,
          outgoingDuration: 200,
          incomingDuration: 180,
          bars: bars,
          allowTempo: allowTempo,
        )!;

    test('16 bars, tempo matched, ends where the outro starts', () {
      final p = planFor();
      expect(p.style, DjMixStyle.beatmatch);
      expect(p.bars, 16);
      expect(p.rate, closeTo(124 / 128, 0.004));
      expect(p.blendSec, closeTo(16 * 4 * 60 / 124, 0.2));
      // Starts on an outgoing downbeat and ends at (or a bar before) the outro.
      expect(tail.downbeats, contains(p.mixOutStart));
      final outro = DjMixPlanner.outroStart(tail)!;
      expect(outro, closeTo(188, 1.0));
      expect(p.mixOutEnd, lessThanOrEqualTo(outro + 0.05));
      expect(outro - p.mixOutEnd, lessThan(4 * 60 / 124 + 0.05));
      // Incoming sits on a downbeat. Its 16 s intro is shorter than this
      // 31 s blend, so it starts on its first downbeat and its full-energy
      // part comes in during the blend.
      expect(head.downbeats, contains(p.incomingCue));
      expect(p.incomingCue, closeTo(head.downbeats.first, 0.6));
    });

    test('8 bars when asked; the intro plays under the blend', () {
      final p = planFor(bars: 8);
      expect(p.bars, 8);
      expect(p.blendSec, closeTo(8 * 4 * 60 / 124, 0.2));
      // 15.5 s blend under a 16 s intro: the incoming song is started so its
      // full-energy part arrives as the blend ends.
      final full = p.incomingCue + p.blendSec * p.rate;
      expect(full, closeTo(DjMixPlanner.introEnd(head)!, 2.5));
      expect(head.downbeats, contains(p.incomingCue));
    });

    test('far tempi fall back to an 8-bar filter mix at their own speed', () {
      final slow = analyzePcm(drums(bpm: 90, seconds: 60, intro: 2), sr);
      final p = planFor(inc: slow);
      expect(p.style, DjMixStyle.filter);
      expect(p.rate, 1.0);
      expect(p.bars, 8);
      expect(slow.downbeats, contains(p.incomingCue));
    });

    test('a 10% tempo gap is blended at both songs own speed, not stretched',
        () {
      final far = analyzePcm(drums(bpm: 112, seconds: 60, intro: 2), sr);
      final p = planFor(inc: far);
      expect(p.style, DjMixStyle.filter);
      expect(p.rate, 1.0);
    });

    test('dj volume curves: matched blends overlap at full, others stay level',
        () {
      final (o40, i40) = DjMixPlanner.gains(beatmatched: true, progress: 0.4);
      expect(o40, 1.0);
      expect(i40, greaterThan(0.9));
      final (o1, i1) = DjMixPlanner.gains(beatmatched: true, progress: 1);
      expect(o1, closeTo(0, 1e-9));
      expect(i1, closeTo(1, 1e-9));
      for (var k = 0; k <= 10; k++) {
        final (o, i) = DjMixPlanner.gains(beatmatched: false, progress: k / 10);
        expect(o * o + i * i, closeTo(1, 1e-9));
      }
    });

    test('no tempo change when pitch shifting is on', () {
      final p = planFor(allowTempo: false);
      expect(p.style, DjMixStyle.filter);
      expect(p.rate, 1.0);
    });

    test('basses swap over one bar at the midpoint, treble crosses', () {
      final p = planFor();
      final start = DjMixPlanner.eqAt(p, 0);
      expect(start.outLow, 0);
      expect(start.inLow, DjMixPlanner.bassKillDb);
      final before = DjMixPlanner.eqAt(p, 0.5 - 1 / 32 - 0.01);
      expect(before.outLow, 0);
      expect(before.inLow, DjMixPlanner.bassKillDb);
      final after = DjMixPlanner.eqAt(p, 0.5 + 1 / 32 + 0.01);
      expect(after.outLow, DjMixPlanner.bassKillDb);
      expect(after.inLow, 0);
      final end = DjMixPlanner.eqAt(p, 1);
      expect(end.outHigh, DjMixPlanner.trebleTrimDb);
      expect(end.inHigh, 0);
    });

    test('beat lock pulls a late, noisy deck onto the grid', () {
      final p = planFor();
      final lock = DjBeatLock(p, speed: 1);
      final rnd = math.Random(3);
      var out = p.triggerAt;
      var inc = p.incomingStartAt + 0.09; // starts 90 ms late
      var rate = p.rate;
      var t = DateTime(2026);
      const dt = 0.025;
      for (var k = 0; k < 2400; k++) {
        out += dt;
        inc += dt * rate;
        t = t.add(const Duration(milliseconds: 25));
        lock.sample(out + (rnd.nextDouble() - 0.5) * 0.06,
            inc + (rnd.nextDouble() - 0.5) * 0.06);
        final a = lock.step(t);
        if (a.seekTo != null) inc = a.seekTo!;
        if (a.rate != null) rate = a.rate!;
        expect((rate / p.rate - 1).abs(), lessThanOrEqualTo(0.0301));
      }
      expect((inc - p.expectedIncoming(out)).abs(), lessThan(0.02));
    });
  });
}
