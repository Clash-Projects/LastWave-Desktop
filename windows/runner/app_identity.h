#ifndef RUNNER_APP_IDENTITY_H_
#define RUNNER_APP_IDENTITY_H_

// Single process identity for the desktop shell: taskbar grouping and the
// SMTC source label (volume flyout / lock screen). Without an explicit
// AppUserModelID the media flyout renders this app as "Unknown app".
// Keep in sync with the installer shortcut ID if one is ever added.
constexpr wchar_t kLastWaveAppUserModelId[] = L"com.lastwave.lastwave_desktop";

#endif  // RUNNER_APP_IDENTITY_H_
