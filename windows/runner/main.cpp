#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <shobjidl.h>
#include <timeapi.h>
#pragma comment(lib, "winmm.lib")

#include <uxtheme.h>
#pragma comment(lib, "uxtheme.lib")

#include "flutter_window.h"
#include "utils.h"

#include "app_identity.h"

// Opt the process into dark Win32 popup menus (tray icon menu, ...).
//
// tray_manager shows a raw HMENU via TrackPopupMenu, which renders light
// unless the app allows dark mode. Both uxtheme entry points are
// undocumented ordinals, so resolve them dynamically and fail open on
// older Windows builds.
void EnableDarkWin32Menus() {
  HMODULE uxtheme = ::LoadLibraryExW(L"uxtheme.dll", nullptr,
                                     LOAD_LIBRARY_SEARCH_SYSTEM32);
  if (uxtheme == nullptr) return;
  using SetPreferredAppModeFn = int(WINAPI*)(int);
  using FlushMenuThemesFn = void(WINAPI*)();
  auto setPreferredAppMode = reinterpret_cast<SetPreferredAppModeFn>(
      ::GetProcAddress(uxtheme, MAKEINTRESOURCEA(135)));
  auto flushMenuThemes = reinterpret_cast<FlushMenuThemesFn>(
      ::GetProcAddress(uxtheme, MAKEINTRESOURCEA(136)));
  constexpr int kAllowDark = 1;
  if (setPreferredAppMode != nullptr) setPreferredAppMode(kAllowDark);
  if (flushMenuThemes != nullptr) flushMenuThemes();
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // 1ms system timer resolution for the life of the app. Dart cannot set
  // this (no FFI binding, and it is process-global by design). Windows
  // defaults to ~15.6ms granularity, which coarsens every Sleep-based
  // wait in the process: the BotGuard poll loop (100ms steps, worst case
  // ~115ms per iteration on the rare cipher-fallback path) and libmpv's
  // internal event/demuxer timing. Media players raise this during
  // playback; reverted on exit below.
  // Explicit app identity BEFORE any window exists: taskbar grouping
  // and the SMTC media-flyout source label ("Unknown app" otherwise).
  // Best-effort — the app runs fine without it.
  ::SetCurrentProcessExplicitAppUserModelID(kLastWaveAppUserModelId);

  ::timeBeginPeriod(1);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"lastwave_desktop", origin, size)) {
    ::timeEndPeriod(1);
    return EXIT_FAILURE;
  }
  // Dark owner-drawn theme for Win32 popup menus (tray menu included).
  // Ignored on builds without immersive dark menus — fails open to light.
  EnableDarkWin32Menus();
  ::SetWindowTheme(window.GetHandle(), L"DarkMode_Explorer", nullptr);
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::timeEndPeriod(1);
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
