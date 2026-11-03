# How to measure (A/B: `main` vs the fixes branch)

Nothing on this branch was measured on a device: the sandbox it was written in
had no Flutter SDK. These steps produce the real numbers.

> **Branch name.** The fixes were pushed to `claude/cool-wozniak-i1f3h0` (the
> branch this session was allowed to push to). Wherever this file says
> `perf-and-fixes`, use that branch, or create the name locally first:
> `git branch perf-and-fixes origin/claude/cool-wozniak-i1f3h0`.

## 0. One-time setup

1. Use the same machine, the same display (refresh rate matters), and the same
   window size for every run. Plug in laptops and pick a fixed power plan.
2. Launch the app once normally and get past the welcome screen (sign in or
   continue as guest). The benchmark reuses that profile.
3. Ideally have **a few hundred Liked songs**. The scroll scenario uses the
   Liked page, and a short list measures nothing.
4. Pick one song with **word-synced lyrics** and note its YouTube Music
   `videoId`, exact title and artist. Use the same song for every run.

`main` does not contain the benchmark files. Copy them in once and leave them
uncommitted:

```bash
git checkout main
git checkout perf-and-fixes -- integration_test/perf_benchmark_test.dart test_driver/perf_driver.dart
```

On `main`, also add the dev dependency to `pubspec.yaml`. Revert it afterwards:

```yaml
dev_dependencies:
  integration_test:
    sdk: flutter
```

## 1. Run the benchmark (3 runs per branch)

```bash
flutter drive --profile -d windows \
  --driver=test_driver/perf_driver.dart \
  --target=integration_test/perf_benchmark_test.dart \
  --dart-define=PERF_VIDEO_ID=<videoId> \
  --dart-define=PERF_TITLE="<title>" \
  --dart-define=PERF_ARTIST="<artist>"
```

Use `-d macos` or `-d linux` on those platforms. Always use `--profile`:
debug-mode numbers are meaningless, and release mode exposes no timeline.

Optional defines: `PERF_HOLD_SECONDS` (default 30, the length of the karaoke
and idle scenarios), `PERF_NAV_CYCLES` (default 20), and
`PERF_SORT_TITLE=true`, which clicks the Liked table's **TITLE** header before
scrolling and writes `scroll_*_sorted.json` instead.

After each run, copy `build/*.json` to a folder such as
`perf/results/<branch>/run<N>/` before the next run overwrites it.

### What each run writes (`build/`)

| File | Scenario | Contents |
|---|---|---|
| `karaoke_30s.json` | Now Playing with karaoke lyrics on screen for 30 s | `watchPerformance` summary |
| `karaoke_timeline.timeline_summary.json` | same 30 s, traced | `TimelineSummary`: build/raster avg, p90, p99, worst, missed frames, GC counts |
| `karaoke_timeline.timeline.json` | same | raw trace; open it in https://ui.perfetto.dev |
| `scroll_fling.json` | 3 flings down and 3 up through Liked songs | `watchPerformance` summary |
| `scroll_slow.json` | two slow 6 s drags | `watchPerformance` summary |
| `navigation_20_cycles.json` | 20 × (push /history → pop → Liked tab → Home tab) | `watchPerformance` summary |
| `idle_playback_lyrics_hidden_30s.json` | playing on the Settings page, lyrics not mounted | `watchPerformance` summary |

The `watchPerformance` keys to compare are:
`average_frame_build_time_millis`, `90th_percentile_frame_build_time_millis`,
`99th_percentile_frame_build_time_millis`, `worst_frame_build_time_millis`,
`missed_frame_build_budget_count`, and the matching `*_rasterizer_*` keys.

## 2. CPU % (OS task manager)

The frame metrics don't show idle CPU. Measure it by hand, with the app
launched normally in profile mode (`flutter run --profile -d <platform>`) or as
a release build:

1. Play the benchmark song and open **Now Playing** with lyrics visible.
2. Wait 10 s, then read the app's CPU % every 5 s for 60 s:
   - Windows: Task Manager → Details tab → `lastwave_desktop.exe`, CPU column.
     Or use Resource Monitor, which shows a 60 s average.
   - macOS: Activity Monitor → % CPU.
   - Linux: `top -d 5 -p $(pgrep -f lastwave_desktop)`
3. Record the mean. Repeat with:
   - **Idle, lyrics hidden:** playing, on the Home or Settings page.
   - **Minimized:** playing, window minimized. Tickers should stop here.
   - **Paused, visible:** nothing playing, Now Playing open.
4. Do this 3 times per branch.

On a multi-core machine, Task Manager shows % of the whole machine. Compare
like with like and don't convert.

## 3. Compare

For each metric, take the **median of the 3 runs** per branch and report:

```
delta % = (fixes - main) / main × 100
```

A change is real only if the two branches' run-to-run ranges don't overlap.
Display refresh rate and other running apps matter more than most code
changes, so keep them fixed.

### Where to look first

- **Scrolling a sorted table** (Liked, playlist or album table with a column
  sort on): `scroll_*` build-time p90/p99. This is the clearest expected win
  (see PERFORMANCE_REPORT.md, item P1). The default run scrolls unsorted;
  do the 3 runs per branch a second time with `--dart-define=PERF_SORT_TITLE=true`
  for the sorted path, where the difference is largest.
- **Karaoke** (`karaoke_*`): small expected change. The karaoke engine was
  already leaf-scoped on `main`. Hovering the mouse over the lyrics during the
  run exercises P3.

## 4. Pure-Dart micro-benchmarks

These need no device:

```bash
dart run perf/bench/hot_paths_bench.dart
```

They isolate the algorithmic change behind P1 (table order memo) and show the
per-call cost of the karaoke line lookup.
