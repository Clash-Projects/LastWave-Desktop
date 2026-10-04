#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "win32_window.h"

namespace lastwave {
class WasapiChannel;
class SmtcChannel;
}

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<lastwave::WasapiChannel> wasapi_channel_;
  std::unique_ptr<lastwave::SmtcChannel> smtc_channel_;
  // Set at the start of OnDestroy: DestroyWindow() re-enters the WndProc
  // via a user-callback while teardown is in flight (release crash
  // flutter_windows+1e220). Once set, messages go to DefWindowProc
  // instead of the half-torn-down view controller. Cleared at the end
  // of OnCreate: Win32Window::Create() calls Destroy() before the
  // window exists, which would otherwise latch this on forever.
  bool destroying_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
