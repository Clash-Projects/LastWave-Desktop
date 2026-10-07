#include "smtc_channel.h"

#include "app_identity.h"

#include <SystemMediaTransportControlsInterop.h>
#include <hstring.h>
#include <roapi.h>
#include <windows.foundation.h>
#include <windows.media.h>
#include <windows.storage.streams.h>
#include <wrl.h>
#include <wrl/client.h>
#include <wrl/wrappers/corewrappers.h>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <cstdint>
#include <cwchar>
#include <memory>
#include <string>

#pragma comment(lib, "runtimeobject.lib")

namespace lastwave {
namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Wrappers::HStringReference;

constexpr int64_t kMsTo100ns = 10000;

// Status codes sent by Dart (see smtc_service.dart).
constexpr int kStatusStopped = 0;
constexpr int kStatusPlaying = 1;
constexpr int kStatusPaused = 2;
constexpr int kStatusChanging = 3;

std::wstring Utf8ToWide(const std::string& input) {
  if (input.empty()) return {};
  const int len =
      MultiByteToWideChar(CP_UTF8, 0, input.c_str(), -1, nullptr, 0);
  if (len <= 1) return {};
  std::wstring out(static_cast<size_t>(len - 1), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, input.c_str(), -1, out.data(), len);
  return out;
}

HSTRING MakeHString(const std::string& utf8, HSTRING* owned) {
  const std::wstring wide = Utf8ToWide(utf8);
  if (wide.empty()) return nullptr;
  HSTRING h = nullptr;
  if (FAILED(WindowsCreateString(
          wide.c_str(), static_cast<UINT32>(wide.size()), &h))) {
    return nullptr;
  }
  *owned = h;
  return h;
}

std::string StringArg(const EncodableMap& args, const char* key) {
  const auto it = args.find(EncodableValue(key));
  if (it == args.end()) return {};
  if (const auto* s = std::get_if<std::string>(&it->second)) return *s;
  return {};
}

int64_t IntArg(const EncodableMap& args, const char* key) {
  const auto it = args.find(EncodableValue(key));
  if (it == args.end()) return 0;
  if (const auto* v = std::get_if<int32_t>(&it->second)) {
    return static_cast<int64_t>(*v);
  }
  if (const auto* v = std::get_if<int64_t>(&it->second)) return *v;
  if (const auto* v = std::get_if<double>(&it->second)) {
    return static_cast<int64_t>(*v);
  }
  return 0;
}

int IntArg32(const EncodableMap& args, const char* key, int fallback) {
  const auto it = args.find(EncodableValue(key));
  if (it == args.end()) return fallback;
  if (const auto* v = std::get_if<int32_t>(&it->second)) {
    return static_cast<int>(*v);
  }
  if (const auto* v = std::get_if<int64_t>(&it->second)) {
    return static_cast<int>(*v);
  }
  return fallback;
}

double DoubleArg(const EncodableMap& args, const char* key, double fallback) {
  const auto it = args.find(EncodableValue(key));
  if (it == args.end()) return fallback;
  if (const auto* v = std::get_if<double>(&it->second)) return *v;
  if (const auto* v = std::get_if<int32_t>(&it->second)) {
    return static_cast<double>(*v);
  }
  if (const auto* v = std::get_if<int64_t>(&it->second)) {
    return static_cast<double>(*v);
  }
  return fallback;
}

bool BoolArg(const EncodableMap& args, const char* key, bool fallback) {
  const auto it = args.find(EncodableValue(key));
  if (it == args.end()) return fallback;
  if (const auto* v = std::get_if<bool>(&it->second)) return *v;
  return fallback;
}

ABI::Windows::Foundation::TimeSpan MsToSpan(int64_t ms) {
  ABI::Windows::Foundation::TimeSpan span{};
  span.Duration = (ms < 0 ? 0 : ms) * kMsTo100ns;
  return span;
}

}  // namespace

class SmtcChannel::Impl {
 public:
  Impl(flutter::BinaryMessenger* messenger, HWND hwnd) : hwnd_(hwnd) {
    channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
        messenger, "lastwave/smtc",
        &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler(
        [this](const auto& call, auto result) { Handle(call, std::move(result)); });
    InitSystemMedia();
  }

  ~Impl() {
    if (smtc_ && token_.value != 0) {
      smtc_->remove_ButtonPressed(token_);
    }
    smtc_.Reset();
  }

 private:
  // Exact MIDL specialization for the ButtonPressed delegate (declared
  // in the Foundation namespace; the unqualified name is a macro).
  using ButtonPressedHandler = ABI::Windows::Foundation::
      __FITypedEventHandler_2_Windows__CMedia__CSystemMediaTransportControls_Windows__CMedia__CSystemMediaTransportControlsButtonPressedEventArgs_t;

  void InitSystemMedia() {
    if (hwnd_ == nullptr) return;
    // main.cpp already did CoInitializeEx(APARTMENTTHREADED); RoInitialize
    // with the same STA model returns S_FALSE and is a no-op - ignore
    // "already initialized" outcomes, fail open on anything else.
    const HRESULT roInit = RoInitialize(RO_INIT_SINGLETHREADED);
    if (FAILED(roInit) && roInit != RPC_E_CHANGED_MODE) return;

    ComPtr<ISystemMediaTransportControlsInterop> interop;
    HRESULT hr = RoGetActivationFactory(
        HStringReference(
            L"Windows.Media.SystemMediaTransportControls")
            .Get(),
        IID_PPV_ARGS(&interop));
    if (FAILED(hr) || !interop) return;

    ComPtr<ABI::Windows::Media::ISystemMediaTransportControls> smtc;
    hr = interop->GetForWindow(
        hwnd_, IID_PPV_ARGS(&smtc));
    if (FAILED(hr) || !smtc) return;

    // Transport is present but idle until the first Dart update arrives.
    smtc->put_IsEnabled(true);
    smtc->put_IsPlayEnabled(false);
    smtc->put_IsPauseEnabled(false);
    smtc->put_IsStopEnabled(false);
    smtc->put_IsNextEnabled(false);
    smtc->put_IsPreviousEnabled(false);
    smtc->put_PlaybackStatus(
        ABI::Windows::Media::MediaPlaybackStatus_Stopped);

    auto handler = Callback<ButtonPressedHandler>(
        [this](ABI::Windows::Media::ISystemMediaTransportControls*,
               ABI::Windows::Media::
                   ISystemMediaTransportControlsButtonPressedEventArgs* args)
            -> HRESULT {
          if (args == nullptr) return S_OK;
          ABI::Windows::Media::SystemMediaTransportControlsButton button =
              ABI::Windows::Media::
                  SystemMediaTransportControlsButton_Play;
          if (FAILED(args->get_Button(&button))) return S_OK;
          const char* name = nullptr;
          switch (button) {
            case ABI::Windows::Media::SystemMediaTransportControlsButton_Play:
              name = "play";
              break;
            case ABI::Windows::Media::SystemMediaTransportControlsButton_Pause:
              name = "pause";
              break;
            case ABI::Windows::Media::SystemMediaTransportControlsButton_Stop:
              name = "stop";
              break;
            case ABI::Windows::Media::SystemMediaTransportControlsButton_Next:
              name = "next";
              break;
            case ABI::Windows::Media::
                SystemMediaTransportControlsButton_Previous:
              name = "previous";
              break;
            default:
              break;
          }
          if (name != nullptr && channel_) {
            channel_->InvokeMethod(
                "onButton",
                std::make_unique<EncodableValue>(std::string(name)));
          }
          return S_OK;
        });
    if (!handler) return;
    EventRegistrationToken token{};
    hr = smtc->add_ButtonPressed(handler.Get(), &token);
    if (FAILED(hr)) return;
    token_ = token;
    smtc_ = smtc;
  }

  void Handle(const flutter::MethodCall<EncodableValue>& call,
              std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    if (call.method_name() != "update") {
      result->NotImplemented();
      return;
    }
    const auto* args = std::get_if<EncodableMap>(call.arguments());
    if (args == nullptr) {
      result->Error("smtc", "missing args");
      return;
    }
    ApplyUpdate(*args);
    result->Success();
  }

  void ApplyUpdate(const EncodableMap& args) {
    if (!smtc_) return;
    const std::string title = StringArg(args, "title");
    const std::string artist = StringArg(args, "artist");
    const std::string album = StringArg(args, "album");
    const std::string artUrl = StringArg(args, "artUrl");
    const int status = IntArg32(args, "status", kStatusStopped);
    const int64_t positionMs = IntArg(args, "positionMs");
    const int64_t durationMs = IntArg(args, "durationMs");
    const double rate = DoubleArg(args, "rate", 1.0);
    const bool hasTrack = BoolArg(args, "hasTrack", false);
    const bool canNext = BoolArg(args, "canNext", false);
    const bool canPrev = BoolArg(args, "canPrev", false);

    ComPtr<ABI::Windows::Media::ISystemMediaTransportControlsDisplayUpdater>
        updater;
    if (FAILED(smtc_->get_DisplayUpdater(&updater)) || !updater) return;
    updater->put_Type(ABI::Windows::Media::MediaPlaybackType_Music);
    // Source label for the flyout/lock screen. Must equal the process
    // AppUserModelID (main.cpp) + window ID (flutter_window.cpp) + the
    // Start Menu shortcut's AppUserModelID (installer.iss). The shell
    // looks up display name/icon via that shortcut; with no matching
    // shortcut it falls back to "Unknown app" with no logo.
    // Uses an owned HSTRING (not HStringReference) so the ID stays valid
    // for the duration of the put_ call.
    {
      HSTRING appId = nullptr;
      if (SUCCEEDED(WindowsCreateString(
              kLastWaveAppUserModelId,
              static_cast<UINT32>(wcslen(kLastWaveAppUserModelId)),
              &appId))) {
        updater->put_AppMediaId(appId);
        WindowsDeleteString(appId);
      }
    }

    ComPtr<ABI::Windows::Media::IMusicDisplayProperties> music;
    if (SUCCEEDED(updater->get_MusicProperties(&music)) && music) {
      HSTRING owned = nullptr;
      if (!title.empty() && MakeHString(title, &owned) != nullptr) {
        music->put_Title(owned);
        WindowsDeleteString(owned);
      }
      owned = nullptr;
      if (!artist.empty() && MakeHString(artist, &owned) != nullptr) {
        music->put_Artist(owned);
        WindowsDeleteString(owned);
      }
      owned = nullptr;
      // AlbumTitle lives on the versioned IMusicDisplayProperties2.
      ComPtr<ABI::Windows::Media::IMusicDisplayProperties2> music2;
      if (!album.empty() && SUCCEEDED(music.As(&music2)) && music2 &&
          MakeHString(album, &owned) != nullptr) {
        music2->put_AlbumTitle(owned);
        WindowsDeleteString(owned);
      }
    }

    // Thumbnails resolve lazily inside the shell from the URL - refresh
    // only when the URL actually changed (Dart already dedupes; this is
    // the backstop for repeated position/metadata pushes).
    if (artUrl != lastArtUrl_) {
      lastArtUrl_ = artUrl;
      if (!artUrl.empty()) {
        SetThumbnail(updater.Get(), artUrl);
      } else {
        updater->put_Thumbnail(nullptr);
      }
    }
    updater->Update();

    const auto playbackStatus = status == kStatusPlaying
        ? ABI::Windows::Media::MediaPlaybackStatus_Playing
        : status == kStatusPaused
        ? ABI::Windows::Media::MediaPlaybackStatus_Paused
        : status == kStatusChanging
        ? ABI::Windows::Media::MediaPlaybackStatus_Changing
        : ABI::Windows::Media::MediaPlaybackStatus_Stopped;
    smtc_->put_PlaybackStatus(playbackStatus);
    // Rate + timeline live on the versioned ISystemMediaTransportControls2.
    ComPtr<ABI::Windows::Media::ISystemMediaTransportControls2> smtc2;
    if (SUCCEEDED(smtc_.As(&smtc2)) && smtc2) {
      smtc2->put_PlaybackRate(hasTrack ? rate : 0.0);
    }
    smtc_->put_IsPlayEnabled(hasTrack);
    smtc_->put_IsPauseEnabled(hasTrack);
    smtc_->put_IsStopEnabled(hasTrack);
    smtc_->put_IsNextEnabled(canNext);
    smtc_->put_IsPreviousEnabled(canPrev);

    if (durationMs > 0) {
      ComPtr<ABI::Windows::Media::ISystemMediaTransportControls2> smtcTl;
      if (FAILED(smtc_.As(&smtcTl)) || !smtcTl) return;
      ComPtr<IInspectable> inspectable;
      HRESULT hr = RoActivateInstance(
          HStringReference(
              L"Windows.Media.SystemMediaTransportControlsTimelineProperties")
              .Get(),
          &inspectable);
      ComPtr<ABI::Windows::Media::
                 ISystemMediaTransportControlsTimelineProperties>
          timeline;
      if (SUCCEEDED(hr) && inspectable) {
        hr = inspectable.As(&timeline);
      }
      if (SUCCEEDED(hr) && timeline) {
        const int64_t clamped =
            positionMs < 0 ? 0 : (positionMs > durationMs ? durationMs : positionMs);
        timeline->put_StartTime(MsToSpan(0));
        timeline->put_MinSeekTime(MsToSpan(0));
        timeline->put_EndTime(MsToSpan(durationMs));
        timeline->put_MaxSeekTime(MsToSpan(durationMs));
        timeline->put_Position(MsToSpan(clamped));
        smtcTl->UpdateTimelineProperties(timeline.Get());
      }
    }
  }

  void SetThumbnail(
      ABI::Windows::Media::ISystemMediaTransportControlsDisplayUpdater* updater,
      const std::string& url) {
    HSTRING owned = nullptr;
    const HSTRING hUrl = MakeHString(url, &owned);
    if (hUrl == nullptr) return;

    ComPtr<ABI::Windows::Foundation::IUriRuntimeClassFactory> uriFactory;
    HRESULT hr = RoGetActivationFactory(
        HStringReference(L"Windows.Foundation.Uri").Get(),
        IID_PPV_ARGS(&uriFactory));
    ComPtr<ABI::Windows::Foundation::IUriRuntimeClass> uri;
    if (SUCCEEDED(hr) && uriFactory) {
      hr = uriFactory->CreateUri(hUrl, &uri);
    }
    WindowsDeleteString(owned);
    if (FAILED(hr) || !uri) return;

    ComPtr<ABI::Windows::Storage::Streams::
               IRandomAccessStreamReferenceStatics>
        refStatics;
    hr = RoGetActivationFactory(
        HStringReference(
            L"Windows.Storage.Streams.RandomAccessStreamReference")
            .Get(),
        IID_PPV_ARGS(&refStatics));
    ComPtr<ABI::Windows::Storage::Streams::IRandomAccessStreamReference> ref;
    if (SUCCEEDED(hr) && refStatics) {
      hr = refStatics->CreateFromUri(uri.Get(), &ref);
    }
    if (SUCCEEDED(hr) && ref) {
      updater->put_Thumbnail(ref.Get());
    }
  }

  HWND hwnd_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel_;
  ComPtr<ABI::Windows::Media::ISystemMediaTransportControls> smtc_;
  EventRegistrationToken token_{};
  std::string lastArtUrl_;
};

SmtcChannel::SmtcChannel(flutter::BinaryMessenger* messenger, HWND hwnd)
    : impl_(std::make_unique<Impl>(messenger, hwnd)) {}

SmtcChannel::~SmtcChannel() = default;

}  // namespace lastwave

