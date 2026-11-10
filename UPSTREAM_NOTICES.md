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
