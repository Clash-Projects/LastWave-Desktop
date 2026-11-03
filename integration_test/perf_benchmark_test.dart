// On-device performance benchmark for LastWave Desktop.
//
// Run in PROFILE mode (debug numbers are meaningless):
//
//   flutter drive --profile -d windows \
//     --driver=test_driver/perf_driver.dart \
//     --target=integration_test/perf_benchmark_test.dart \
//     --dart-define=PERF_VIDEO_ID=<videoId of a song with word-synced lyrics> \
//     --dart-define=PERF_TITLE="<its title>" \
//     --dart-define=PERF_ARTIST="<its artist>"
//
// Run 3 times per build being compared; results land in build/*.json.
//
// Preconditions: the profile under test is past /welcome (signed in or guest)
// and, ideally, has a few hundred Liked songs so the scroll scenario has a
// long list to move through. PERF_VIDEO_ID must come with PERF_TITLE and
// PERF_ARTIST (lyrics are matched on those); without PERF_VIDEO_ID the
// restored session track is resumed instead.
//
// Every scenario is wrapped in `watchPerformance`, which writes avg / p90 /
// p99 / worst build and raster times plus missed-frame counts under
// `<scenario>` in the response data. The karaoke scenario is additionally
// recorded with `traceAction`; the driver turns that timeline into a
// `TimelineSummary` (`karaoke_timeline.timeline_summary.json`).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';

import 'package:lastwave_desktop/core/audio/stream_models.dart';
import 'package:lastwave_desktop/features/player/playback_service.dart';
import 'package:lastwave_desktop/main.dart' as app;
import 'package:lastwave_desktop/ui/app_shell/app_shell.dart';

const _videoId = String.fromEnvironment('PERF_VIDEO_ID');
// Lyrics are looked up by title + artist, so both must name the real song.
const _title = String.fromEnvironment('PERF_TITLE');
const _artist = String.fromEnvironment('PERF_ARTIST');

/// Seconds for the karaoke and idle scenarios (override to shorten a dry run).
const _holdSeconds = int.fromEnvironment('PERF_HOLD_SECONDS', defaultValue: 30);
const _navCycles = int.fromEnvironment('PERF_NAV_CYCLES', defaultValue: 20);

/// Sort the Liked table by title before scrolling (exercises the sorted
/// display-order path; sort state is per session, so it is set here).
const _sortByTitle = bool.fromEnvironment('PERF_SORT_TITLE');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Real vsync-driven frames: the app keeps animating (karaoke ticker, ambient
  // stage), so the fake-async "pump until settled" model does not apply.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('LastWave perf benchmark', (tester) async {
    // main() installs its own FlutterError.onError (fatal crumbs). The test
    // binding requires the handler to be restored before the test ends.
    final testErrorHandler = FlutterError.onError;
    await app.main(const <String>[]);
    FlutterError.onError = testErrorHandler;

    await _waitFor(tester, find.byType(WaveShell),
        reason: 'App did not reach the main shell. Sign in or continue as '
            'guest once in this profile, then rerun.');
    final shellContext = tester.element(find.byType(WaveShell));
    final router = GoRouter.of(shellContext);
    final container = ProviderScope.containerOf(shellContext);
    final player = container.read(playbackServiceProvider.notifier);

    // ---- start playback -------------------------------------------------
    if (_videoId.isNotEmpty) {
      if (_title.isEmpty || _artist.isEmpty) {
        fail('PERF_VIDEO_ID needs PERF_TITLE and PERF_ARTIST too: lyrics are '
            'matched by title and artist.');
      }
      await player.play(const PlayableTrack(
        title: _title,
        artist: _artist,
        videoId: _videoId,
      ));
    } else if (container.read(playbackServiceProvider).current != null) {
      await player.playResume();
    } else {
      fail('Nothing to play: pass --dart-define=PERF_VIDEO_ID=<id> or '
          'start a track once so the session restores it.');
    }
    await _hold(tester, const Duration(seconds: 8)); // stream open + lyrics

    // ---- 1. karaoke on screen ------------------------------------------
    router.go('/now');
    await _hold(tester, const Duration(seconds: 3)); // transition + layout
    await binding.traceAction(
      () => binding.watchPerformance(
        () => _hold(tester, const Duration(seconds: _holdSeconds)),
        reportKey: 'karaoke_${_holdSeconds}s',
      ),
      reportKey: 'karaoke_timeline',
    );

    // ---- 2. long-list scrolling ----------------------------------------
    router.go('/liked');
    await _hold(tester, const Duration(seconds: 4)); // load + entrance
    if (_sortByTitle) {
      final header = find.text('TITLE').hitTestable();
      expect(header, findsWidgets, reason: 'Liked table header not found.');
      await tester.tap(header.first);
      await _hold(tester, const Duration(seconds: 1));
    }
    final list = _mainVerticalScrollable(tester);
    await binding.watchPerformance(() async {
      for (var i = 0; i < 3; i++) {
        await tester.fling(list, const Offset(0, -2400), 4000);
        await _hold(tester, const Duration(milliseconds: 1500));
      }
      for (var i = 0; i < 3; i++) {
        await tester.fling(list, const Offset(0, 2400), 4000);
        await _hold(tester, const Duration(milliseconds: 1500));
      }
    }, reportKey: _sortByTitle ? 'scroll_fling_sorted' : 'scroll_fling');
    await binding.watchPerformance(() async {
      await tester.timedDrag(
          list, const Offset(0, -1600), const Duration(seconds: 6));
      await _hold(tester, const Duration(milliseconds: 500));
      await tester.timedDrag(
          list, const Offset(0, 1600), const Duration(seconds: 6));
      await _hold(tester, const Duration(milliseconds: 500));
    }, reportKey: _sortByTitle ? 'scroll_slow_sorted' : 'scroll_slow');

    // ---- 3. back / forward navigation ----------------------------------
    router.go('/home');
    await _hold(tester, const Duration(seconds: 2));
    await binding.watchPerformance(() async {
      for (var i = 0; i < _navCycles; i++) {
        // Push a detail route and pop it (forward/back within a branch)…
        router.push('/history');
        await _hold(tester, const Duration(milliseconds: 700));
        router.pop();
        await _hold(tester, const Duration(milliseconds: 700));
        // …then switch branches and back (state-retaining tab switch).
        router.go('/liked');
        await _hold(tester, const Duration(milliseconds: 700));
        router.go('/home');
        await _hold(tester, const Duration(milliseconds: 700));
      }
    }, reportKey: 'navigation_${_navCycles}_cycles');

    // ---- 4. idle playback, lyrics not mounted --------------------------
    router.go('/settings');
    await _hold(tester, const Duration(seconds: 2));
    await binding.watchPerformance(
      () => _hold(tester, const Duration(seconds: _holdSeconds)),
      reportKey: 'idle_playback_lyrics_hidden_${_holdSeconds}s',
    );

    await player.pause();
    await _hold(tester, const Duration(milliseconds: 500));
  }, timeout: const Timeout(Duration(minutes: 10)));
}

/// Lets real time pass while frames keep being produced.
Future<void> _hold(WidgetTester tester, Duration d) async {
  final end = DateTime.now().add(d);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _waitFor(
  WidgetTester tester,
  Finder finder, {
  required String reason,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 200));
    if (finder.evaluate().isNotEmpty) return;
  }
  fail(reason);
}

/// The tallest on-screen vertical scrollable: the page list, not a shelf or
/// a menu. Offstage branches are excluded by the default finder.
Finder _mainVerticalScrollable(WidgetTester tester) {
  final candidates = find
      .byType(Scrollable)
      .hitTestable()
      .evaluate()
      .where((e) {
        final w = e.widget as Scrollable;
        return axisDirectionToAxis(w.axisDirection) == Axis.vertical;
      })
      .toList();
  expect(candidates, isNotEmpty, reason: 'No vertical list on screen.');
  double heightOf(Element e) {
    final box = e.renderObject;
    return box is RenderBox && box.hasSize ? box.size.height : 0;
  }

  candidates.sort((a, b) => heightOf(b).compareTo(heightOf(a)));
  final target = candidates.first;
  return find.byElementPredicate((e) => identical(e, target));
}
