# Playlist Link Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Paste a public YouTube, Spotify, or Apple Music playlist link on the Playlists page and import it as a local playlist with matched playable tracks — no account needed.

**Architecture:** One new feature file owns link detection, keyless page scrapers (ported from LastWave-Native, both verified live 2026-10-07), YouTube-direct import, and Spotify/Apple row→YouTube matching; the Playlists hero gains an Import button opening a paste-link dialog with fetch preview and N-of-M report.

**Tech Stack:** Flutter/Dart, Riverpod, Dio (redirects + plain HTML), existing `InnertubeApi.fetchPlaylist` / `findBestMatchOrNull`, `playlistRepositoryProvider.createCustom` + `addTrack`.

**Spec:** User directive 2026-10-07 (port native Spotify + Apple link handling, add YT public playlist, Import button + paste-link option on Playlists page) + native source `data/playlist/{ExternalPlaylistModels,SpotifyPlaylistImporter,AppleMusicPlaylistImporter}.kt` + `InnerTubeMusicApi.extractPlaylistId/findBestMatchOrNull`.

## Global Constraints

- New branch `feat/playlist-link-import` in worktree `.worktrees/playlist-import` from `origin/main`; commit per task; NEVER push, never open a PR.
- Public/unlisted links only; no login, no API keys, no OAuth anywhere in this feature.
- TDD every task: test fails first with the expected failure, then passes; `flutter analyze` clean on touched files.
- No UI changes outside the Playlists hero (Import button) and one new dialog.
- Unmatched rows are dropped but counted; a fetch that yields zero rows is an error, never an empty playlist.

## Review Focus

- Private/deleted playlist link → friendly "could not read that playlist" error inside the dialog, never a hang (20s fetch cap) — test in Task 3.
- `spotify.link` short URL → redirects followed to the canonical playlist id — test in Task 1.
- Apple ld+json fallback rows carry no artist → counted as skipped, import still completes — test in Task 2.
- Match misses → dropped, dialog reports "N of M matched", playlist created with hits — test in Task 4.
- YT mix/radio id (`RD…`) pasted → rejected with a friendly message, not browsed — test in Task 3.

---

### Task 1: Link models + detection

**Files:**
- Create: `lib/features/library/playlist_link.dart` (enum + detect + extract, nothing else yet)
- Test: `test/playlist_link_test.dart`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum PlaylistLinkSource { youtube, spotify, appleMusic }` with `label`; `PlaylistLinkSource? detectPlaylistLink(String raw)` (spotify.com/spotify.link/`spotify:` prefix → spotify; music.apple.com → appleMusic; `list=`/`playlist/`/youtu.be/youtube.com/music.youtube.com → youtube; else null); `String? extractPlaylistId(String raw, PlaylistLinkSource source)` (spotify `playlist/<id>` incl. locale segment + `spotify:playlist:<id>`; apple `pl.<id>` incl. slug-less; youtube delegates to existing `InnertubeApi.extractPlaylistId` semantics: `list=` param, `playlist/` path, else trimmed raw).

- [ ] **Step 1: Write the failing test** `test/playlist_link_test.dart`: detect covers `https://open.spotify.com/playlist/ABC?si=x`, `https://open.spotify.com/intl-de/playlist/ABC`, `spotify:playlist:ABC`, `https://music.apple.com/us/playlist/slug/pl.abc123`, `https://music.youtube.com/playlist?list=PLxyz`, `https://www.youtube.com/watch?v=a&list=PLxyz`, garbage → null; extract returns `ABC`, `pl.abc123`, `PLxyz` respectively; `spotify.link/ABC` detects as spotify.
- [ ] **Step 2: Run test to verify it fails.** Run: `flutter test test/playlist_link_test.dart` Expected: FAIL (file under test missing).
- [ ] **Step 3: Implement** enum + two functions in `lib/features/library/playlist_link.dart` (port native `ExternalPlaylistLink` regexes).
- [ ] **Step 4: Run test to verify it passes.** Run: `flutter test test/playlist_link_test.dart` Expected: PASS.
- [ ] **Step 5: Commit.** `git add lib/features/library/playlist_link.dart test/playlist_link_test.dart` + `git commit -m "feat(playlist): link source detection and id extraction"`

### Task 2: Spotify + Apple page parsers (pure, fixture-tested)

**Files:**
- Modify: `lib/features/library/playlist_link.dart` (append parsers + row/result types)
- Test: `test/playlist_link_parse_test.dart` + `test/fixtures/spotify_embed_sample.html`, `test/fixtures/apple_playlist_sample.html` (trimmed from the live pages captured 2026-10-07 to 2–3 tracks each, markers intact)

**Interfaces:**
- Consumes: Task 1 (nothing directly; same file).
- Produces: `class PlaylistLinkRow { title, artist }`, `class PlaylistLinkPage { source, title, rows }`, `PlaylistLinkPage parseSpotifyEmbed(String html, [fallbackTitle])` (`__NEXT_DATA__` script → walk JSON tree → `spotify:track:` rows with `title`/`subtitle`, first `spotify:playlist:` name as title; never throws, unreadable → empty rows), `PlaylistLinkPage parseApplePage(String html)` (tier 1 `serialized-server-data` objects with `title` + `artistName`, tier 2 `schema:music-playlist` names with empty artist; title from ld+json `name` else `<title>` minus ` - Apple Music` suffix).

- [ ] **Step 1: Write the failing tests**: Spotify fixture → title + 2 rows with exact title/artist strings from the fixture; garbage HTML → empty rows, no throw; Apple fixture tier 1 → rows with artists; tier-2-only HTML (strip server-data from a copy) → rows with empty artist; title parsed without ` - Apple Music` suffix.
- [ ] **Step 2: Run tests to verify they fail.** Run: `flutter test test/playlist_link_parse_test.dart` Expected: FAIL.
- [ ] **Step 3: Implement** parsers (port native `parseEmbedPage`/`parsePage`: JSON-tree walk, `&nbsp;` collapse, HTML-entity unescape with `&amp;` last, depth cap 256).
- [ ] **Step 4: Run tests to verify they pass.** Run: `flutter test test/playlist_link_parse_test.dart test/playlist_link_test.dart` Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(playlist): keyless Spotify and Apple parsers"`

### Task 3: Fetchers (network, stub-Dio tested)

**Files:**
- Modify: `lib/features/library/playlist_link.dart` (append fetch functions)
- Test: extend `test/playlist_link_parse_test.dart` (stub-Dio cases)

**Interfaces:**
- Consumes: Tasks 1–2.
- Produces: `Future<PlaylistLinkPage> fetchSpotifyPlaylist(Dio dio, String urlOrId)` (id via Task 1 else throw `FormatException`; GET `https://open.spotify.com/embed/playlist/<id>` desktop UA, 20s timeout; non-200 → throw; parse body), `Future<PlaylistLinkPage> fetchApplePlaylist(Dio dio, String urlOrId)` (verbatim URL, or `https://music.apple.com/us/playlist/<id>` fallback, or bare `pl.<id>`; desktop Mac UA + `Accept-Language: en-US`; null body → throw; parse body). Both reject YT mix ids (`RD…`) with `FormatException` before any fetch.

- [ ] **Step 1: Write the failing tests**: stub Dio serving the Task 2 fixtures → parsed pages; 404 stub → throws; garbage id (`not a link`) → `FormatException`; `RDxyz` → `FormatException` without any HTTP call (assert zero requests).
- [ ] **Step 2: Run tests to verify they fail.** Expected: FAIL (functions missing).
- [ ] **Step 3: Implement** the two fetchers (Dio `responseType: plain`, per-request 20s `.timeout()`).
- [ ] **Step 4: Run tests.** Run: `flutter test test/playlist_link_parse_test.dart` Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(playlist): Spotify and Apple playlist fetchers"`

### Task 4: Import flow (match + create local playlist)

**Files:**
- Create: `lib/features/library/playlist_import.dart`
- Test: `test/playlist_import_test.dart`

**Interfaces:**
- Consumes: Tasks 1–3 (`detectPlaylistLink`, `extractPlaylistId`, fetchers, `PlaylistLinkPage`), existing `InnertubeApi.fetchPlaylist` / `findBestMatchOrNull`, `playlistRepositoryProvider.createCustom` / `addTrack(id, StoredTrack)`.
- Produces: `Future<PlaylistImportPreview> previewPlaylistLink({required InnertubeApi api, required Dio dio, required String rawLink})` (detect → null means `FormatException('That does not look like a playlist link')`; youtube → `api.fetchPlaylist` direct tracks mapped to `StoredTrack(name/title, artist, artworkUrl, videoId)`; spotify/apple → fetch page then match rows in chunks of 5 via `api.findBestMatchOrNull` with 10s per-track timeout, misses dropped; returns `PlaylistImportPreview(title, totalRows, matchedTracks)`; zero matched → throw `StateError('No playable tracks found')`), `Future<SavedPlaylist> importPreview({required PlaylistRepository repo, required PlaylistImportPreview preview})` (`createCustom(preview.title)` then `addTrack` per matched track, returns the created playlist).

- [ ] **Step 1: Write the failing tests** (fake api via subclass override of `fetchPlaylist`/`findBestMatchOrNull`, stub Dio for pages): YT link → direct tracks, no matching calls; Spotify rows → one miss dropped, preview counts `totalRows: 3, matched: 2`; garbage link → `FormatException`; all-miss → `StateError`; `importPreview` creates playlist with exactly the matched tracks (fake repo or real `PlaylistRepository` with temp db? use a fake implementing the two methods via subclass if constructible, else record calls with a hand fake class — decide at implementation, minimal seam).
- [ ] **Step 2: Run tests to verify they fail.** Expected: FAIL.
- [ ] **Step 3: Implement** preview + import (bounded fan-out: 5-at-a-time `Future.wait` chunks).
- [ ] **Step 4: Run tests + full lyric-safe suite.** Run: `flutter test test/playlist_link_test.dart test/playlist_link_parse_test.dart test/playlist_import_test.dart` Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(playlist): link preview and local import flow"`

### Task 5: Playlists page Import button + paste-link dialog

**Files:**
- Modify: `lib/ui/collections/playlists_page.dart:83-93` (add Import to hero `primaryActions`), `lib/ui/collections/playlist_dialogs.dart` (append `showWaveImportPlaylist`)
- Test: `test/playlist_import_dialog_test.dart` (link→preview state machine without widgets: drive `previewPlaylistLink` states loading/ready/error through a tiny controller? If dialog logic stays inline in the widget, test only the pure detect→fetch→preview mapping already covered in Task 4; this task's test asserts dialog button wiring via widget pump only if cheap — otherwise analyze-only + manual QA note in ledger)

**Interfaces:**
- Consumes: Task 4.
- Produces: `showWaveImportPlaylist(BuildContext context, WidgetRef ref)` ContentDialog (follows `showWaveCreatePlaylist` idiom): TextBox paste field (autofocus, hint `Paste a YouTube, Spotify or Apple Music playlist link…`), live source label via `detectPlaylistLink`, Fetch → progress → preview line `"<title>" · <matched> of <total> tracks matched` or error text → Import (FilledButton, enabled only on ready preview) creates via `importPreview` then `context.go('/playlists/<id>')`. Import hero button (icon `FluentIcons.download` or `FluentIcons.link`, label `Import`) beside New.

- [ ] **Step 1: Write the failing test** per Interfaces (or ledger a ruling if widget-pump is impractical: `Task 5: Ruling: dialog verified by analyze + manual QA — <why>`).
- [ ] **Step 2: Implement** button + dialog.
- [ ] **Step 3: Verify.** Run: `flutter analyze` on touched files (clean) + `flutter test test/ test/playlist_link_test.dart test/playlist_link_parse_test.dart test/playlist_import_test.dart` (all PASS).
- [ ] **Step 4: Commit.** `git commit -m "feat(playlist): Import button and paste-link dialog"`

## File map

- NEW `lib/features/library/playlist_link.dart` — source enum, detect/extract, Spotify + Apple parsers + fetchers.
- NEW `lib/features/library/playlist_import.dart` — preview (YT direct / match rows) + create-local import.
- EDIT `lib/ui/collections/playlists_page.dart` — hero Import button.
- EDIT `lib/ui/collections/playlist_dialogs.dart` — `showWaveImportPlaylist`.
- NEW tests `test/playlist_link_test.dart`, `test/playlist_link_parse_test.dart`, `test/playlist_import_test.dart` (+ dialog test or ledgered ruling) + `test/fixtures/spotify_embed_sample.html`, `test/fixtures/apple_playlist_sample.html`.
