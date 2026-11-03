# Performance & bug-fix report — LastWave Desktop

**Branch:** `claude/cool-wozniak-i1f3h0`. This is the branch the session was
allowed to push to; the brief asked for `perf-and-fixes`. The branch has 12
commits on top of `265ddbc`, one per fix, using `fix(...)`, `perf(...)` and
`test(...)` prefixes.

**Environment:** no Flutter SDK, no `dart` binary, and no device. Every change
was checked by reading the code, not by compiling it. **No number in this
report was measured on a device. Every impact figure is ESTIMATED**, and each
one shows how it was derived. §4 says what actually ran (nothing).

---

## 1. Executive summary

**Bugs fixed: 8.** 3 Medium and 5 Low. None was a crash on the default
path; the Medium ones are user-visible misbehaviour.

| Sev | # | Bugs |
|---|---|---|
| Medium | 3 | ←/→ seek restarting the track before its duration was known (B3); lyrics and motion art frozen after MPRIS *Raise* from the tray (B5); lyrics follow-scroll jumping instead of animating after unrelated rebuilds (B8) |
| Low | 5 | command palette controller leak (B1); `ref` used after dispose in global hotkeys (B2); RangeError on a shuffled start with an out-of-range index (B4); cookie import writing to a disposed dialog (B6); search-suggestion keyboard selection landing on hidden rows (B7) |

**Top performance wins (ESTIMATED):**

| Win | Scenario | Est. impact | Confidence |
|---|---|---|---|
| P1: table display order memoized | Scrolling or hovering a *sorted* Liked or playlist table (2 000 rows) | Build time per frame drops from about 10–110 ms to under 1 ms of sort work, roughly −90 % of UI-thread build cost in that scenario. Removes hover hitches. | Medium |
| P1 | Same table, *unsorted* | About 20 µs less allocation per row built | High (small) |
| P2: lyrics derived once per result | Karaoke on screen | About 0.3–0.5 ms saved per karaoke rebuild, which happens every few seconds | High (tiny) |
| P3: auto-hide timer throttle | Moving the mouse over lyrics | 125–1000 Timer allocations per second become ≤ 5 | High (tiny) |

**Overall CPU (ESTIMATED):**

- **Karaoke on screen:** about 0–2 % relative reduction, and only while the
  mouse moves over the lyrics. On `main` the karaoke engine is already
  leaf-scoped: a 60 Hz cap, binary search, cached `TextPainter`s, a
  `CustomPainter(repaint:)` per active syllable, and 10 Hz position
  throttling. I found no remaining per-tick rebuilds to remove without
  touching smoothness.
- **Idle playback, lyrics hidden:** about 0 %. Nothing in this path was
  changed. The remaining idle work is small and listed in §6.
- **Biggest real-world gain:** sorted long tables, where the old code could
  spend more than 100 ms per hover rebuild (P1).

Earlier sessions had already done most of the large wins: the 10 Hz position
gate, leaf-scoped position subscribers, karaoke painters, palette isolates,
DPR-aware artwork decode, and TickerMode while minimized. See
`docs/performance-*.md`. This pass found little left on the hot paths and
reports that honestly rather than inflating small changes.

---

## 2. Bugs fixed

| # | Severity | Bug | File:line | Root cause | Fix | User-visible symptom it prevents |
|---|---|---|---|---|---|---|
| B1 | Low | Leak | `lib/ui/app_shell/command_palette.dart:113` | `showWaveCommandPalette` created a `TextEditingController` for each Ctrl+K and never disposed it | The dialog state, its only user, disposes it. Children unmount first, so the `TextBox` has already detached. | Slow growth of leaked `ChangeNotifier`s over a long session |
| B2 | Low | `ref` after dispose | `lib/ui/app_shell/app_shell.dart:396-414` | OS hotkey handlers awaited `windowManager.isFocused()` and then used `ref` without re-checking `mounted` | Re-check `mounted` after the await | "Cannot use ref after the widget was disposed" when a media hotkey lands during shell teardown |
| B3 | Medium | Wrong result | `lib/ui/app_shell/app_shell.dart:375` | The global ←/→ seek clamped to `snap.duration`, which is 0 until mpv opens the source, so every step seeked to 0:00 | Return when the duration is ≤ 0. This is the same guard the dock timeline's own ←/→ handler already has (`player_dock.dart`, `_seekBy`). | Pressing an arrow key in a restored session or during a slow stream open restarted the song |
| B4 | Low | Range error | `lib/features/player/playback_service.dart:1534` | The `startShuffled` branch read `tracks[startIndex]` (raw) instead of the clamped `index` | Use `tracks[index]`. In-range starts are unchanged. | RangeError instead of playback when a caller passes an out-of-range start with shuffle |
| B5 | Medium | Lifecycle (desktop) | `lib/app/window_lifecycle.dart:149` | Linux MPRIS `Raise` calls `windowManager.show()` directly, bypassing `_setWindowVisible(true)`, so `windowVisibleProvider` stayed `false` after hide-to-tray | `onWindowFocus` repairs a stale "hidden" flag. A focused window is on screen. Blur is still ignored. | Karaoke frozen, motion art paused, and the network probe slowed after raising the window from the tray via MPRIS, until the next minimize/restore |
| B6 | Low | Use after dispose | `lib/ui/settings/settings_page.dart:1931` | After the `cookies.txt` picker returned, the code wrote `controller.text` and called `setState` without checking that the dialog was still mounted. Linux portal pickers are not modal. | `if (!context.mounted) return;` | Assertion or crash if the "Connect with cookies" dialog was closed while the file picker was open |
| B7 | Low | Range / wrong result | `lib/ui/search/search_page.dart:201` | The dropdown renders at most 6 suggestions, but ↑/↓ and Enter clamped to the full list | Clamp to the rendered count. Only the out-of-range path changes. | ↓ past the 6th row hid the highlight, and Enter then searched for a suggestion that was not on screen |
| B8 | Medium | Lyrics sync / lifecycle | `lib/features/lyrics/karaoke_lyrics_view.dart:479` (memo); the effect is in `_AppleLineLyricsView.didUpdateWidget` | `build()` re-ran `stripLyricCreditLines` on each rebuild. Whenever that allocated a new `LyricsResult` (plain-text lyrics always; synced lyrics when it strips a line), the child saw "new lyrics", reset `_lastIndex`/`_pinnedOpening`, and the next line change used `jumpTo` | Memoize on the provider result's identity plus title and artist (see P2). The value is the same; the object is now stable. | After the toolbar auto-hid, after a follow toggle, or after entering select mode, the next lyric line snapped into place instead of the normal animated scroll |

Why each fix only restores intended behaviour:

- **B1, B2, B6:** guards and disposal only.
- **B3:** mirrors a guard the codebase already applies to the same action.
- **B4:** identical for valid input.
- **B5:** only changes state when the flag is provably wrong (the window has
  focus).
- **B7:** the dropdown already capped itself at 6 rows.
- **B8:** the reset is documented for *new lyrics*, not for unrelated
  rebuilds.

---

## 3. Performance improvements

| # | Area | Problem | File:line | Fix | Est. before | Est. after | Est. gain | Confidence |
|---|---|---|---|---|---|---|---|---|
| P1 | Scrolling (Liked, playlist, YT playlist, album and search tables) | The `_order` getter allocated `List.generate(n)` and, with a column sort active, ran a full `sort` with a `toLowerCase()` comparator on **every access**. `itemBuilder` reads it once per row, so every newly built row, and every row on a hover `setState`, paid O(n log n). | `lib/ui/components/desktop_table.dart:205` (memo), `:216` and `:249` (invalidation) | Cache the order. Invalidate it in `didUpdateWidget` (any new config) and in `_cycleSort`. A length guard keeps the old behaviour if `items` is mutated in place. Same comparator and same input, so the order is identical; Dart's sort is deterministic. | **Sorted, n = 2 000:** about 22 k comparisons × 2 `toLowerCase` ≈ **4–6 ms per row built**. A fling builds 2–4 rows per frame, so **10–25 ms per frame**. A hover enter or exit rebuilds about 20 rows, so **80–120 ms per hover hitch**. **Unsorted:** 2 000-int allocation ≈ 2–4 µs per row. | One sort of 4–6 ms per widget update (track change, like toggle). After that, O(1) per row. | Sorted: −90 % or more of UI-thread build work while scrolling or hovering, and hover hitches gone. Unsorted: −20 to −80 µs per frame. | Medium. The comparator cost is extrapolated from typical Dart string ops; `perf/bench/hot_paths_bench.dart` measures the exact algorithm. |
| P2 | Lyrics/karaoke | Plain-text expansion and the regex credit strip (about 6 regexes per line) ran over every lyric line on every karaoke rebuild | `lib/features/lyrics/karaoke_lyrics_view.dart:479` | Memoize per provider emission. The function is pure. | 60–120 lines × ~6 regex tests ≈ 0.3–0.5 ms per rebuild. Rebuilds happen on auto-hide show/hide, follow and select changes: about 1 every 3–5 s. | ~0 | ≤ 0.02 % CPU. Also fixes B8. | High |
| P3 | Lyrics/karaoke (idle CPU while the mouse moves) | `MouseRegion.onHover` → `_pokeControls()` cancelled and allocated a `Timer` on every pointer event (125–1000 Hz) | `lib/features/lyrics/karaoke_lyrics_view.dart:292` (handler at `:655`) | While the toolbar is shown and armed with the same timeout, re-arm at most every 200 ms. The timeout measures from the last poke and waits out any remainder, so the fade still lands exactly N s after the last movement. This copies `now_playing_page.dart`'s idle timer. | 125–1000 Timer create/cancel per second, about 0.1–1 ms/s plus GC churn | ≤ 5/s | ≤ 0.1 % of a core while hovering | High |

The visible result is identical for P1–P3. P1 returns the same index order.
P2 returns the same value, deterministically. P3 shows the same toolbar and
fades at the same moment; only the number of intermediate Timer objects
changes.

---

## 4. Measured results

**Nothing was run.** The sandbox had neither `flutter` nor `dart` on PATH,
and the brief ruled out installing the SDK. Not run:

- `test/perf_and_fixes_test.dart`: unit tests for the karaoke line lookup
  (boundaries, seek, shared and untimed cues, and a 200-timeline random
  cross-check against a linear reference), syllable progress clamping, and
  `stripLyricCreditLines` identity and determinism, which P2 relies on.
  Run it with `flutter test test/perf_and_fixes_test.dart`.
- `perf/bench/hot_paths_bench.dart`: a pure-Dart micro-benchmark of P1's
  algorithm (before vs after per scroll frame, n = 200/2 000/10 000) and the
  per-call cost of the karaoke lookup. Run it with
  `dart run perf/bench/hot_paths_bench.dart`.
- `integration_test/perf_benchmark_test.dart` with
  `test_driver/perf_driver.dart`: the on-device benchmark. See §8.

Results from the micro-benchmark belong here once you run it. Keep them apart
from the estimates in §3.

---

## 5. Skipped (unsafe to apply blind)

| Item | Where | Expected gain | Risk | What to verify on device |
|---|---|---|---|---|
| Decode local-file artwork at display size | `lib/ui/components/artwork.dart:546` (`Image.file` without `cacheWidth`/`cacheHeight`) | Large for local libraries with embedded 1–3k px covers: about 4–36 MB decoded per cover down to about 50–400 KB per tile | Setting both dimensions on a non-square image distorts it before `BoxFit.cover`. Setting one dimension can under-sample the short side and blur it. The safe value needs the source aspect ratio. | Compare tiles of portrait and landscape local covers pixel by pixel. Watch image-cache bytes in DevTools. |
| Narrow table hover to a per-row notifier | `lib/ui/components/desktop_table.dart:592` | After P1, a hover rebuilds about 20 rows (~1–2 ms) instead of 1 | It changes how `_TableRow` receives `hovered`, and the interaction with `WaveEntrance` and focus is not verifiable blind | Hover highlight timing, keyboard focus ring, and the entrance animation on first build |
| Stable queue row keys (drop the index from the key) | `lib/ui/queue/queue_panel.dart:165`, `:189` | Avoids rebuilding every queue row from scratch on each track change | The same track can be queued twice, which would create duplicate keys and an assertion | The duplicate-track queue case, and the reorder animation |
| Pause `_BrowseTile` rotation timers while the Search branch is offstage or minimized | `lib/ui/search/search_page.dart:743` | About 15 offscreen `setState` calls and image swaps per 10 s, which can trigger network fetches | When you return, the tile shows a different image than on `main`, a visible behaviour change | Whether rotation continuing offscreen is intended |
| Karaoke ticker frame rate | `lib/features/lyrics/karaoke_lyrics_view.dart:398` | The ticker schedules frames at display rate (144 Hz) while work is capped at 60 Hz, so up to about 84 frames/s composite with no change | Reducing frame scheduling would lower highlight smoothness, which the brief forbids | — |

---

## 6. Found but not fixed

| Issue | Where | Why left | Recommendation |
|---|---|---|---|
| `clearUpcoming` doesn't rebuild the shuffle order | `lib/features/player/playback_service.dart:1600` | Indices past the cleared queue are filtered by `_queueIndexValid`, so nothing crashes. But in shuffle mode, "next" can still pick a remaining entry *before* the current one, while the panel shows "Queue ends here". The intended behaviour in shuffle after "Clear" is unclear. | Decide the intended semantics. Then either `_rebuildShuffleOrder(queue.length, currentIndex)` or truncate `_shuffleOrder` to indices ≤ `currentIndex`. |
| `removeAt` on the current item doesn't rebuild the shuffle order | `lib/features/player/playback_service.dart:1577` | Every other mutation rebuilds the order; this path leaves it pointing at pre-removal indices (off by one after the removed slot). Rebuilding reshuffles, a visible change to upcoming order. | Rebuild or re-map the order (decrement indices > removed), as the other mutations do |
| Podcast progress coordinator runs a SQLite `SELECT` on every 10 Hz position tick, even for songs | `lib/features/podcasts/podcast_repository.dart:150` | About 10–20 µs per tick, about 0.02 % CPU. Caching risks missing a row created mid-track. | Cache "not a podcast" per videoId and invalidate it from `upsertPodcastProgress` |
| `File.existsSync()` in `build` for local artwork | `lib/ui/components/artwork.dart:545` | A synchronous stat per tile build, about 10–50 µs. Caching changes behaviour when files appear or disappear. | Resolve existence once in state (and on URL change) |
| Dialog controllers disposed right after `await showDialog` | e.g. `lib/ui/settings/settings_page.dart:2018`, `lib/ui/collections/playlist_dialogs.dart` | The controller is disposed while the route's exit transition still shows the `TextBox`. This is safe as long as nothing rebuilds it during the 110–180 ms fade. | Move ownership into a `StatefulWidget`, as was done for the palette (B1) |
| Karaoke `_isEffectivelyActive` does two inherited lookups, twice per tick | `lib/features/lyrics/karaoke_lyrics_view.dart:200` | About 4 hash lookups at 60 Hz, which is negligible | None needed |

---

## 7. Device verification checklist

**Lyrics sync**
- Play a word-synced song. **Seek** forward and back by dragging the dock bar,
  pressing ←/→, and tapping a lyric line. The active line and wipe must land
  on the right line immediately.
- **Skip** to the next and previous tracks. Lyrics reset to the new song with
  no stale line highlighted.
- Let the toolbar **auto-hide** (Settings → lyrics auto-hide), then wait for
  the next line. It should **animate** into place, not jump (B8).
- Move the mouse continuously over lyrics for 10 s, then stop. The toolbar
  fades exactly N s after you stop (P3).
- Plain-text (unsynced) lyrics still show, and select or share still works.

**Scroll restoration and tables**
- On Liked (a large library), sort by **TITLE**, fling, and hover rows quickly.
  There should be no hitches (P1). Change the sort direction, unsort, like or
  unlike a song, and confirm the order updates each time.
- Leave a tab and come back. Scroll offsets are retained (branch switcher).

**Back/forward navigation:** mouse back/forward buttons and Alt+←/→ through 20
pages; the palette (Ctrl+K) opens and closes repeatedly (B1).

**Minimize/restore:** while karaoke plays, minimize and restore. The ticker
resumes. On Linux, hide to tray, then **raise via MPRIS** (for example
`playerctl -p lastwave` or your desktop's media widget). Lyrics must be moving
(B5).

**Media keys:** Ctrl+Alt+P/N/B while unfocused, and system media keys
(SMTC/MPRIS).

**Keyboard seek:** restart the app with a restored session, and press → before
pressing play. It must **not** jump to 0:00 (B3).

**Search:** type a query with more than 6 suggestions and press ↓ past the last
row. The highlight stops at row 6, and Enter searches that row (B7).

**Window resize:** resize across 640/800/1000/1100 px widths. Table columns
collapse as before, and sorted order is preserved.

**Settings:** Connect with cookies → Import cookies.txt, then close the dialog
while the picker is open (Linux). No error (B6).

---

## 8. How to get real numbers

Run the on-device benchmark in profile mode:

```bash
flutter drive --profile -d windows \
  --driver=test_driver/perf_driver.dart \
  --target=integration_test/perf_benchmark_test.dart \
  --dart-define=PERF_VIDEO_ID=<videoId> \
  --dart-define=PERF_TITLE="<title>" \
  --dart-define=PERF_ARTIST="<artist>"
```

It covers karaoke on screen for 30 s, fling and slow scroll through Liked
(add `--dart-define=PERF_SORT_TITLE=true` for the sorted path), 20
navigation cycles, and 30 s of idle playback with lyrics hidden. It writes
avg/p90/p99 build and raster times and missed frames to `build/*.json`, plus
a `TimelineSummary` of the karaoke trace. Compare the median of 3 runs
against `e2cb2ee`, and read CPU % from the OS task manager.

**Notes on the harness:**

- `pubspec.yaml` gains `integration_test: sdk: flutter` as a dev dependency,
  the one exception the brief allowed. `pubspec.lock` was not regenerated
  (there was no SDK); `flutter drive` or `flutter pub get` updates it.
- `test_driver/perf_driver.dart` imports `flutter_driver` for
  `TimelineSummary`. It is an SDK package and already a transitive
  dependency of `integration_test`, so nothing else is added to the pubspec.
