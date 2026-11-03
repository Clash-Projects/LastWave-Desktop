// ignore_for_file: avoid_print
// Two real libmpv decks (null audio output, real-time clock) running the
// production planner + phase lock. Needs a system libmpv and fixtures
// from AUTOMIX_FIXTURE_A / _B; skipped otherwise.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/automix/automix_analyzer.dart';
import 'package:lastwave_desktop/features/automix/beat_mix_planner.dart';
import 'package:media_kit/media_kit.dart';

double secs(Duration d) => d.inMicroseconds / 1e6;

Future<double> clock(Player p) async {
  try {
    final v = await (p.platform as dynamic).getProperty('time-pos') as String;
    return double.tryParse(v) ?? secs(p.state.position);
  } catch (_) {
    return secs(p.state.position);
  }
}

Future<Player> deck() async {
  final p = Player(configuration: const PlayerConfiguration(vo: 'null'));
  final dyn = p.platform as dynamic;
  await dyn.setProperty('ao', 'null');
  await dyn.setProperty('audio-pitch-correction', 'yes');
  return p;
}

void main() {
  final a = Platform.environment['AUTOMIX_FIXTURE_A'] ?? '';
  final b = Platform.environment['AUTOMIX_FIXTURE_B'] ?? '';
  final hasMpv = File('/usr/lib/x86_64-linux-gnu/libmpv.so.2').existsSync();

  test('beat-matched mix stays locked on real decks', () async {
    MediaKit.ensureInitialized();
    final tmp = await Directory.systemTemp.createTemp('automix');
    final an = AutomixAnalyzer(
        serialize: <T>(op) => op(), log: print, cacheDir: tmp.path);
    final tail = await an.request(
        key: 'a|tail',
        side: AnalysisSide.tail,
        url: a,
        duration: const Duration(seconds: 150));
    final head =
        await an.request(key: 'b|head', side: AnalysisSide.head, url: b);
    final plan = BeatMixPlanner.plan(
      outgoingTail: tail!,
      incomingHead: head!,
      outgoingDuration: 150,
      incomingDuration: 140,
      maxOverlap: 20,
    )!;
    print('plan ${plan.reason} out=${plan.mixOutStart} in=${plan.incomingCue} '
        'startAt=${plan.incomingStartAt} rate=${plan.rate} beats=${plan.beats}');
    expect(plan.beatMatched, isTrue);
    expect(plan.rate, closeTo(124 / 128, 0.003));

    final out = await deck();
    final inc = await deck();
    await out.open(Media(a,
        start: Duration(milliseconds: ((plan.triggerAt - 2) * 1000).round())));
    await inc.open(
        Media(b,
            start: Duration(
                milliseconds: (plan.incomingStartAt * 1000).round())),
        play: false);
    // Wait for the trigger point, then start 350 ms LATE on purpose.
    while (secs(out.state.position) < plan.triggerAt) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await Future<void>.delayed(const Duration(milliseconds: 350));
    await inc.setRate(plan.rate);
    await inc.play();
    final lock = BeatLock(plan, speed: 1.0);
    final errs = <double>[];
    var lastLog = DateTime.now();
    while (true) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      final op = await clock(out);
      final ip = await clock(inc);
      if (op >= plan.mixOutEnd) break;
      lock.sample(op, ip);
      final act = lock.step(DateTime.now());
      if (act.seekTo != null) {
        await inc.seek(Duration(milliseconds: (act.seekTo! * 1000).round()));
      } else if (act.rate != null) {
        await inc.setRate(act.rate!);
      }
      if (DateTime.now().difference(lastLog) >
          const Duration(milliseconds: 1990)) {
        lastLog = DateTime.now();
        print('t op=${op.toStringAsFixed(2)} '
            'avg_err=${(lock.lastError * 1000).round()}ms '
            'rate=${inc.state.rate.toStringAsFixed(4)}');
      }
      if (op >= plan.mixOutStart) errs.add(ip - plan.expectedIncoming(op));
    }
    errs.sort((x, y) => x.abs().compareTo(y.abs()));
    final p90 = errs[(errs.length * 0.9).floor()].abs();
    print('audible ticks=${errs.length} mean_abs_ms='
        '${(lock.meanAudibleError * 1000).round()} p90_ms=${(p90 * 1000).round()}');
    expect(lock.meanAudibleError, lessThan(0.015));
    await out.dispose();
    await inc.dispose();
  }, skip: !hasMpv || a.isEmpty || b.isEmpty, timeout: const Timeout(Duration(minutes: 2)));
}
