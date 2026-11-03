// Pure-Dart micro-benchmarks for the hot paths touched on perf-and-fixes.
// No Flutter imports, so it runs with a plain Dart SDK:
//
//   dart run perf/bench/hot_paths_bench.dart
//
// The algorithms are copied verbatim from the app (see the comments on each
// case), so the numbers isolate the algorithmic change from everything else.
// Results are machine-specific: compare before/after on the same machine.

import 'dart:math' as math;

// ---------------------------------------------------------------------------
// 1. WaveDesktopTable._order (lib/ui/components/desktop_table.dart)
//
// Before: a getter that allocated + sorted the full index list on EVERY
// access, and itemBuilder read it once per row built.
// After: computed once, reused until the widget/sort changes.
// Model: one scroll frame that builds `rowsPerFrame` rows.
// ---------------------------------------------------------------------------

class _Row {
  final String title;
  _Row(this.title);
}

List<int> _computeOrder(List<_Row> items) {
  final order = List<int>.generate(items.length, (i) => i);
  order.sort((a, b) =>
      items[a].title.toLowerCase().compareTo(items[b].title.toLowerCase()));
  return order;
}

int _frameBefore(List<_Row> items, int rowsPerFrame, int firstRow) {
  var sink = 0;
  for (var r = 0; r < rowsPerFrame; r++) {
    sink += _computeOrder(items)[firstRow + r]; // `_order[i]` per row
  }
  return sink;
}

int _frameAfter(List<int> cached, int rowsPerFrame, int firstRow) {
  var sink = 0;
  for (var r = 0; r < rowsPerFrame; r++) {
    sink += cached[firstRow + r];
  }
  return sink;
}

// ---------------------------------------------------------------------------
// 2. activeLyricLineIndex (lib/features/lyrics/lyrics_models.dart)
// Already a binary search on main; measured against a linear scan to show
// what the 60Hz tick costs per call.
// ---------------------------------------------------------------------------

int _binary(List<int> times, int pos) {
  if (times.isEmpty || pos < times.first) return -1;
  var low = 0, high = times.length - 1, result = 0;
  while (low <= high) {
    final mid = (low + high) >> 1;
    if (times[mid] <= pos) {
      result = mid;
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }
  return result;
}

int _linear(List<int> times, int pos) {
  if (times.isEmpty || pos < times.first) return -1;
  var result = 0;
  for (var i = 0; i < times.length; i++) {
    if (times[i] <= pos) result = i;
  }
  return result;
}

double _usPer(int iterations, void Function() body) {
  // Warm up the JIT, then time.
  for (var i = 0; i < iterations ~/ 10 + 1; i++) {
    body();
  }
  final sw = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    body();
  }
  sw.stop();
  return sw.elapsedMicroseconds / iterations;
}

void main() {
  final rnd = math.Random(7);
  String word() => String.fromCharCodes(
      List.generate(6 + rnd.nextInt(10), (_) => 97 + rnd.nextInt(26)));

  print('== WaveDesktopTable order, 20 rows built per frame, title sort ==');
  for (final n in [200, 2000, 10000]) {
    final items = List.generate(n, (_) => _Row('${word()} ${word()}'));
    final cached = _computeOrder(items);
    var sink = 0;
    final iters = n >= 10000 ? 20 : 200;
    final before =
        _usPer(iters, () => sink += _frameBefore(items, 20, n ~/ 2 - 10));
    final after =
        _usPer(iters * 1000, () => sink += _frameAfter(cached, 20, n ~/ 2 - 10));
    print('n=$n  before=${before.toStringAsFixed(1)} us/frame  '
        'after=${after.toStringAsFixed(3)} us/frame  '
        '(${(before / after).toStringAsFixed(0)}x)');
    if (sink == -1) print(sink); // keeps the work observable
  }

  print('\n== activeLyricLineIndex, per call ==');
  for (final n in [60, 120, 400]) {
    var t = 0;
    final times = [for (var i = 0; i < n; i++) t += 1000 + rnd.nextInt(4000)];
    var sink = 0;
    final probes = [for (var i = 0; i < 1000; i++) rnd.nextInt(t)];
    var p = 0;
    final bin = _usPer(200000, () => sink += _binary(times, probes[p++ % 1000]));
    final lin = _usPer(200000, () => sink += _linear(times, probes[p++ % 1000]));
    print('lines=$n  binary=${(bin * 1000).toStringAsFixed(0)} ns  '
        'linear=${(lin * 1000).toStringAsFixed(0)} ns');
    if (sink == -1) print(sink); // keeps the work observable
  }
}
