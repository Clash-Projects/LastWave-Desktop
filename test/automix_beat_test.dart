import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/automix/audio_analysis.dart';
import 'package:lastwave_desktop/features/automix/beat_mix_planner.dart';

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
      expect(a.hasBeat && a.confidence >= BeatMixPlanner.minConfidence, isFalse);
    });

    test('json round trip', () {
      final a = analyzePcm(drums(bpm: 120, seconds: 20), sr);
      final b = TrackAnalysis.fromJson(a.toJson())!;
      expect(b.bpm, a.bpm);
      expect(b.downbeats, a.downbeats);
    });
  });

  group('planner', () {
    final tail = analyzePcm(drums(bpm: 124, seconds: 60, tail: 6), sr,
        offsetSeconds: 140);
    final head = analyzePcm(drums(bpm: 128, seconds: 60, intro: 2.2), sr);

    test('beat-matches close tempi on downbeats, before the silent tail', () {
      final p = BeatMixPlanner.plan(
        outgoingTail: tail,
        incomingHead: head,
        outgoingDuration: 200,
        incomingDuration: 180,
        maxOverlap: 20,
      )!;
      expect(p.beatMatched, isTrue);
      expect(p.rate, closeTo(124 / 128, 0.003));
      expect(p.beats, 32);
      expect(tail.downbeats, contains(p.mixOutStart));
      expect(head.downbeats, contains(p.incomingCue));
      expect(p.mixOutEnd, lessThanOrEqualTo(tail.contentEnd + 0.02));
      expect(p.incomingCue, greaterThanOrEqualTo(2.2 - 0.08));
      // Incoming downbeats land on outgoing beats across the blend.
      for (var k = 0; k <= 32; k += 4) {
        final outBeat = p.mixOutStart + k * tail.beatPeriod;
        final inBeat = p.incomingCue + k * head.beatPeriod;
        expect(p.expectedIncoming(outBeat), closeTo(inBeat, 0.03));
      }
    });

    test('far tempi fall back to a blend that still skips dead air', () {
      final slow = analyzePcm(drums(bpm: 90, seconds: 60, intro: 4), sr);
      final p = BeatMixPlanner.plan(
        outgoingTail: tail,
        incomingHead: slow,
        outgoingDuration: 200,
        incomingDuration: 180,
        maxOverlap: 12,
      )!;
      expect(p.beatMatched, isFalse);
      expect(p.rate, 1.0);
      expect(p.mixOutEnd, closeTo(tail.contentEnd, 0.01));
      expect(p.incomingCue, closeTo(3.95, 0.1));
    });

    test('tempo change is not used when pitch shifting is on', () {
      final p = BeatMixPlanner.plan(
        outgoingTail: tail,
        incomingHead: head,
        outgoingDuration: 200,
        incomingDuration: 180,
        maxOverlap: 20,
        allowTempo: false,
      )!;
      expect(p.beatMatched, isFalse);
    });
  });

  test('beat lock pulls a late, noisy deck onto the grid', () {
    final plan = BeatMixPlan(
      mixOutStart: 100,
      overlap: 15,
      incomingCue: 5,
      incomingStartAt: 2,
      rate: 0.97,
      beatMatched: true,
      beats: 32,
      reason: 'test',
    );
    final lock = BeatLock(plan, speed: 1);
    final rnd = math.Random(7);
    var now = DateTime(2026);
    var out = plan.triggerAt;
    var inc = plan.incomingStartAt - 0.4 * 0.97; // started 400 ms late
    var rate = 0.97;
    const dt = 0.025;
    while (out < plan.mixOutEnd) {
      out += dt;
      inc += dt * rate;
      now = now.add(const Duration(milliseconds: 25));
      // ±30 ms clock jitter on each reading, like mpv's chunked clock.
      lock.sample(out + (rnd.nextDouble() - 0.5) * 0.06,
          inc + (rnd.nextDouble() - 0.5) * 0.06);
      final a = lock.step(now);
      if (a.seekTo != null) inc = a.seekTo!;
      if (a.rate != null) rate = a.rate!;
      // Never an audible wobble beyond ±3%.
      expect((rate / 0.97 - 1).abs(), lessThanOrEqualTo(0.0301));
    }
    expect(lock.meanAudibleError, lessThan(0.015));
  });
}
