// ignore_for_file: avoid_print
// Decodes a real file through libmpv's pcm output and analyses it.
// Needs a system libmpv and ffmpeg (skipped when either is missing).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/automix/automix_analyzer.dart';

void main() {
  final hasMpv = File('/usr/lib/x86_64-linux-gnu/libmpv.so.2').existsSync();
  final fixture = Platform.environment['AUTOMIX_FIXTURE'] ?? '';
  test('analysis deck decodes head and tail to PCM', () async {
    final logs = <String>[];
    final tmp = await Directory.systemTemp.createTemp('automix');
    final a = AutomixAnalyzer(
      serialize: <T>(op) => op(),
      log: logs.add,
      cacheDir: tmp.path,
    );
    final head = await a.request(
        key: 'k|s|head', side: AnalysisSide.head, url: fixture);
    final tail = await a.request(
        key: 'k|s|tail',
        side: AnalysisSide.tail,
        url: fixture,
        duration: Duration(
            milliseconds:
                int.parse(Platform.environment['AUTOMIX_FIXTURE_MS'] ?? '0')));

    logs.forEach(print);
    expect(head, isNotNull);
    expect(tail, isNotNull);
    expect(head!.bpm, closeTo(124, 0.5));
    expect(head.audibleStart, closeTo(3.0, 0.1));
    expect(tail!.contentEnd, closeTo(144.0, 0.2));
    expect(tail.bpm, closeTo(124, 0.5));
  }, skip: !hasMpv || fixture.isEmpty);
}
