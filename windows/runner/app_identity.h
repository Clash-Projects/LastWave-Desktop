#ifndef RUNNER_APP_IDENTITY_H_
#define RUNNER_APP_IDENTITY_H_

// Single process identity for the desktop shell: taskbar grouping and the
// SMTC source label (volume flyout / lock screen). Without an explicit
// AppUserModelID the media flyout renders this app as "Unknown app".
// IMPORTANT: this ID must match the Start Menu shortcut's AppUserModelID
// (see windows/installer.iss [Icons] AppUserModelID) AND the window
// property store ID set in flutter_window.cpp AND the SMTC AppMediaId set
// in smtc_channel.cpp. If any one of them differs - or if no Start Menu
// shortcut with this ID exists (e.g. `flutter run` without installing)
// - the shell cannot resolve display name/icon and falls back to
// "Unknown app" with no logo.
constexpr wchar_t kLastWaveAppUserModelId[] = L"com.lastwave.lastwave_desktop";

#endif  // RUNNER_APP_IDENTITY_H_

