#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <timeapi.h>
#pragma comment(lib, "winmm.lib")

#include "flutter_window.h"
#include "utils.h"

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
