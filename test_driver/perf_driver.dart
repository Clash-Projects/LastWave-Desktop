// Host-side driver for integration_test/perf_benchmark_test.dart.
//
// Writes one JSON file per scenario into build/ (the integration_test
// default `testOutputsDirectory`):
//   build/<scenario>.json                       watchPerformance summary
//   build/karaoke_timeline.timeline_summary.json TimelineSummary of the trace
//   build/karaoke_timeline.timeline.json         raw trace (open in Perfetto)
//
// flutter_driver ships with the Flutter SDK and is already a transitive
// dependency of integration_test, so no pubspec entry is added for it.
// ignore: depend_on_referenced_packages
import 'package:flutter_driver/flutter_driver.dart' as driver;
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() {
  return integrationDriver(
    responseDataCallback: (Map<String, dynamic>? data) async {
      if (data == null) return;
      for (final entry in data.entries) {
        final value = entry.value;
        if (value is Map<String, dynamic> &&
            value.containsKey('traceEvents')) {
          final summary = driver.TimelineSummary.summarize(
            driver.Timeline.fromJson(value),
          );
          await summary.writeTimelineToFile(
            entry.key,
            pretty: true,
            includeSummary: true,
          );
        } else {
          await writeResponseData(
            <String, dynamic>{entry.key: value},
            testOutputFilename: entry.key,
          );
        }
      }
    },
  );
}
