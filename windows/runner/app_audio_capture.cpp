// winsock2 must precede windows.h.
#include <winsock2.h>
#include <ws2tcpip.h>

#include "app_audio_capture.h"

#include <audioclient.h>
#include <audioclientactivationparams.h>
#include <mmdeviceapi.h>
#include <windows.h>
#include <wrl/client.h>
#include <wrl/implements.h>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <atomic>
#include <future>
#include <string>
#include <thread>

namespace lastwave {
namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;

constexpr int kSampleRate = 48000;
constexpr int kChannels = 2;
constexpr int kBytesPerFrame = kChannels * 2;  // s16

class ActivationHandler
    : public Microsoft::WRL::RuntimeClass<
          Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
          Microsoft::WRL::FtmBase, IActivateAudioInterfaceCompletionHandler> {
 public:
  ActivationHandler() { done_ = ::CreateEventW(nullptr, TRUE, FALSE, nullptr); }
  ~ActivationHandler() override { ::CloseHandle(done_); }
  STDMETHOD(ActivateCompleted)(IActivateAudioInterfaceAsyncOperation*) override {
    ::SetEvent(done_);
    return S_OK;
  }
  HANDLE done() const { return done_; }

 private:
  HANDLE done_;
};

std::string Hr(const char* what, HRESULT hr) {
  char buf[96];
  snprintf(buf, sizeof(buf), "%s failed (0x%08lx)", what, static_cast<unsigned long>(hr));
  return buf;
}

// Activates a loopback client for this process tree (includes WebView2
// children, which never render audio themselves).
HRESULT ActivateProcessLoopback(ComPtr<IAudioClient>* out, std::string* error) {
  AUDIOCLIENT_ACTIVATION_PARAMS params{};
  params.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
  params.ProcessLoopbackParams.TargetProcessId = ::GetCurrentProcessId();
  params.ProcessLoopbackParams.ProcessLoopbackMode =
      PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE;
  PROPVARIANT pv{};
  pv.vt = VT_BLOB;
  pv.blob.cbSize = sizeof(params);
  pv.blob.pBlobData = reinterpret_cast<BYTE*>(&params);

  auto handler = Microsoft::WRL::Make<ActivationHandler>();
  ComPtr<IActivateAudioInterfaceAsyncOperation> op;
  HRESULT hr = ::ActivateAudioInterfaceAsync(
      VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK, __uuidof(IAudioClient), &pv,
      handler.Get(), &op);
  if (FAILED(hr)) {
    // Process loopback needs Windows 10 2004 (build 19041) or newer.
    *error = Hr("ActivateAudioInterfaceAsync", hr);
    return hr;
  }
  if (::WaitForSingleObject(handler->done(), 5000) != WAIT_OBJECT_0) {
    *error = "audio activation timed out";
    return E_FAIL;
  }
  HRESULT activate_hr = E_FAIL;
  ComPtr<IUnknown> unk;
  hr = op->GetActivateResult(&activate_hr, &unk);
  if (FAILED(hr) || FAILED(activate_hr)) {
    *error = Hr("GetActivateResult", FAILED(hr) ? hr : activate_hr);
    return FAILED(hr) ? hr : activate_hr;
  }
  return unk.As(out);
}

}  // namespace

class AppAudioCapture::Impl {
 public:
  explicit Impl(flutter::BinaryMessenger* messenger) {
    WSADATA wsa;
    wsa_ok_ = ::WSAStartup(MAKEWORD(2, 2), &wsa) == 0;
    channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
        messenger, "lastwave/app_audio",
        &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler([this](const auto& call, auto result) {
      if (call.method_name() == "stop") {
        Stop();
        result->Success();
        return;
      }
      if (call.method_name() != "start") {
        result->NotImplemented();
        return;
      }
      const auto* args = std::get_if<EncodableMap>(call.arguments());
      int port = 0;
      std::string token;
      if (args) {
        auto p = args->find(EncodableValue("port"));
        auto t = args->find(EncodableValue("token"));
        if (p != args->end()) port = std::get<int32_t>(p->second);
        if (t != args->end()) token = std::get<std::string>(t->second);
      }
      std::string error = Start(port, token);
      if (error.empty()) {
        result->Success(EncodableValue(true));
      } else {
        result->Error("app_audio", error);
      }
    });
  }

  ~Impl() {
    Stop();
    if (wsa_ok_) ::WSACleanup();
  }

 private:
  std::string Start(int port, const std::string& token) {
    Stop();
    if (!wsa_ok_) return "winsock unavailable";
    if (port <= 0 || port > 65535) return "bad port";
    running_ = true;
    std::promise<std::string> ready;
    auto ready_future = ready.get_future();
    worker_ = std::thread(
        [this, port, token, p = std::move(ready)]() mutable {
          Run(port, token, &p);
        });
    std::string error = ready_future.get();
    if (!error.empty()) Stop();
    return error;
  }

  void Stop() {
    running_ = false;
    if (worker_.joinable()) worker_.join();
  }

  // Capture thread: activate, connect, then pump packets until stopped or
  // Dart closes the socket. [ready] is fulfilled exactly once.
  void Run(int port, const std::string& token, std::promise<std::string>* ready) {
    ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    std::string error;
    SOCKET sock = INVALID_SOCKET;
    HANDLE event = ::CreateEventW(nullptr, FALSE, FALSE, nullptr);
    ComPtr<IAudioClient> client;
    ComPtr<IAudioCaptureClient> capture;
    do {
      if (FAILED(ActivateProcessLoopback(&client, &error))) break;
      WAVEFORMATEX fmt{};
      fmt.wFormatTag = WAVE_FORMAT_PCM;
      fmt.nChannels = kChannels;
      fmt.nSamplesPerSec = kSampleRate;
      fmt.wBitsPerSample = 16;
      fmt.nBlockAlign = kBytesPerFrame;
      fmt.nAvgBytesPerSec = kSampleRate * kBytesPerFrame;
      HRESULT hr = client->Initialize(
          AUDCLNT_SHAREMODE_SHARED,
          AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK |
              AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM,
          200000 /* 20 ms */, 0, &fmt, nullptr);
      if (FAILED(hr)) { error = Hr("IAudioClient::Initialize", hr); break; }
      if (FAILED(hr = client->SetEventHandle(event))) { error = Hr("SetEventHandle", hr); break; }
      if (FAILED(hr = client->GetService(IID_PPV_ARGS(&capture)))) { error = Hr("GetService", hr); break; }

      sock = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
      sockaddr_in addr{};
      addr.sin_family = AF_INET;
      addr.sin_port = htons(static_cast<u_short>(port));
      addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
      if (sock == INVALID_SOCKET ||
          ::connect(sock, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
        error = "could not connect to the app's PCM port";
        break;
      }
      BOOL nodelay = TRUE;
      ::setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char*>(&nodelay), sizeof(nodelay));
      // Token first, so Dart only accepts our own stream on its port.
      std::string hello = token + "\n";
      if (::send(sock, hello.data(), static_cast<int>(hello.size()), 0) <= 0) {
        error = "PCM port closed";
        break;
      }
      if (FAILED(hr = client->Start())) { error = Hr("IAudioClient::Start", hr); break; }
    } while (false);

    ready->set_value(error);
    if (error.empty()) Pump(client.Get(), capture.Get(), sock, event);

    if (client) client->Stop();
    if (sock != INVALID_SOCKET) ::closesocket(sock);
    ::CloseHandle(event);
    ::CoUninitialize();
  }

  void Pump(IAudioClient*, IAudioCaptureClient* capture, SOCKET sock, HANDLE event) {
    while (running_) {
      // No packets arrive while the app is silent; the timeout keeps Stop() responsive.
      ::WaitForSingleObject(event, 100);
      UINT32 packet = 0;
      while (running_ && SUCCEEDED(capture->GetNextPacketSize(&packet)) && packet > 0) {
        BYTE* data = nullptr;
        UINT32 frames = 0;
        DWORD flags = 0;
        if (FAILED(capture->GetBuffer(&data, &frames, &flags, nullptr, nullptr))) return;
        const int bytes = static_cast<int>(frames) * kBytesPerFrame;
        if (flags & AUDCLNT_BUFFERFLAGS_SILENT) {
          silence_.assign(bytes, 0);
          data = reinterpret_cast<BYTE*>(silence_.data());
        }
        bool ok = true;
        for (int sent = 0; ok && sent < bytes;) {
          int n = ::send(sock, reinterpret_cast<const char*>(data) + sent, bytes - sent, 0);
          ok = n > 0;
          sent += n;
        }
        capture->ReleaseBuffer(frames);
        if (!ok) return;  // Dart closed the port: browser guests stopped.
      }
    }
  }

  bool wsa_ok_ = false;
  std::atomic<bool> running_{false};
  std::thread worker_;
  std::string silence_;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel_;
};

AppAudioCapture::AppAudioCapture(flutter::BinaryMessenger* messenger)
    : impl_(std::make_unique<Impl>(messenger)) {}

AppAudioCapture::~AppAudioCapture() = default;

}  // namespace lastwave
