#include "flutter_window.h"

#include <optional>
#include <string>

#include <flutter/standard_method_codec.h>

#include <commctrl.h>
#include <windowsx.h>

#include <propkey.h>
#include <propvarutil.h>
#include <shobjidl.h>

#include "app_identity.h"
#include "utils.h"
#include "flutter/generated_plugin_registrant.h"
#include "smtc_channel.h"
#include "wasapi_channel.h"

namespace {

// dwData tag on the WM_COPYDATA that carries a lastwave:// link (see main.cpp).
constexpr ULONG_PTR kDeepLinkCopyData = 0x4C57;

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
  deeplink_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "lastwave/deeplink",
          &flutter::StandardMethodCodec::GetInstance());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  caption_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "lastwave/caption",
          &flutter::StandardMethodCodec::GetInstance());
  caption_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const auto* args = std::get_if<flutter::EncodableList>(call.arguments());
        if (call.method_name() == "setMaxButton" && args && args->size() == 4) {
          auto at = [&](size_t i) {
            const auto& v = (*args)[i];
            if (const auto* d = std::get_if<double>(&v)) return static_cast<LONG>(*d);
            if (const auto* n = std::get_if<int32_t>(&v)) return static_cast<LONG>(*n);
            return 0L;
          };
          max_button_ = RECT{at(0), at(1), at(2), at(3)};
          if (::IsRectEmpty(&max_button_)) SetMaxHover(false);
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
  // The Flutter view is a child window: it must pass the hit test over the
  // button up to this window, or the shell never sees HTMAXBUTTON.
  ::SetWindowSubclass(flutter_controller_->view()->GetNativeWindow(),
                      &FlutterWindow::ViewProc, 1,
                      reinterpret_cast<DWORD_PTR>(this));

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
  deeplink_channel_.reset();
  caption_channel_.reset();
  max_button_ = RECT{0, 0, 0, 0};
  wasapi_channel_.reset();
  if (flutter_controller_) {
    ::RemoveWindowSubclass(flutter_controller_->view()->GetNativeWindow(),
                           &FlutterWindow::ViewProc, 1);
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Media flyout / media-key press marshalled from SMTC's thread-pool
  // callback; forwarded to Dart here, on the platform thread.
  if (message == lastwave::SmtcChannel::kButtonMessage) {
    if (smtc_channel_ && !destroying_) smtc_channel_->OnButtonMessage(wparam);
    return 0;
  }

  // Snap Layouts: ahead of the plugins, which answer WM_NCHITTEST for the
  // frameless resize borders.
  if (!destroying_) {
    switch (message) {
      case WM_NCHITTEST:
        if (InMaxButton(lparam)) return HTMAXBUTTON;
        break;
      case WM_NCMOUSEMOVE:
        SetMaxHover(wparam == HTMAXBUTTON);
        if (wparam == HTMAXBUTTON) {
          TRACKMOUSEEVENT track{sizeof(track), TME_LEAVE | TME_NONCLIENT,
                                hwnd, 0};
          ::TrackMouseEvent(&track);
          return 0;
        }
        break;
      case WM_NCMOUSELEAVE:
        SetMaxHover(false);
        break;
      case WM_NCLBUTTONDOWN:
      case WM_NCLBUTTONDBLCLK:
        if (wparam == HTMAXBUTTON) return 0;
        break;
      case WM_NCLBUTTONUP:
        if (wparam == HTMAXBUTTON) {
          ::ShowWindow(hwnd, ::IsZoomed(hwnd) ? SW_RESTORE : SW_MAXIMIZE);
          return 0;
        }
        break;
    }
  }

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
    case WM_COPYDATA: {
      // A second launch (browser/chat link) hands its lastwave:// URL to
      // this instance. Only that scheme is forwarded to Dart.
      auto* data = reinterpret_cast<COPYDATASTRUCT*>(lparam);
      if (data != nullptr && data->dwData == kDeepLinkCopyData &&
          data->lpData != nullptr && deeplink_channel_ && !destroying_) {
        std::wstring link(static_cast<const wchar_t*>(data->lpData),
                          data->cbData / sizeof(wchar_t));
        while (!link.empty() && link.back() == L'\0') link.pop_back();
        if (link.rfind(L"lastwave://", 0) == 0) {
          deeplink_channel_->InvokeMethod(
              "link", std::make_unique<flutter::EncodableValue>(
                          Utf8FromUtf16(link.c_str())));
        }
        return TRUE;
      }
      break;
    }
    case WM_FONTCHANGE:
      if (flutter_controller_ && flutter_controller_->engine()) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

bool FlutterWindow::InMaxButton(LPARAM screen_point) const {
  if (::IsRectEmpty(&max_button_) || !flutter_controller_) return false;
  POINT pt{GET_X_LPARAM(screen_point), GET_Y_LPARAM(screen_point)};
  ::ScreenToClient(flutter_controller_->view()->GetNativeWindow(), &pt);
  return ::PtInRect(&max_button_, pt) != FALSE;
}

void FlutterWindow::SetMaxHover(bool hover) {
  if (hover == max_hover_ || !caption_channel_) return;
  max_hover_ = hover;
  caption_channel_->InvokeMethod(
      "hover", std::make_unique<flutter::EncodableValue>(hover));
}

LRESULT CALLBACK FlutterWindow::ViewProc(HWND hwnd, UINT message,
                                         WPARAM wparam, LPARAM lparam,
                                         UINT_PTR, DWORD_PTR self) {
  if (message == WM_NCHITTEST &&
      reinterpret_cast<FlutterWindow*>(self)->InMaxButton(lparam)) {
    return HTTRANSPARENT;
  }
  return ::DefSubclassProc(hwnd, message, wparam, lparam);
}
