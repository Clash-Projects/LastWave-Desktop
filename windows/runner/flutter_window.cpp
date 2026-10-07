#include "flutter_window.h"

#include <optional>

#include <propkey.h>
#include <propvarutil.h>
#include <shobjidl.h>

#include "app_identity.h"
#include "flutter/generated_plugin_registrant.h"
#include "smtc_channel.h"
#include "wasapi_channel.h"

namespace {

// Window-level AppUserModelID: GetForWindow-based SMTC resolves the
// flyout label/icon from the HWND's property store first, then falls
// back to the process ID set in main.cpp. Setting both to the same
// kLastWaveAppUserModelId keeps taskbar grouping + SMTC in sync.
// Best-effort: any failure degrades to the process-level ID.
void SetWindowAppUserModelId(HWND hwnd) {
  if (hwnd == nullptr) return;
  IPropertyStore* store = nullptr;
  if (FAILED(::SHGetPropertyStoreForWindow(
          hwnd, IID_PPV_ARGS(&store)))) {
    return;
  }
  PROPVARIANT pv{};
  if (SUCCEEDED(::InitPropVariantFromString(
          kLastWaveAppUserModelId, &pv))) {
    store->SetValue(PKEY_AppUserModel_ID, pv);
    store->Commit();
    ::PropVariantClear(&pv);
  }
  store->Release();
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  // Explicit window identity BEFORE the SMTC channel binds GetForWindow:
  // without this the shell falls back to "Unknown app" for the HWND
  // even when the process-level ID (main.cpp) is correct.
  SetWindowAppUserModelId(GetHandle());

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  wasapi_channel_ = std::make_unique<lastwave::WasapiChannel>(
      flutter_controller_->engine()->messenger());
  // SMTC (volume flyout / lock screen / media keys) binds the main window
  // only - the hidden BotGuard WebView never gets its own registration.
  // Best-effort: init failures degrade to silence inside the channel.
  smtc_channel_ = std::make_unique<lastwave::SmtcChannel>(
      flutter_controller_->engine()->messenger(), GetHandle());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  // Clear the teardown guard: Win32Window::Create() calls Destroy() (and
  // thus OnDestroy()) before the window exists, which latches destroying_.
  // From here on the view controller is live and delegates must run.
  destroying_ = false;
  return true;
}

void FlutterWindow::OnDestroy() {
  destroying_ = true;
  smtc_channel_.reset();
  wasapi_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  // Never forward once destroy has begun: DestroyWindow() re-enters here
  // on the same thread while flutter_controller_ is being torn down.
  if (flutter_controller_ && !destroying_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      if (flutter_controller_ && flutter_controller_->engine()) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

