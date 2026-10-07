# Full Lyrics Providers Port (lrc.red + 5 native) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port every active native lyrics provider to desktop (lrc.red in the first-party slot, plus BetterLyrics, Kugou, Musixmatch, SimpMusic), with Auto-first word-sync racing, a Settings primary-provider picker (Auto default), and a Now Playing per-track source switcher that retries excluding the current provider.

**Architecture:** New `lib/features/lyrics/lyrics_providers.dart` holds theprovider enum, one fetch function per upstream, and the ported matching/parsing helpers; `lyrics_repository.dart` keeps its public shape and becomes the race orchestrator (preferred 4s head-start → 6-way word race → Musixmatch → LRCLIB, word-sync always beats line-sync); prefs + Settings + karaoke toolbar expose the picker/switcher. Existing LRCLIB/Apple paths are not touched.

**Tech Stack:** Flutter/Dart, Riverpod, Dio (`dio: ^5.11.1`), `crypto: ^3.0.7` (Musixmatch HMAC), `dart:io` ZLibCodec (KRC decrypt), `dart:convert` Base64.

**Spec:** User directive 2026-10-06 (port all, verify each API live first, word-by-word priority over line-by-line, Auto default, Now Playing switcher excludes current, no PR/push) + native source `LastWave-Native @ 55b6bb8`, `app/src/main/java/com/lastwave/app/data/lyrics/*.kt`.

## Global Constraints

- Local branch `feat/lyrics-providers-port` from `origin/main`; commit per task; NEVER push, never open a PR.
- Word-sync always outranks line-sync; line-sync is streamed early via `onPartialResult`, never blocks the race.
- Only port APIs verified live on 2026-10-06 (see table); SimpMusic (Cloudflare 403 from datacenter, works on devices per native) ships but is race-participant only, never blocking.
- No UI/state/logic change outside: Settings Timing group, karaoke toolbar source menu, provider plumbing.
- `flutter analyze` clean + `flutter test test/` green (except pre-existing `karaoke_lyrics_test.dart` load failure from missing `kAddonClientSecret`, unrelated).

## API liveness (verified 2026-10-06, track "Shape of You"/Ed Sheeran unless noted)

- LRCLIB `lrclib.net/api/get|search` → 200 (already ported, untouched).
- Paxsenix `apple-music/lyrics?id=…&v=2` → 200 `syncType Syllable` (already ported, untouched; `&ttml=true` flaky 503, not used).
- BetterLyrics `lyrics-api.boidu.dev/getLyrics` → 200 TTML `itunes:timing="Word"`.
- lrc.red `lrc.red/api/v1?q=|track+artist|isrc=` → 200 Bini-identical schema (`results[]`: `track_name/artist_name/album_name/duration/isrc/timing_type/lyricsUrl`, `source HIT-LRC-RED`); `/s/{ISRC}.ttml` → 200 TTML `lrc:timing="Word"`. NOTE: `lyrics-api.binimum.org` 307-redirects to `lrc.red/api/v1` — Bini is dead, lrc.red is its successor; port BiniLyricsApi verbatim with base `https://lrc.red/api/v1`.
- Kugou `lyrics.kugou.com/search|download` → 200, full round-trip captured: id `531021744`, fmt `krc`, 9184-char payload saved as fixture input (`kugou_krc_b64.txt` in temp; commit a trimmed copy as `test/fixtures/kugou_sample_krc.b64`).
- Musixmatch `apic.musixmatch.com/ws/1.1/token.get` unsigned → 401 JSON (host alive; signed flow ported from native incl. HMAC `RJDefUswhwjkZDeM`, date `yyyyMMdd` UTC, token refresh on 401/402).
- SimpMusic `api-lyrics.simpmusic.org/v1/{videoId}` → 403 Cloudflare from datacenter curl (any UA); kept as non-blocking race entry (needs `PlayableTrack.videoId`, exists on desktop).

## Review Focus

- Wrong-cut lyrics (live/remix/cover served for studio request): every new provider gates on `lyricsSameVersion` + duration tiers — test in Task 2/3/5.
- KRC decrypt with ≤4-byte/short payload or bad accesskey returns null, never throws — test in Task 5.
- Musixmatch 401/402 mid-race refreshes token once, then gives up quietly — test in Task 6.
- Provider switch never serves the previous provider's cached result: cache key includes provider id + excludes — test in Task 8.
- SimpMusic 403/timeout never delays or poisons the race result — test in Task 7/8.

---

### Task 0: Line-by-line fix (diagnose first, TDD)

**Files:**
- Modify: `lib/features/lyrics/lyrics_repository.dart` and/or `lib/features/lyrics/karaoke_lyrics_view.dart` (wherever root cause lands)
- Test: `test/lyrics_line_sync_test.dart`

**Interfaces:**
- Consumes: existing `getLyrics(wordByWord:)` + `lyricsForDisplayMode` + `_AppleLineLyricsView`.
- Produces: line-synced-only tracks return usable `lines` for BOTH `wordByWord: true` (interpolated wipe) and `wordByWord: false` (clean line display), and the line view renders them.

- [ ] **Step 1: Reproduce with failing tests** (stubbed Dio, LRCLIB line-only + Apple empty fixtures): `getLyrics(wordByWord: false)` returns non-empty `lines` with `isSynced: true, isWordSynced: false`; `getLyrics(wordByWord: true)` on the same fixture returns non-empty `lines` (interpolated syllables OK). Run: `flutter test test/lyrics_line_sync_test.dart` Expected: FAIL on at least one (that failure IS the diagnosis).
- [ ] **Step 2: Root-cause per systematic-debugging** (trace `getLyrics` → `normalizeKaraokeTimings` → `lyricsForDisplayMode` → view branch; single hypothesis, minimal change). Record hypothesis + finding in ledger as `Task 0: Ruling`.
- [ ] **Step 3: Implement minimal fix** at the source, not the symptom.
- [ ] **Step 4: Run tests + analyze.** Run: `flutter test test/lyrics_line_sync_test.dart test/flutter_lyric_adapter_test.dart` Expected: PASS. `flutter analyze` on touched files: clean.
- [ ] **Step 5: Commit.** `git commit -m "fix(lyrics): line-by-line sync returns usable lines"`

### Task 1: Provider enum + pref + Settings picker

**Files:**
- Create: `lib/features/lyrics/lyrics_providers.dart` (enum only in this task)
- Modify: `lib/core/storage/prefs.dart:150-152` (add pref next to `wordByWord`)
- Modify: `lib/ui/settings/settings_page.dart:730-748` (`_Lyrics` group)
- Test: `test/lyrics_provider_pref_test.dart`

**Interfaces:**
- Consumes: `Prefs` SharedPreferences pattern (`lw_word_by_word`).
- Produces: `enum LyricsProviderId { auto, lrcRed, appleMusic, betterLyrics, kugou, simpMusic, musixmatch, lrclib }` with `id`, `title`, `subtitle`, `isWordProvider`, `fromId()` (AUTO fallback); `Prefs.lyricsProviderId` (`lw_lyrics_provider`, default `'auto'`).

Titles/subtitles (match native, `Lrc.Red` replaces LastWave slot): auto `Auto` / `Fastest word-sync wins, LRCLIB fallback`; lrcRed `Lrc.Red` / `Recording-matched word-sync first`; appleMusic `Apple Music` / `Syllable-synced Apple Music lyrics first`; betterLyrics `BetterLyrics` / `Word-synced lyrics first`; kugou `Kugou` / `KRC word-synced lyrics first`; simpMusic `Video-Match` / `Matched on the playing video first`; musixmatch `Catalog` / `Largest catalogue line-sync first`; lrclib `LRCLIB` / `Line-synced community lyrics first`.

- [ ] **Step 1: Write the failing test** `test/lyrics_provider_pref_test.dart`: `fromId('kugou') == LyricsProviderId.kugou`, `fromId('bogus') == auto`, `fromId(null) == auto`, all non-auto ids round-trip, `isWordProvider` true for all except auto/lrclib (lrclib false; auto false).
- [ ] **Step 2: Run it to verify it fails.** Run: `flutter test test/lyrics_provider_pref_test.dart` Expected: FAIL (file under test missing).
- [ ] **Step 3: Implement enum in `lib/features/lyrics/lyrics_providers.dart` + `lyricsProviderId` getter/setter in `prefs.dart` + ComboBox row in `_Lyrics` below the word-by-word switch** (ComboBox<String> pattern per settings_page.dart:597, value `prefs.lyricsProviderId`, `onChanged` → `onUpdate((p) => p.setLyricsProviderId(v))`).
- [ ] **Step 4: Run tests.** Run: `flutter test test/lyrics_provider_pref_test.dart` Expected: PASS. Run: `flutter analyze lib/features/lyrics/lyrics_providers.dart lib/core/storage/prefs.dart lib/ui/settings/settings_page.dart` Expected: clean.
- [ ] **Step 5: Commit.** `git add lib/features/lyrics/lyrics_providers.dart lib/core/storage/prefs.dart lib/ui/settings/settings_page.dart test/lyrics_provider_pref_test.dart` + `git commit -m "feat(lyrics): primary provider pref with Auto default and Settings picker"`

### Task 2: Shared matching + enhanced-LRC parsing helpers

**Files:**
- Modify: `lib/features/lyrics/lyrics_repository.dart` (append helpers; extend `parseLrc`)
- Test: `test/lyrics_match_parse_test.dart`

**Interfaces:**
- Consumes: nothing new.
- Produces: `bool lyricsSameVersion(String requestTitle, String candidateTitle)` (version-tags equality: live/concert/session/unplugged/acoustic/remix/cover/karaoke/instrumental/slowed/sped/nightcore/demo/lullaby/8d from bracket segments + trailing `- X` suffix); `bool lyricsTitlesMatchStrict(String a, String b)` (exact → 0.7-ratio contains → token Jaccard ≥0.5, plus leading `Artist - ` strip); `bool lyricsArtistsMatchStrict(String a, String b)` (exact → 0.6-ratio contains min-len 4 → Jaccard ≥0.5); `String lyricsForSearchTitle(String raw)` (strip feat/video/official credits only, keep version markers); `String lyricsForSearchArtist(String raw)` (strip ` - Topic`); `String lyricsDecodeEntities(String raw)` (`&#x..;`, `&#..;`, `&nbsp; &quot; &apos; &#39; &lt; &gt; &amp;` — `&amp;` last); `bool lyricsPlausibleDuration(List<LyricLine> lines, int? durationSeconds)` (reject timeline ending 45s+ past track end, or covering <50% while missing 90s+, min 3 lines / 60s track); extended `parseLrc` that also extracts inline word stamps `<m:ss.xx>` into syllables (native `parseWordRuns`: stamp starts word, ends at next stamp/line end/+800ms) and strips them from display text; `List<LyricLine> parseEnhancedLrc(String lrc)` (returns `parseLrc` result only if some line `hasSyllables`, else empty). Existing `parseLrc` callers keep working (pure addition for unstamped input).

- [ ] **Step 1: Write failing tests**: sameVersion rejects `Song (Live)` vs `Song`, accepts `Song (Remastered)` vs `Song`; strict title rejects `Love` vs `Love Me Like You Do`; artist rejects `Ann` vs `Annie`; forSearchTitle keeps `(Live)` drops `(feat. X)`/`[Official Video]`; decodeEntities `&#x41;&amp;` → `A&`; parseLrc on `[00:01.00]Hel<00:01.20>lo` yields syllables `[Hel@1000, lo@1200]` and text without stamps; parseEnhancedLrc returns empty for plain LRC; plausibleDuration rejects 300s-past-end timeline.
- [ ] **Step 2: Run to verify fail.** Run: `flutter test test/lyrics_match_parse_test.dart` Expected: FAIL.
- [ ] **Step 3: Implement helpers + parseLrc extension** in `lyrics_repository.dart` (port native `LrclibLyricsApi` companion + `parseWordRuns`/`stampToMs`/`plausibleDuration`).
- [ ] **Step 4: Run tests + analyze.** Run: `flutter test test/lyrics_match_parse_test.dart test/flutter_lyric_adapter_test.dart` Expected: PASS (adapter untouched, guards regressions).
- [ ] **Step 5: Commit.** `git commit -m "feat(lyrics): strict version-aware matching and enhanced-LRC word stamps"`

### Task 3: BetterLyrics provider (boidu.dev, 3 endpoints)

**Files:**
- Modify: `lib/features/lyrics/lyrics_providers.dart` (add fetch function)
- Test: extend `test/lyrics_match_parse_test.dart`? No — new `test/lyrics_better_test.dart` (pure parse tests: no network in unit tests).

**Interfaces:**
- Consumes: Task 2 (`parseEnhancedLrc`, `lyricsDecodeEntities`), existing `LyricsRepository.parseTtml`.
- Produces: `Future<LyricsResult?> fetchBetterLyrics(Dio dio, {title, artist, album, durationSeconds})`: tries `https://lyrics-api.boidu.dev/getLyrics`, `/ttml/getLyrics`, `/qq/getLyrics` with params `s/title, a/artist, d/secs, al/album` (raw then cleaned retry); `parseBetterDocument(String raw)` tries TTML (`<tt` or ttml ns → `parseTtml`) → karaoke `[start,dur](wstart,wdur)word` (`parseBetterKaraoke`) → `parseEnhancedLrc` → `parseLrc` → regex TTML fallback; JSON envelope unwrap: keys `ttml,ttmlContent,lyrics,lrc,content,text,plainLyrics,syncedLyrics,line,lines,lyric,data,result,response`, reject `isError:true`/`ok:false`, nested-JSON-string unwrap; source `BetterLyrics (Word-Sync|Line-Sync)` after `lyricsPlausibleDuration` gate.

- [ ] **Step 1: Write failing tests** with inline fixtures: TTML doc → word-synced lines; karaoke doc `[1000,2000](1000,200)Hello (1500,300)world` → syllables + text `Hello world`; `{"ttml":"<tt…>"}` envelope unwrap; `{"isError":true}` → null.
- [ ] **Step 2: Run to verify fail.** Run: `flutter test test/lyrics_better_test.dart` Expected: FAIL.
- [ ] **Step 3: Implement** `parseBetterDocument/unwrapBetterPayload/parseBetterKaraoke/fetchBetterLyrics` in `lyrics_providers.dart` (port native `BetterLyricsApi.parseDocument/unwrapPayload/parseKaraokeLrc/queryEndpoints/fetchDocument`).
- [ ] **Step 4: Run tests + analyze.** Expected: PASS, clean.
- [ ] **Step 5: Commit.** `git commit -m "feat(lyrics): BetterLyrics word-sync provider"`

### Task 4: Lrc.Red provider (Bini port, new base URL)

**Files:**
- Modify: `lib/features/lyrics/lyrics_providers.dart`
- Test: `test/lyrics_lrcred_test.dart`

**Interfaces:**
- Consumes: Task 1 enum (`lrcRed`), Task 2 (`lyricsSameVersion`, `BiniHit`-equivalent scoring), `parseTtml`.
- Produces: `class LrcRedHit { trackName, artistName, duration, isrc, timingType, lyricsUrl }`; `Future<LrcRedHit?> identifyLrcRed(...)` (ISRC direct → word-first; else shaped `track/artist/album/duration` then free-text `q = "artist - title"`, `selectBest`: sameVersion + score ≥5 (exact title 3 / fuzzy 1 + artist 2 + duration 3/1), word-first then closest duration); `fetchLrcRedLines(LrcRedHit hit)` GETs `lyricsUrl` (`https://lrc.red/s/{ISRC}.ttml`) → `parseTtml`; `fetchLrcRed(...)` returns `LyricsResult` source `Lrc.Red (Word-Sync|Line-Sync)` after `lyricsPlausibleDuration`. Base `https://lrc.red/api/v1` (NOT binimum — verified 307).

- [ ] **Step 1: Write failing tests** on recorded payloads (paste the verified 2026-10-06 `/api/v1?q=` Shape-of-You JSON shape): selectBest prefers `timing_type word` + duration 234 over Latin Remix 238; score floor rejects artist-mismatch hit; `timing_type` word → `isWordSynced` true after TTML parse.
- [ ] **Step 2: Run to verify fail.** Expected: FAIL.
- [ ] **Step 3: Implement** (port `BiniLyricsApi.identify/query/selectBest/scoreHit/fetchLinesFor/fetchLyrics` with new base + source strings).
- [ ] **Step 4: Run tests + analyze.** Expected: PASS, clean.
- [ ] **Step 5: Commit.** `git commit -m "feat(lyrics): Lrc.Red recording-matched provider (replaces Bini/LastWave slot)"`

### Task 5: Kugou KRC provider (search → decrypt → parse)

**Files:**
- Modify: `lib/features/lyrics/lyrics_providers.dart`
- Test: `test/lyrics_kugou_test.dart` + fixture `test/fixtures/kugou_sample_krc.b64` (trimmed captured payload)

**Interfaces:**
- Consumes: Task 2 strict matchers.
- Produces: `String? decryptKugouKrc(String base64Content)` (Base64 → drop 4 magic bytes → XOR 16-byte key `[0x40,0x47,0x61,0x77,0x5E,0x32,0x74,0x47,0x51,0x36,0x31,0x2D,0xCE,0xD2,0x6E,0x69]` → `ZLibCodec().decode`, null on short/bad input); `List<LyricLine> parseKugouKrc(String krc)` (`[offset:]` global shift, `[start,dur]<off,dur,?>syllable` lines, blank-syllable → trailing space on previous, first-line `Artist - Title` + credit prefixes (`lyrics by/written by/作词/作曲/…`) dropped); `fetchKugou(...)` search `https://lyrics.kugou.com/search?ver=1&man=yes&client=pc&keyword="artist - title"&duration={ms}` → text-mandatory match (sameVersion + artist + title, duration tiers 8s→30s→closest) → download `.../download?ver=1&client=pc&id=&accesskey=&fmt=krc&charset=utf8` → decrypt → parse → source `Kugou KRC (Word-Sync)` after plausible gate. UA `Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36`.

- [ ] **Step 1: Write failing tests**: fixture decrypts to text containing `[offset`/`[` lines; `decryptKugouKrc('AAAA')` → null; parse drops `作词 : X` credit row; blank `<…> ` syllable appends space; wrong-version candidate (`Song (Live)`) rejected by selector.
- [ ] **Step 2: Run to verify fail.** Expected: FAIL.
- [ ] **Step 3: Implement** (port `KugouLyricsApi.decryptKrc/parseKrc/fetchWordLyrics` incl. credit regex).
- [ ] **Step 4: Run tests + analyze.** Expected: PASS, clean.
- [ ] **Step 5: Commit.** `git commit -m "feat(lyrics): Kugou KRC word-sync provider"`

### Task 6: Musixmatch provider (signed web-client flow)

**Files:**
- Modify: `lib/features/lyrics/lyrics_providers.dart`
- Test: `test/lyrics_musixmatch_test.dart`

**Interfaces:**
- Consumes: `crypto` Hmac(sha256, `RJDefUswhwjkZDeM`).
- Produces: `String musixmatchSign(String url)` (`url + yyyyMMdd-UTC` → HMAC-SHA256 → Base64 → `&signature={enc}&signature_protocol=sha256`); `subtitleToLrc(String subtitleBody)` (JSON `[{text,time:{total:sec}}]` → `[mm:ss.mmm]text`); `fetchMusixmatch(...)` (`token.get` cached, refresh once on 401/402 → `track.search` q_track/q_artist, score ≥80 with mandatory artist → `track.subtitle.get` requires `has_subtitles==1` → `parseLrc`) source `Catalog (Line-Sync)` after plausible gate. Base `https://apic.musixmatch.com/ws/1.1`, `app_id web-desktop-app-v1.0`.

- [ ] **Step 1: Write failing tests**: sign output contains `signature_protocol=sha256` and changes with date override (test via injectable date param defaulting to now); subtitle JSON → exact `[00:00.140]` LRC lines; scorer rejects artist-mismatch ≥ threshold.
- [ ] **Step 2: Run to verify fail.** Expected: FAIL.
- [ ] **Step 3: Implement** (port `MusixmatchLyricsApi` incl. token cache var + single retry).
- [ ] **Step 4: Run tests + analyze.** Expected: PASS, clean.
- [ ] **Step 5: Commit.** `git commit -m "feat(lyrics): Musixmatch catalogue line-sync provider"`

### Task 7: SimpMusic provider (videoId-keyed)

**Files:**
- Modify: `lib/features/lyrics/lyrics_providers.dart`
- Test: `test/lyrics_simp_test.dart`

**Interfaces:**
- Consumes: Task 2 (`parseEnhancedLrc`, desktop `parseLrc`).
- Produces: `fetchSimpMusic(Dio dio, {String? videoId, int? durationSeconds})`: null videoId → null; GET `https://api-lyrics.simpmusic.org/v1/{videoId}` → `success:true` → track within ±10s, closest → `richSyncLyrics`→`parseEnhancedLrc` else `syncedLyrics`→`parseLrc`; source `Video-Match (Word-Sync|Line-Sync)`; any 403/timeout → null (never throws).

- [ ] **Step 1: Write failing tests**: fixture `{"success":true,"data":[{"duration":213,"richSyncLyrics":"[00:01.00]Hi<00:01.20>there"}]}` → word-synced; duration 400 vs 213 → null; `{"success":false}` → null.
- [ ] **Step 2: Run to verify fail.** Expected: FAIL.
- [ ] **Step 3: Implement** (port `SimpMusicLyricsApi.fetchLyrics`).
- [ ] **Step 4: Run tests + analyze.** Expected: PASS, clean.
- [ ] **Step 5: Commit.** `git commit -m "feat(lyrics): SimpMusic video-matched provider"`

### Task 8: Orchestrator race (preferred head-start → word race → fallbacks)

**Files:**
- Modify: `lib/features/lyrics/lyrics_repository.dart` (`getLyrics` only; LRCLIB/Apple privates untouched)
- Test: `test/lyrics_race_test.dart` (fake provider fns via injectable override hook — add `@visibleForTesting setProviderOverrides` map on repository; production path unchanged)

**Interfaces:**
- Consumes: Tasks 1–7, existing `_fetchLrclib/_fetchAppleWordByWord/isBetterCandidate/normalizeKaraokeTimings`.
- Produces: `getLyrics` gains optional `{String preferredProviderId = 'auto', Set<String> excludeProviderIds = const {}}`: cache key `title|artist|album|duration|wordByWord|preferred|sortedExcludes`; preferred==lrclib → LRCLIB first (stashed fallback, word later still wins); preferred word-provider → 4s head-start single attempt (line result stashed + `onPartialResult`); 12s word race over non-excluded {lrcRed, apple, betterLyrics, kugou, simpMusic(videoId only)} via `Stream.fromFutures` — first `isWordSynced` + plausible wins, first plausible line result streamed as partial; explicit preferred line-fallback outranks race line; then Musixmatch (non-excluded); then LRCLIB if not attempted; empty fallback. Per-request `.timeout(10s)` → null. `wordByWord:false` short-circuits on first settled (local-download path in download_manager unchanged).

- [ ] **Step 1: Write failing tests** (overrides): preferred kugou word hit beats faster apple line hit; exclude={kugou} with kugou-only-word returns apple line; cache key differs across preferred ids (switching never replays stale); 12s race resolves from partial when all-word hang (fake delayed futures).
- [ ] **Step 2: Run to verify fail.** Expected: FAIL.
- [ ] **Step 3: Implement** race in `getLyrics` (port native `getLyrics` flow §§preferred/race/fallback, minus local-download + Bini-ISRC fan-out which have no desktop counterpart).
- [ ] **Step 4: Run full suite.** Run: `flutter test test/lyrics_race_test.dart test/lyrics_better_test.dart test/lyrics_lrcred_test.dart test/lyrics_kugou_test.dart test/lyrics_musixmatch_test.dart test/lyrics_simp_test.dart test/lyrics_match_parse_test.dart test/lyrics_provider_pref_test.dart test/flutter_lyric_adapter_test.dart` Expected: all PASS. Run: `flutter analyze lib test` Expected: clean.
- [ ] **Step 5: Commit.** `git commit -m "feat(lyrics): word-first provider race with preferred head-start and exclusions"`

### Task 9: Now Playing source switcher (per-track override + retry-excluding-current)

**Files:**
- Modify: `lib/ui/lyrics/lyrics_panel.dart` (`waveLyricsProvider` passes pref + override + excludes), `lib/features/lyrics/karaoke_lyrics_view.dart` (`_KaraokeToolbar`: source menu)
- Test: widget test `test/lyrics_source_menu_test.dart` (menu lists Auto + 7 providers + "Try another source"; tapping provider triggers refetch — assert via provider override state, pump with fake repository if harness allows, else assert menu items + state transitions only)

**Interfaces:**
- Consumes: Task 8 params; `lyricsOffsetProvider`-style `StateProvider.family<String?, String> lyricsProviderOverrideProvider` (queueKey → provider id or null) + `StateProvider.family<Set<String>, String> lyricsExcludedProvidersProvider` in `lyrics_panel.dart`.
- Produces: toolbar source chip (existing title text becomes the menu anchor — fluent `Flyout`/`MenuFlyout` with checked current source): rows Auto (clears override+excludes) + 7 providers (sets override; ALSO adds previous current provider id to excludes when it differs, so the switch "attempts best excluding current") + `Try another source` (keeps Auto, adds current result's provider id to excludes, `forceRefresh: true`); any change invalidates `waveLyricsProvider(queueKey)`. Mapping result→provider id: match `result.source` prefix (`Lrc.Red`, `Apple Music`, `BetterLyrics`, `Kugou KRC`, `Video-Match`, `Catalog`, `lrclib`/default LRCLIB).

- [ ] **Step 1: Write failing widget/state tests**: override+exclude state transitions; source→provider mapping for all 7 prefixes + unknown → null.
- [ ] **Step 2: Run to verify fail.** Expected: FAIL.
- [ ] **Step 3: Implement** providers + menu (follow `_MiniIconButton`/`LWTooltip` toolbar idioms; no layout change otherwise).
- [ ] **Step 4: Run tests + analyze.** Expected: PASS, clean.
- [ ] **Step 5: Commit.** `git commit -m "feat(lyrics): now-playing source switcher with exclude-current retry"`

### Task 10: Full verification, local branch only

- [ ] **Step 1: Run full verification.** Run: `flutter analyze` Expected: clean. Run: `flutter test test/lyrics_provider_pref_test.dart test/lyrics_match_parse_test.dart test/lyrics_better_test.dart test/lyrics_lrcred_test.dart test/lyrics_kugou_test.dart test/lyrics_musixmatch_test.dart test/lyrics_simp_test.dart test/lyrics_race_test.dart test/lyrics_source_menu_test.dart test/flutter_lyric_adapter_test.dart test/audio_output_test.dart` Expected: all PASS (`karaoke_lyrics_test.dart` excluded — pre-existing `kAddonClientSecret` load failure on clean main).
- [ ] **Step 2: Confirm no push.** Run: `git log --oneline origin/main..HEAD` (10 commits + branch point) and `git status --porcelain` (clean). No `git push`, no `gh pr` commands.
- [ ] **Step 3: Final local commit if needed** (nothing should remain).

## File map

- NEW `lib/features/lyrics/lyrics_providers.dart` — enum + 5 fetchers + Better/LrcRed/Kugou/Musixmatch/Simp helpers.
- EDIT `lib/features/lyrics/lyrics_repository.dart` — Task 2 helpers, Task 8 race (LRCLIB/Apple privates untouched).
- EDIT `lib/core/storage/prefs.dart` — `lyricsProviderId`.
- EDIT `lib/ui/settings/settings_page.dart` — `_Lyrics` ComboBox.
- EDIT `lib/ui/lyrics/lyrics_panel.dart` — override/exclude providers + plumbing.
- EDIT `lib/features/lyrics/karaoke_lyrics_view.dart` — toolbar source menu only.
- NEW tests `test/lyrics_{provider_pref,match_parse,better,lrcred,kugou,musixmatch,simp,race,source_menu}_test.dart` + `test/fixtures/kugou_sample_krc.b64`.
