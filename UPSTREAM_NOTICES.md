# Upstream notices

LastWave-iOS incorporates and adapts user-interface code from
[Clash-Projects/LastWave-Native](https://github.com/Clash-Projects/LastWave-Native),
Copyright the LastWave-Native contributors, licensed under the GNU General Public
License, version 3.0 (GPL-3.0).

The Native UI implementation is being ported from Android Jetpack Compose to
Flutter/Dart for iOS and iPadOS. Ported or adapted files will be identified in
their source headers and in this document as the migration progresses.

The full GPL-3.0 license is included in `LICENSE`. This repository's combined
work is distributed under GPL-3.0, subject to the terms of that license and
the separate licenses of third-party dependencies and assets.

## Adapted UI files

- `lib/ui/app_shell/mobile_shell.dart`: the floating three-destination navigation dock is adapted from `app/src/main/java/com/lastwave/app/ui/shell/MainShell.kt` in LastWave-Native. The Jetpack Compose implementation was translated to Flutter/Dart.

- `lib/ui/home/home_page.dart`: the greeting/date header adapts the typography and hierarchy of LastWave-Native's `ui/feed/FeedTiles.kt` `ExpressiveGreetingHeader`; translated to Flutter while retaining LastWave-iOS's existing Edit Home and Last.fm connection actions.
- `lib/ui/now_playing/now_playing_page.dart`: the full-screen player backdrop adapts the blurred, enlarged album-art stage and contrast scrim from LastWave-Native's `ui/player/FullPlayer.kt`; the existing optional animated ambient layer and Flutter playback controls remain intact.
- `lib/ui/app_shell/mobile_shell.dart`: the mobile mini-player card proportions, larger rounded artwork, and single-card visual hierarchy adapt `ui/player/MiniPlayer.kt`; Flutter playback, download, like, playlist, and stream-detail actions remain wired to the existing services.
- `lib/ui/player_dock/player_dock.dart`: the immersive transport dock exposes the live source-quality badge on wider iPad layouts, adapting the quality indicator from LastWave-Native's `ui/player/FullPlayer.kt` while keeping narrow phone controls uncluttered.

- `lib/ui/app_shell/mobile_shell.dart`: the primary destination is labeled **Feed** to match `MainTab.FEED` in `ui/shell/MainShell.kt`. The mini-player is centered and constrained to the Native 680dp maximum width, with 14dp horizontal gutters, following `ui/player/MiniPlayer.kt`; existing Flutter transport and library actions are retained.

- `lib/ui/home/home_page.dart`: the Feed greeting/date, centered 920dp content rail, artwork-backed Infinite Radio hero, and fixed Quick Access row are translated from `ui/feed/FeedTiles.kt` and `ui/feed/FeedScreen.kt`. The radio button uses the existing Flutter playback queue and endless-radio service.
- `lib/ui/home/discovery_sections.dart` and `lib/app/router.dart`: the New Releases quick-access destination reuses the existing Flutter catalogue/filter implementation rather than adding a second data source.
- `lib/ui/app_shell/mobile_shell.dart`: the Home sections editor remains accessible from More after matching Native's compact greeting header.

- `lib/ui/home/home_page.dart`: `My genres` and the three-track horizontal Quick Picks columns adapt `TasteStrip` and `QuickPicksRows` from `ui/feed/FeedTiles.kt`. Genre chips use the existing Last.fm/local genre provider and YouTube Music genre-track provider, with the existing playback service to start radio.
- `lib/features/feed/home_shelf_layout.dart`: configurable Flutter shelf order now places supported Native Feed sections in Native's default sequence; greeting, Infinite Radio, and Quick Access remain structural elements.
