# Smooth Scrolling, High-Refresh Rate & Lyrics Performance Optimization Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate 30fps stutter, reduce lyrics CPU usage from 15% to negligible (<2%), implement smooth native desktop scrolling, and make navigation/exploration instant.

**Architecture:** 
1. Uncap the lyrics frame ticker from artificial 33ms (30Hz) throttling to display vsync (120Hz/144Hz+) and eliminate per-line `ImageFiltered` GPU Gaussian blur passes.
2. Provide smooth desktop mouse wheel & trackpad scroll physics in `WaveScrollBehavior`.
3. Expand memory image cache from 50 MiB to 384 MiB to eliminate disk re-decode hitches on scroll.
4. Replace persistent chrome live `BackdropFilter` blurs with high-contrast semi-opaque solid tones.
5. Cache artwork palette extraction across card lifecycles to stop CPU isolate storms.
6. Streamline route transitions to fast 110ms crossfades.

**Tech Stack:** Flutter Desktop (Windows/Linux/macOS), Riverpod, Fluent UI, Skia/Direct3D raster pipeline.

---

## Global Constraints

- Dart 3.13.3+ / Flutter 3.47+ SDK compatibility.
- Zero functional or visual regression: lyrics synchronization, typography, and playback controls must remain pixel-perfect.
- No new external package dependencies unless necessary.
- Preserve all existing tests and ensure clean test passes.

## Review Focus

- Syllable karaoke wipe accuracy must remain exactly synchronized with audio playback clock.
- Scrolling horizontal shelves must not block vertical page scrolling.
- Image memory must stay bounded under 500 MiB RSS while preventing scroll re-decode thrashing.
- Title bar, player dock, and navigation rail must maintain polished visual hierarchy without live blur overhead.
- All Flutter tests in `test/` must pass.

---

### Task 1: Uncap Lyrics Ticker to High Refresh (120Hz/144Hz) & Eliminate Inactive Line Gaussian Blurs

**Files:**
- Modify: `lib/features/lyrics/karaoke_lyrics_view.dart:200-230`
- Modify: `lib/features/lyrics/karaoke_lyrics_view.dart:695-715`
- Modify: `lib/features/lyrics/karaoke_lyrics_view.dart:1255-1275`
- Test: `test/lyrics_match_parse_test.dart`

**Interfaces:**
- Consumes: `Ticker`, `LyricController`, `LyricLine`, `ValueNotifier<int>`
- Produces: 120Hz/144Hz-capable smooth lyric rendering and scroll without `ImageFiltered` blur penalty.

- [x] **Step 1: Write verification test for lyric progress calculation**
Ensure syllable progress calculation correctly interpolates at high refresh rates without precision loss.

- [x] **Step 2: Remove the 33,000µs (30Hz) clamp in `_onTick`**
In `lib/features/lyrics/karaoke_lyrics_view.dart`, remove the artificial `if (wall.difference(_lastTickWall).inMicroseconds < 33000) return;` check so the animation ticker runs at display refresh rate.

- [x] **Step 3: Remove per-line `ImageFiltered` Gaussian blur in `WaveKaraokeLyricLine`**
In `lib/features/lyrics/karaoke_lyrics_view.dart`, replace `ImageFiltered(imageFilter: ImageFilter.blur(...))` on inactive lines with crisp typographic opacity falloff (`idleTextColor`).

- [x] **Step 4: Stabilize `ScrollablePositionedList` in `_AppleLineLyricsView`**
Prevent destroying and reconstructing the `ScrollablePositionedList.builder` widget on every active line index change. Only update line states and invoke `_scrollTo` on the existing controller.

- [x] **Step 5: Run tests to verify**
Run: `& "C:\src\flutter\bin\flutter.bat" test test/lyrics_match_parse_test.dart`
Expected: All tests pass.

- [x] **Step 6: Commit**
```bash
git add lib/features/lyrics/karaoke_lyrics_view.dart
git commit -m "perf(lyrics): uncap ticker to display refresh and remove per-line blur"
```

---

### Task 2: Implement Desktop Smooth Inertial Scroll Physics & Drag Devices

**Files:**
- Modify: `lib/design_system/fluent/lw_scrollbar.dart:40-74`
- Test: `test/scroll_physics_test.dart`

**Interfaces:**
- Consumes: `FluentScrollBehavior`, `ScrollPhysics`
- Produces: `WaveScrollBehavior` with smooth mouse wheel dampening and mouse/trackpad drag support.

- [x] **Step 1: Add unit test for `WaveScrollBehavior`**
Create `test/scroll_physics_test.dart` testing `dragDevices` and `getScrollPhysics`.

- [x] **Step 2: Update `WaveScrollBehavior`**
In `lib/design_system/fluent/lw_scrollbar.dart`:
1. Override `dragDevices` to include `PointerDeviceKind.mouse` and `PointerDeviceKind.trackpad`.
2. Override `getScrollPhysics(BuildContext context)` to provide natural dampening physics (`BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics())` or custom smooth physics).

- [x] **Step 3: Run tests to verify**
Run: `& "C:\src\flutter\bin\flutter.bat" test test/scroll_physics_test.dart`
Expected: PASS.

- [x] **Step 4: Commit**
```bash
git add lib/design_system/fluent/lw_scrollbar.dart test/scroll_physics_test.dart
git commit -m "perf(scroll): enable mouse/trackpad dragging and smooth scroll physics"
```

---

### Task 3: Expand Memory Image Cache to 384 MiB

**Files:**
- Modify: `lib/main.dart:28-35`

**Interfaces:**
- Consumes: `PaintingBinding.instance.imageCache`
- Produces: Sufficient memory cache budget to prevent image purge/re-decode during scrolling.

- [x] **Step 1: Increase image cache bounds**
In `lib/main.dart`:
Change `maximumSize` from 200 to 1,000 images, and `maximumSizeBytes` from `50 << 20` (50 MiB) to `384 << 20` (384 MiB).

- [x] **Step 2: Verify app compiles cleanly**
Run: `& "C:\src\flutter\bin\flutter.bat" analyze lib/main.dart`
Expected: No errors.

- [x] **Step 3: Commit**
```bash
git add lib/main.dart
git commit -m "perf(images): increase memory image cache ceiling to 384 MiB"
```

---

### Task 4: Eliminate Window Chrome Live `BackdropFilter` Invalidation on Scroll

**Files:**
- Modify: `lib/ui/app_shell/title_bar.dart:45-60`
- Modify: `lib/ui/player_dock/player_dock.dart:82-95`
- Modify: `lib/ui/navigation/side_rail.dart:65-80`

**Interfaces:**
- Consumes: `LwHazeLevel`, `WaveColors`
- Produces: Polished semi-opaque solid chrome surfaces that do not re-blur underlying scrollable content.

- [x] **Step 1: Update Title Bar, Side Rail, and Player Dock Haze**
Pass `enableBlur: false` (or solid surface styling) to `WaveHaze` in `title_bar.dart`, `side_rail.dart`, and `player_dock.dart` so they do not allocate offscreen blur layers when page content scrolls underneath.

- [x] **Step 2: Verify syntax and analysis**
Run: `& "C:\src\flutter\bin\flutter.bat" analyze lib/ui/app_shell/title_bar.dart lib/ui/player_dock/player_dock.dart lib/ui/navigation/side_rail.dart`
Expected: No errors.

- [x] **Step 3: Commit**
```bash
git add lib/ui/app_shell/title_bar.dart lib/ui/player_dock/player_dock.dart lib/ui/navigation/side_rail.dart
git commit -m "perf(chrome): eliminate continuous backdrop blur invalidation on persistent bars"
```

---

### Task 5: Cache Artwork Palette Extraction Across Card Lifecycles

**Files:**
- Modify: `lib/ui/components/ambient.dart:370-405`
- Modify: `lib/ui/components/shelf.dart:220-230`

**Interfaces:**
- Consumes: `artworkPaletteProvider`, `artworkSeedProvider`
- Produces: LRU/persistent caching of computed palettes preventing `compute()` isolate storms on scroll.

- [x] **Step 1: Add `ref.keepAlive()` and memory cache to `artworkPaletteProvider`**
In `lib/ui/components/ambient.dart`, ensure resolved palettes are retained in an LRU memory cache instead of immediately disposing and spawning isolates when cards scroll out of view.

- [x] **Step 2: Run tests to verify**
Run: `& "C:\src\flutter\bin\flutter.bat" test`
Expected: PASS.

- [x] **Step 3: Commit**
```bash
git add lib/ui/components/ambient.dart
git commit -m "perf(palette): cache artwork palette extraction to prevent isolate storms"
```

---

### Task 6: Accelerate Navigation Transitions to Instant/110ms Crossfade

**Files:**
- Modify: `lib/app/router.dart:27-50`

**Interfaces:**
- Consumes: `CustomTransitionPage`, `WaveMotion`
- Produces: Snappy, lightweight page transitions without heavy slide/matrix composition overhead.

- [x] **Step 1: Streamline `_page` transition builder**
In `lib/app/router.dart`, update `_page` to use `FadeTransition` over `WaveMotion.fast` (110ms) without `SlideTransition`, eliminating dual-page matrix composition lag.

- [x] **Step 2: Run all tests to verify whole project**
Run: `& "C:\src\flutter\bin\flutter.bat" test`
Expected: PASS.

- [x] **Step 3: Commit**
```bash
git add lib/app/router.dart
git commit -m "perf(router): streamline page transitions to fast 110ms crossfade"
```
