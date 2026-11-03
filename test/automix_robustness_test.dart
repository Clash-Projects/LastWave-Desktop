import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/automix/audio_analysis.dart';
import 'package:lastwave_desktop/features/automix/automix_analyzer.dart';
import 'package:lastwave_desktop/features/automix/beat_mix_planner.dart';
import 'package:lastwave_desktop/features/automix/mix_guard.dart';

DeckReading deck({double volume = 70, bool playing = true, double rate = 1}) =>
    DeckReading(volume: volume, playing: playing, rate: rate);

MixGuardInput input({
  bool mixing = false,
  bool armed = false,
  bool ramping = false,
  DeckReading? primary,
  DeckReading? standby,
  Duration mixAge = Duration.zero,
  bool resolving = false,
}) =>
    MixGuardInput(
      mixing: mixing,
      armed: armed,
      ramping: ramping,
      fullVolume: 70,
      expectedRate: 1,
      primary: primary ?? deck(),
      standby: standby,
      mixAge: mixAge,
      resolving: resolving,
    );

TrackAnalysis analysis({
  double bpm = 120,
  double conf = 0.9,
  double ws = 0,
  double we = 60,
  double as = 1,
  double ce = 59,
  List<double>? beats,
}) {
  final b = beats ?? [for (var t = ws + 0.5; t < we; t += 60 / bpm) t];
  return TrackAnalysis(
    windowStart: ws,
    windowEnd: we,
    bpm: bpm,
    confidence: conf,
    beats: b,
    downbeats: [for (var i = 0; i < b.length; i += 4) b[i]],
    audibleStart: as,
    contentEnd: ce,
    energyDb: const [],
  );
}

void main() {
  group('mix guard', () {
    test('a healthy idle state needs nothing', () {
      expect(checkMix(input(standby: deck(volume: 0, playing: false))),
          isEmpty);
    });

    test('primary left quiet after a mix is restored (the mute bug)', () {
      expect(checkMix(input(primary: deck(volume: 0.0001))),
          contains(MixRepair.restorePrimaryVolume));
    });

    test('an audible or playing standby is silenced', () {
      expect(checkMix(input(standby: deck(volume: 40))),
          contains(MixRepair.silenceStandby));
      expect(checkMix(input(standby: deck(volume: 0, playing: true))),
          contains(MixRepair.silenceStandby));
      // Armed and silent is the normal pre-mix state.
      expect(
          checkMix(input(
              armed: true, standby: deck(volume: 0, playing: false))),
          isEmpty);
    });

    test('a tempo left over from beat-matching is undone, not mid-glide', () {
      expect(checkMix(input(primary: deck(rate: 0.97))),
          contains(MixRepair.restoreRate));
      expect(checkMix(input(ramping: true, primary: deck(rate: 0.97))),
          isEmpty);
    });

    test('a mix is left alone while running, aborted when stuck', () {
      expect(
          checkMix(input(
              mixing: true,
              primary: deck(volume: 10),
              standby: deck(volume: 60),
              mixAge: const Duration(seconds: 10))),
          isEmpty);
      expect(checkMix(input(mixing: true, mixAge: const Duration(seconds: 90))),
          [MixRepair.abortStuckMix]);
    });

    test('nothing is touched while a track change is resolving', () {
      expect(checkMix(input(resolving: true, primary: deck(volume: 0))),
          isEmpty);
    });
  });

  test('fault budget steps down: beat-matching first, then overlap', () {
    final b = MixFaultBudget();
    expect(b.beatMixAllowed && b.overlapAllowed, isTrue);
    b.record();
    b.record();
    expect(b.record(), contains('beat-matching off'));
    expect(b.beatMixAllowed, isFalse);
    expect(b.overlapAllowed, isTrue);
    b.record();
    b.record();
    expect(b.record(), contains('overlap off'));
    expect(b.overlapAllowed, isFalse);
  });

  group('sanitizeAnalysis', () {
    test('keeps a normal analysis', () {
      expect(sanitizeAnalysis(analysis()), isNotNull);
    });

    test('rejects impossible values', () {
      expect(sanitizeAnalysis(analysis(bpm: double.nan)), isNull);
      expect(sanitizeAnalysis(analysis(bpm: 900)), isNull);
      expect(sanitizeAnalysis(analysis(conf: 3)), isNull);
      expect(sanitizeAnalysis(analysis(as: 30, ce: 10)), isNull);
      expect(sanitizeAnalysis(analysis(beats: [1, 3, 2])), isNull);
      expect(sanitizeAnalysis(analysis(ws: 10, we: 5)), isNull);
    });
  });

  group('plan safety', () {
    test('a garbage analysis never yields an unsafe plan', () {
      final tail = analysis(ws: 140, we: 200, ce: 1e9, beats: []);
      final head = analysis(as: -50);
      final p = BeatMixPlanner.plan(
        outgoingTail: tail,
        incomingHead: head,
        outgoingDuration: 200,
        incomingDuration: 180,
        maxOverlap: 14,
      );
      if (p != null) {
        expect(
            BeatMixPlanner.isSafePlan(p,
                outgoingDuration: 200, maxOverlap: 14),
            isTrue);
      }
    });

    test('isSafePlan rejects out-of-range plans', () {
      const ok = BeatMixPlan(
        mixOutStart: 180,
        overlap: 12,
        incomingCue: 2,
        incomingStartAt: 0,
        rate: 0.98,
        beatMatched: true,
        beats: 24,
        reason: 't',
      );
      expect(BeatMixPlanner.isSafePlan(ok, outgoingDuration: 200, maxOverlap: 14),
          isTrue);
      BeatMixPlan with_({double? overlap, double? rate, double? out}) =>
          BeatMixPlan(
            mixOutStart: out ?? ok.mixOutStart,
            overlap: overlap ?? ok.overlap,
            incomingCue: ok.incomingCue,
            incomingStartAt: ok.incomingStartAt,
            rate: rate ?? ok.rate,
            beatMatched: true,
            beats: 24,
            reason: 't',
          );
      for (final bad in [
        with_(overlap: 30),
        with_(rate: 0.8),
        with_(rate: double.nan),
        with_(out: 195),
      ]) {
        expect(
            BeatMixPlanner.isSafePlan(bad,
                outgoingDuration: 200, maxOverlap: 14),
            isFalse);
      }
    });
  });

  group('analyzer', () {
    Int16List tone() => Int16List(11025 * 20);

    test('skips jobs that went stale while queued, without blacklisting',
        () async {
      final dir = await Directory.systemTemp.createTemp('an');
      var wantB = false;
      var decodes = 0;
      final a = AutomixAnalyzer(
        serialize: <T>(op) => op(),
        log: (_) {},
        cacheDir: dir.path,
        wanted: (k) => k == 'a' || wantB,
        decoder: (side, url, h, d) async {
          decodes++;
          return tone();
        },
      );
      final ra = a.request(key: 'a', side: AnalysisSide.head, url: 'x');
      final rb = a.request(key: 'b', side: AnalysisSide.head, url: 'x');
      expect(await ra, isNotNull);
      expect(await rb, isNull);
      expect(decodes, 1);
      // Wanted again later: it runs.
      wantB = true;
      expect(await a.request(key: 'b', side: AnalysisSide.head, url: 'x'),
          isNotNull);
    });

    test('turns itself off after repeated decode failures', () async {
      final dir = await Directory.systemTemp.createTemp('an');
      var decodes = 0;
      final a = AutomixAnalyzer(
        serialize: <T>(op) => op(),
        log: (_) {},
        cacheDir: dir.path,
        decoder: (side, url, h, d) async {
          decodes++;
          return null;
        },
      );
      for (var i = 0; i < 10; i++) {
        await a.request(key: 'k$i', side: AnalysisSide.head, url: 'x');
      }
      expect(decodes, AutomixAnalyzer.maxConsecutiveFailures);
      expect(a.disabled, isTrue);
    });

    test('a crash during a decode disables analysis on the next launch',
        () async {
      final dir = await Directory.systemTemp.createTemp('an');
      File('${dir.path}${Platform.pathSeparator}decode-in-progress')
          .writeAsStringSync('x');
      final logs = <String>[];
      final a = AutomixAnalyzer(
          serialize: <T>(op) => op(), log: logs.add, cacheDir: dir.path);
      expect(a.disabled, isTrue);
      expect(logs.single, contains('previous run ended during'));
      // One-shot: the launch after that tries again.
      final b = AutomixAnalyzer(
          serialize: <T>(op) => op(), log: (_) {}, cacheDir: dir.path);
      expect(b.disabled, isFalse);
    });

    test('a corrupt cache file is ignored and removed', () async {
      final dir = await Directory.systemTemp.createTemp('an');
      final a = AutomixAnalyzer(
        serialize: <T>(op) => op(),
        log: (_) {},
        cacheDir: dir.path,
        decoder: (side, url, h, d) async => tone(),
      );
      await a.request(key: 'k', side: AnalysisSide.head, url: 'x');
      // The cache write is fire-and-forget.
      var files = <File>[];
      for (var i = 0; i < 50 && files.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        files = dir.listSync().whereType<File>().toList();
      }
      expect(files, hasLength(1));
      files.single.writeAsStringSync('{"key":"k","a":{"v":1,"bpm":"x"}}');
      final fresh = AutomixAnalyzer(
        serialize: <T>(op) => op(),
        log: (_) {},
        cacheDir: dir.path,
        decoder: (side, url, h, d) async => tone(),
      );
      expect(await fresh.request(key: 'k', side: AnalysisSide.head, url: 'x'),
          isNotNull);
    });
  });
}
