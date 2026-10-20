# Round 2: 144Hz Desktop Compositor, Wheel Interpolation & Zero-Jank Navigation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate 144Hz lyrics CPU churn, implement true mouse-wheel smooth scroll interpolation on desktop, preserve navigation state via `StatefulShellRoute.indexedStack`, and remove live chrome `BackdropFilter` raster bottlenecks.

**Architecture:** 
1. Route all synced lyrics through the optimized `_AppleLineLyricsView` instead of `flutter_lyric`'s `LyricView`, consolidating position listeners to a single active line/syllable coordinator to eliminate the 15–30 listener fan-out.
2. Intercept desktop `PointerScrollEvent` with a smooth wheel interpolator so mouse wheel notches smoothly glide via temporal damping curves instead of discrete 1-frame pixel teleports.
3. Migrate `router.dart` to `StatefulShellRoute.indexedStack` to preserve page widget trees and scroll offsets across tab switches, and cap `WaveEntranceGroup` animations so back/forth navigation does not run 1000ms `Opacity` (`saveLayer`) cascades.
4. Replace live chrome `BackdropFilter` readbacks in `TitleBar`, `SideRail`, and `PlayerDock` with static tonal acrylic materials.

**Tech Stack:** Flutter Desktop (Windows), Dart, Riverpod, GoRouter (`StatefulShellRoute`), Fluent UI.

---

## Global Constraints
- Do not introduce breaking API changes.
- Maintain existing visual aesthetics and theme tokens.
- All unit tests must pass via `flutter test`.
- Adhere to user global rule: smallest correct patch, preserve existing structure and naming.

---

### Task 1: Direct All Synced Lyrics to `_AppleLineLyricsView` & Eliminate Syllable Listener Fan-Out

**Files:**
- Modify: `lib/features/lyrics/karaoke_lyrics_view.dart:200-220, 400-435, 740-800`
- Modify: `lib/ui/now_playing/now_playing_page.dart:580-605`
- Test: `test/lyrics_match_parse_test.dart`

**Interfaces:**
- Consumes: `_interpolatedPositionMs`, `_activeLineIndex`, `LyricsResult`
- Produces: 144Hz smooth karaoke syllable wipe at <2% CPU without `flutter_lyric` canvas bypass or per-syllable listener fan-out.

- [ ] **Step 1: Write test verifying synced lyrics render `_AppleLineLyricsView` without `flutter_lyric` dependency**
- [ ] **Step 2: Update `karaoke_lyrics_view.dart` to use `_AppleLineLyricsView` whenever `result.isSynced` is true**
- [ ] **Step 3: Stop calling `_lyricController.setProgress` inside `_onTick` when `_AppleLineLyricsView` is active**
- [ ] **Step 4: Refactor `_KaraokeSyllableWidget` to only listen to position when the syllable is active or approaching, and remove the outer clipping `ClipRRect` in `now_playing_page.dart:582`**
- [ ] **Step 5: Run tests and verify PASS**
- [ ] **Step 6: Commit changes**

---

### Task 2: Implement True Desktop Mouse-Wheel Smooth Scrolling & Fix Shelf Scroll Trap

**Files:**
- Create/Modify: `lib/design_system/fluent/lw_scrollbar.dart`
- Modify: `lib/ui/components/shelf.dart:167-185`
- Test: `test/scroll_physics_test.dart`

**Interfaces:**
- Consumes: `PointerScrollEvent`, `ScrollController`, `ScrollPosition`
- Produces: Smooth, time-interpolated wheel scrolling on Windows desktop without discrete jumping, and non-trapping horizontal shelves.

- [ ] **Step 1: Write test for wheel scroll delta interpolation and horizontal shelf forwarding**
- [ ] **Step 2: Implement desktop wheel smoothing in `WaveScrollBehavior` or a reusable smooth scroll wrapper that interpolates `PointerScrollEvent` with `Curves.easeOutCubic` over 180ms**
- [ ] **Step 3: In `shelf.dart:169`, configure horizontal `ListView` so that vertical mouse wheel deltas are not absorbed by the horizontal axis**
- [ ] **Step 4: Run tests and verify PASS**
- [ ] **Step 5: Commit changes**

---

### Task 3: Migrate Router to `StatefulShellRoute.indexedStack` & Tame `WaveEntranceGroup`

**Files:**
- Modify: `lib/app/router.dart:70-130`
- Modify: `lib/ui/theme/motion.dart:40-85, 140-188`

**Interfaces:**
- Consumes: `GoRouter`, `StatefulShellRoute`, `StatefulNavigationShell`
- Produces: Instant, 0ms tab navigation preserving scroll positions and widget trees without cold remounting or 1000ms `Opacity` cascades.

- [ ] **Step 1: Update `router.dart` to wrap primary navigation branches (`/home`, `/discover`, `/search`, `/liked`, `/albums`, `/downloads`) in `StatefulShellRoute.indexedStack`**
- [ ] **Step 2: Update `WaveShell` to take `StatefulNavigationShell` (or preserve child branches in `IndexedStack`)**
- [ ] **Step 3: Update `WaveEntranceGroup` in `motion.dart` to shorten entrance window to 250ms and skip replay if already played**
- [ ] **Step 4: Verify navigation compiles and tests pass**
- [ ] **Step 5: Commit changes**

---

### Task 4: Eliminate Live Chrome `BackdropFilter` Raster Bottlenecks

**Files:**
- Modify: `lib/design_system/fluent/lw_materials.dart:130-165`
- Modify: `lib/ui/theme/haze.dart:150-190`

**Interfaces:**
- Consumes: `LwHazeLevel`, `WaveHaze`
- Produces: Tonal acrylic rendering for TitleBar, SideRail, and PlayerDock that eliminates full-screen GPU framebuffer readbacks during scroll frames.

- [ ] **Step 1: In `lw_materials.dart`, make L1 chrome (`TitleBar`, `SideRail`, `PlayerDock`) use rich static tonal acrylic fills without live `BackdropFilter` readbacks**
- [ ] **Step 2: In `haze.dart`, ensure `WaveGlass` bounds blurs without unbounded parent readbacks**
- [ ] **Step 3: Verify app builds and visual styling is preserved**
- [ ] **Step 4: Commit changes**

---

### Task 5: Clean Up Search Lambda & Collection Mount Work

**Files:**
- Modify: `lib/ui/search/search_page.dart:1365-1376`
- Modify: `lib/ui/collections/liked_page.dart:45-90`

**Interfaces:**
- Consumes: `playbackServiceProvider`
- Produces: Elimination of dynamic `ref.watch` inside table row closures and lighter Frame 0 build execution.

- [ ] **Step 1: In `search_page.dart:1372`, watch `isPlaying` at the `_SongsTable` build level and pass a boolean into the closure rather than watching inside the lambda**
- [ ] **Step 2: In `liked_page.dart`, optimize track list transformations on build**
- [ ] **Step 3: Run full test suite and verify clean pass**
- [ ] **Step 4: Commit changes**
