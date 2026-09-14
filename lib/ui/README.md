// LastWave — Limusic-grade desktop presentation layer.
//
// New visual system ownership:
//   lib/ui/theme/        tokens + Fluent theme factory
//   lib/ui/components/   shared Fluent-based primitives
//   lib/ui/navigation/   grouped destinations + side rail
//   lib/ui/app_shell/    title bar + shell + command palette
//   lib/ui/player_dock/  integrated bottom dock
//   lib/ui/queue/        contextual queue panel
//   lib/ui/lyrics/       premium lyrics reader
//   lib/ui/home/         editorial home
//   lib/ui/search/       categorized search
//   lib/ui/library/      library home
//   lib/ui/collections/  albums / artists / playlists / detail / liked /
//                        downloads / history
//   lib/ui/now_playing/  two-region now playing
//   lib/ui/settings/     Fluent settings
//
// This layer uses fluent_ui as the single component system. It does NOT
// import the superseded editorial ledger kit (design_system/components,
// design_system/tokens, widgets/, shell/). Business logic is reused
// through existing Riverpod providers — no duplicated repositories,
// playback services, or network logic.
library;
