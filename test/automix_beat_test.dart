import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/automix/audio_analysis.dart';
import 'package:lastwave_desktop/features/automix/outro_mix_planner.dart';

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

  group('outro planner', () {
    // Fades the last [fade] seconds before the silent [tail] down to silence.
    Int16List fadeOut(Int16List pcm, {required double fade, double tail = 0}) {
      final out = Int16List.fromList(pcm);
      final end = out.length - (tail * sr).round();
      final start = end - (fade * sr).round();
      for (var k = start; k < end; k++) {
        out[k] = (out[k] * (1 - (k - start) / (end - start))).round();
      }
      return out;
    }

    final head = analyzePcm(drums(bpm: 128, seconds: 60, intro: 2.2), sr);

    test('blends over the outgoing fade and ends on its last sound', () {
      final tail = analyzePcm(
          fadeOut(drums(bpm: 124, seconds: 60, tail: 4), fade: 10, tail: 4),
          sr,
          offsetSeconds: 140);
      final p = OutroMixPlanner.plan(
        outgoingTail: tail,
        incomingHead: head,
        outgoingDuration: 200,
        incomingDuration: 180,
        maxOverlap: 14,
      )!;
      // The song is never cut: the blend ends where its sound ends.
      expect(p.mixOutEnd, closeTo(tail.contentEnd, 0.01));
      expect(p.mixOutEnd, lessThanOrEqualTo(200));
      // The blend follows the fade, kept short.
      expect(p.overlap, inInclusiveRange(OutroMixPlanner.minOverlap, 14));
      expect(p.faded, isTrue);
      expect(p.reason, startsWith('outro fade'));
      // Incoming starts at its first sound, only the silence is skipped.
      expect(p.incomingCue, closeTo(2.15, 0.15));
    });

    test('a hard ending gets a short blend so it is not covered', () {
      final tail = analyzePcm(drums(bpm: 124, seconds: 60, tail: 3), sr,
          offsetSeconds: 140);
      final p = OutroMixPlanner.plan(
        outgoingTail: tail,
        incomingHead: head,
        outgoingDuration: 200,
        incomingDuration: 180,
        maxOverlap: 14,
      )!;
      expect(p.overlap,
          inInclusiveRange(OutroMixPlanner.minOverlap, OutroMixPlanner.hardEndOverlap + 3));
      expect(p.faded, isFalse);
      expect(p.mixOutEnd, closeTo(tail.contentEnd, 0.01));
      expect(p.reason, startsWith('hard end'));
    });

    test('a long fade never blends longer than allowed', () {
      final tail = analyzePcm(
          fadeOut(drums(bpm: 124, seconds: 60), fade: 25), sr,
          offsetSeconds: 140);
      final p = OutroMixPlanner.plan(
        outgoingTail: tail,
        incomingHead: head,
        outgoingDuration: 200,
        incomingDuration: 180,
        maxOverlap: 8,
      )!;
      expect(p.overlap, lessThanOrEqualTo(8));
      expect(p.mixOutEnd, closeTo(tail.contentEnd, 0.01));
    });

    test('the incoming downbeat lands on an outgoing downbeat, speed untouched',
        () {
      final tail = analyzePcm(
          fadeOut(drums(bpm: 124, seconds: 60, tail: 4), fade: 10, tail: 4),
          sr,
          offsetSeconds: 140);
      final p = OutroMixPlanner.plan(
        outgoingTail: tail,
        incomingHead: head,
        outgoingDuration: 200,
        incomingDuration: 180,
        maxOverlap: 14,
      )!;
      expect(p.reason, endsWith('on-beat'));
      // Nothing of the incoming song is skipped: it starts at its first sound.
      expect(p.incomingCue, closeTo(head.audibleStart - 0.05, 0.001));
      final firstDown = head.downbeats.firstWhere((d) => d >= p.incomingCue);
      final landsAt = p.mixOutStart + (firstDown - p.incomingCue);
      final nearest = tail.downbeats
          .reduce((a, b) => (a - landsAt).abs() < (b - landsAt).abs() ? a : b);
      expect(landsAt, closeTo(nearest, 0.02));
      expect(p.mixOutEnd, closeTo(tail.contentEnd, 0.01));
    });
  });
}
