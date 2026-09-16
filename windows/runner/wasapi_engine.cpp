#include "wasapi_engine.h"

#include <windows.h>
#include <initguid.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <endpointvolume.h>
#include <functiondiscoverykeys_devpkey.h>
#include <mmreg.h>
#include <propidl.h>

#include <algorithm>
#include <cstdio>
#include <mutex>
#include <string>
#include <vector>

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "uuid.lib")

namespace lastwave {
namespace wasapi {
namespace {

constexpr int kRates[] = {44100,  48000,  88200,  96000,
                          176400, 192000, 352800, 384000};
constexpr int kDepths[] = {16, 24, 32};
constexpr int kChannels[] = {2};

std::string WideToUtf8(const wchar_t* input) {
  if (!input) return {};
  const int len = WideCharToMultiByte(CP_UTF8, 0, input, -1, nullptr, 0,
                                      nullptr, nullptr);
  if (len <= 1) return {};
  std::string out(static_cast<size_t>(len - 1), '\0');
  WideCharToMultiByte(CP_UTF8, 0, input, -1, out.data(), len, nullptr,
                      nullptr);
  return out;
}

std::wstring Utf8ToWide(const std::string& input) {
  if (input.empty()) return {};
  const int len = MultiByteToWideChar(CP_UTF8, 0, input.c_str(), -1, nullptr, 0);
  if (len <= 1) return {};
  std::wstring out(static_cast<size_t>(len - 1), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, input.c_str(), -1, out.data(), len);
  return out;
}

std::string HresultMessage(HRESULT hr) {
  char buf[32];
  snprintf(buf, sizeof(buf), "0x%08X", static_cast<unsigned>(hr));
  return buf;
}

HRESULT CreateEnumerator(IMMDeviceEnumerator** enumerator) {
  return CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                          CLSCTX_ALL, IID_PPV_ARGS(enumerator));
}

HRESULT DeviceById(const std::string& id, IMMDevice** device) {
  IMMDeviceEnumerator* raw = nullptr;
  HRESULT hr = CreateEnumerator(&raw);
  if (FAILED(hr) || !raw) return hr;
  if (id.empty()) {
    hr = raw->GetDefaultAudioEndpoint(eRender, eConsole, device);
  } else {
    const std::wstring wid = Utf8ToWide(id);
    hr = raw->GetDevice(wid.c_str(), device);
  }
  raw->Release();
  return hr;
}

std::string PropString(IPropertyStore* store, const PROPERTYKEY& key) {
  PROPVARIANT var;
  PropVariantInit(&var);
  std::string result;
  if (SUCCEEDED(store->GetValue(key, &var)) && var.vt == VT_LPWSTR &&
      var.pwszVal) {
    result = WideToUtf8(var.pwszVal);
  }
  PropVariantClear(&var);
  return result;
}

bool FillIdentity(IMMDevice* device, DeviceInfo* info) {
  LPWSTR id = nullptr;
  if (FAILED(device->GetId(&id)) || !id) return false;
  info->id = WideToUtf8(id);
  CoTaskMemFree(id);

  IPropertyStore* store = nullptr;
  if (SUCCEEDED(device->OpenPropertyStore(STGM_READ, &store)) && store) {
    info->name = PropString(store, PKEY_Device_FriendlyName);
    if (info->name.empty()) {
      info->name = PropString(store, PKEY_Device_DeviceDesc);
    }
    info->manufacturer = PropString(store, PKEY_DeviceInterface_FriendlyName);
    info->enumerator = PropString(store, PKEY_Device_EnumeratorName);
    store->Release();
  }
  if (info->name.empty()) info->name = info->id;
  return true;
}

void FillHardwareVolume(IMMDevice* device, DeviceInfo* info) {
  IAudioEndpointVolume* volume = nullptr;
  HRESULT hr = device->Activate(__uuidof(IAudioEndpointVolume), CLSCTX_ALL,
                                nullptr, reinterpret_cast<void**>(&volume));
  if (FAILED(hr) || !volume) {
    info->hardware_volume = false;
    return;
  }
  DWORD mask = 0;
  if (SUCCEEDED(volume->QueryHardwareSupport(&mask))) {
    info->hardware_volume =
        (mask & ENDPOINT_HARDWARE_SUPPORT_VOLUME) != 0;
  } else {
    // Some USB DACs expose the volume interface without the hardware bit.
    float scalar = 0;
    info->hardware_volume = SUCCEEDED(volume->GetMasterVolumeLevelScalar(&scalar));
  }
  volume->Release();
}

WAVEFORMATEXTENSIBLE MakePcm(int rate, int bit_depth, int channels,
                             bool packed24) {
  WAVEFORMATEXTENSIBLE fmt{};
  fmt.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
  fmt.Format.nChannels = static_cast<WORD>(channels);
  fmt.Format.nSamplesPerSec = static_cast<DWORD>(rate);
  const int container = (bit_depth == 24 && packed24) ? 24 : (bit_depth == 24 ? 32 : bit_depth);
  fmt.Format.wBitsPerSample = static_cast<WORD>(container);
  fmt.Format.nBlockAlign =
      static_cast<WORD>(channels * (container / 8));
  fmt.Format.nAvgBytesPerSec =
      fmt.Format.nSamplesPerSec * fmt.Format.nBlockAlign;
  fmt.Format.cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
  fmt.Samples.wValidBitsPerSample = static_cast<WORD>(bit_depth);
  fmt.dwChannelMask =
      channels >= 2 ? (SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT) : SPEAKER_FRONT_CENTER;
  fmt.SubFormat = KSDATAFORMAT_SUBTYPE_PCM;
  return fmt;
}

WAVEFORMATEXTENSIBLE MakeFloat32(int rate, int channels) {
  auto fmt = MakePcm(rate, 32, channels, false);
  fmt.SubFormat = KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;
  fmt.Samples.wValidBitsPerSample = 32;
  return fmt;
}

bool ExclusiveSupports(IAudioClient* client, WAVEFORMATEX* format) {
  WAVEFORMATEX* closest = nullptr;
  const HRESULT hr =
      client->IsFormatSupported(AUDCLNT_SHAREMODE_EXCLUSIVE, format, &closest);
  if (closest) CoTaskMemFree(closest);
  return hr == S_OK;
}

void ProbeFormats(IMMDevice* device, DeviceInfo* info) {
  IAudioClient* client = nullptr;
  HRESULT hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                                reinterpret_cast<void**>(&client));
  if (FAILED(hr) || !client) {
    info->exclusive_supported = false;
    return;
  }

  std::vector<PcmFormat> found;
  auto add = [&](int rate, int depth, int ch) {
    for (const auto& f : found) {
      if (f.sample_rate_hz == rate && f.bit_depth == depth &&
          f.channels == ch) {
        return;
      }
    }
    found.push_back({rate, depth, ch});
  };

  bool any = false;
  for (int ch : kChannels) {
    for (int depth : kDepths) {
      for (int rate : kRates) {
        if (depth == 24) {
          auto packed = MakePcm(rate, 24, ch, true);
          auto padded = MakePcm(rate, 24, ch, false);
          if (ExclusiveSupports(client, &packed.Format) ||
              ExclusiveSupports(client, &padded.Format)) {
            add(rate, 24, ch);
            any = true;
          }
        } else if (depth == 32) {
          auto pcm = MakePcm(rate, 32, ch, false);
          auto flt = MakeFloat32(rate, ch);
          if (ExclusiveSupports(client, &pcm.Format) ||
              ExclusiveSupports(client, &flt.Format)) {
            add(rate, 32, ch);
            any = true;
          }
        } else {
          auto pcm = MakePcm(rate, depth, ch, false);
          if (ExclusiveSupports(client, &pcm.Format)) {
            add(rate, depth, ch);
            any = true;
          }
        }
      }
    }
  }
  client->Release();
  info->exclusive_supported = any;
  info->formats = std::move(found);
}

HRESULT DefaultId(std::string* id) {
  IMMDeviceEnumerator* enumerator = nullptr;
  HRESULT hr = CreateEnumerator(&enumerator);
  if (FAILED(hr) || !enumerator) return hr;
  IMMDevice* device = nullptr;
  hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
  enumerator->Release();
  if (FAILED(hr) || !device) return hr;
  LPWSTR raw = nullptr;
  hr = device->GetId(&raw);
  device->Release();
  if (FAILED(hr) || !raw) return hr;
  *id = WideToUtf8(raw);
  CoTaskMemFree(raw);
  return S_OK;
}

class NotificationClient final : public IMMNotificationClient {
 public:
  explicit NotificationClient(DeviceListener* listener) : listener_(listener) {}

  ULONG STDMETHODCALLTYPE AddRef() override {
    return InterlockedIncrement(&ref_);
  }
  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG v = InterlockedDecrement(&ref_);
    if (v == 0) delete this;
    return v;
  }
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) override {
    if (!ppv) return E_POINTER;
    if (riid == IID_IUnknown || riid == __uuidof(IMMNotificationClient)) {
      *ppv = static_cast<IMMNotificationClient*>(this);
      AddRef();
      return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
  }

  HRESULT STDMETHODCALLTYPE OnDeviceStateChanged(LPCWSTR id,
                                                 DWORD) override {
    Notify("state", id);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE OnDeviceAdded(LPCWSTR id) override {
    Notify("added", id);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE OnDeviceRemoved(LPCWSTR id) override {
    Notify("removed", id);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE OnDefaultDeviceChanged(EDataFlow flow, ERole,
                                                   LPCWSTR id) override {
    if (flow == eRender) Notify("default", id);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE OnPropertyValueChanged(LPCWSTR id,
                                                   const PROPERTYKEY) override {
    Notify("property", id);
    return S_OK;
  }

 private:
  void Notify(const char* reason, LPCWSTR id) {
    if (!listener_) return;
    listener_->OnDevicesChanged(reason, WideToUtf8(id));
  }

  DeviceListener* listener_ = nullptr;
  LONG ref_ = 1;
};

std::mutex g_watch_mu;
IMMDeviceEnumerator* g_watch_enumerator = nullptr;
NotificationClient* g_watch_client = nullptr;

void StopWatchingLocked() {
  if (g_watch_enumerator && g_watch_client) {
    g_watch_enumerator->UnregisterEndpointNotificationCallback(g_watch_client);
  }
  if (g_watch_client) {
    g_watch_client->Release();
    g_watch_client = nullptr;
  }
  if (g_watch_enumerator) {
    g_watch_enumerator->Release();
    g_watch_enumerator = nullptr;
  }
}

}  // namespace

bool EnumerateRenderDevices(std::vector<DeviceInfo>* out, std::string* error) {
  out->clear();
  IMMDeviceEnumerator* enumerator = nullptr;
  HRESULT hr = CreateEnumerator(&enumerator);
  if (FAILED(hr) || !enumerator) {
    if (error) *error = "MMDeviceEnumerator failed " + HresultMessage(hr);
    return false;
  }
  IMMDeviceCollection* collection = nullptr;
  hr = enumerator->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, &collection);
  std::string default_id;
  DefaultId(&default_id);
  if (FAILED(hr) || !collection) {
    enumerator->Release();
    if (error) *error = "EnumAudioEndpoints failed " + HresultMessage(hr);
    return false;
  }
  UINT count = 0;
  collection->GetCount(&count);
  for (UINT i = 0; i < count; ++i) {
    IMMDevice* device = nullptr;
    if (FAILED(collection->Item(i, &device)) || !device) continue;
    DeviceInfo info;
    if (FillIdentity(device, &info)) {
      info.is_default = !default_id.empty() && info.id == default_id;
      FillHardwareVolume(device, &info);
      ProbeFormats(device, &info);
      out->push_back(std::move(info));
    }
    device->Release();
  }
  collection->Release();
  enumerator->Release();
  return true;
}

bool ProbeDevice(const std::string& device_id, DeviceInfo* out,
                 std::string* error) {
  IMMDevice* device = nullptr;
  HRESULT hr = DeviceById(device_id, &device);
  if (FAILED(hr) || !device) {
    if (error) *error = "GetDevice failed " + HresultMessage(hr);
    return false;
  }
  DeviceInfo info;
  const bool ok = FillIdentity(device, &info);
  if (ok) {
    std::string default_id;
    DefaultId(&default_id);
    info.is_default = !default_id.empty() && info.id == default_id;
    FillHardwareVolume(device, &info);
    ProbeFormats(device, &info);
    *out = std::move(info);
  }
  device->Release();
  if (!ok && error) *error = "Device identity unavailable";
  return ok;
}

bool SetHardwareVolume(const std::string& device_id, float scalar,
                       std::string* error) {
  IMMDevice* device = nullptr;
  HRESULT hr = DeviceById(device_id, &device);
  if (FAILED(hr) || !device) {
    if (error) *error = "GetDevice failed " + HresultMessage(hr);
    return false;
  }
  IAudioEndpointVolume* volume = nullptr;
  hr = device->Activate(__uuidof(IAudioEndpointVolume), CLSCTX_ALL, nullptr,
                        reinterpret_cast<void**>(&volume));
  device->Release();
  if (FAILED(hr) || !volume) {
    if (error) *error = "IAudioEndpointVolume unavailable " + HresultMessage(hr);
    return false;
  }
  const float clamped = std::clamp(scalar, 0.0f, 1.0f);
  hr = volume->SetMasterVolumeLevelScalar(clamped, nullptr);
  volume->Release();
  if (FAILED(hr)) {
    if (error) *error = "SetMasterVolumeLevelScalar failed " + HresultMessage(hr);
    return false;
  }
  return true;
}

bool GetHardwareVolume(const std::string& device_id, float* scalar,
                       std::string* error) {
  IMMDevice* device = nullptr;
  HRESULT hr = DeviceById(device_id, &device);
  if (FAILED(hr) || !device) {
    if (error) *error = "GetDevice failed " + HresultMessage(hr);
    return false;
  }
  IAudioEndpointVolume* volume = nullptr;
  hr = device->Activate(__uuidof(IAudioEndpointVolume), CLSCTX_ALL, nullptr,
                        reinterpret_cast<void**>(&volume));
  device->Release();
  if (FAILED(hr) || !volume) {
    if (error) *error = "IAudioEndpointVolume unavailable " + HresultMessage(hr);
    return false;
  }
  hr = volume->GetMasterVolumeLevelScalar(scalar);
  volume->Release();
  if (FAILED(hr)) {
    if (error) *error = "GetMasterVolumeLevelScalar failed " + HresultMessage(hr);
    return false;
  }
  return true;
}

std::string DefaultDeviceId() {
  std::string id;
  DefaultId(&id);
  return id;
}

bool StartWatching(DeviceListener* listener, std::string* error) {
  std::lock_guard<std::mutex> lock(g_watch_mu);
  StopWatchingLocked();
  IMMDeviceEnumerator* enumerator = nullptr;
  HRESULT hr = CreateEnumerator(&enumerator);
  if (FAILED(hr) || !enumerator) {
    if (error) *error = "MMDeviceEnumerator failed " + HresultMessage(hr);
    return false;
  }
  auto* client = new NotificationClient(listener);
  hr = enumerator->RegisterEndpointNotificationCallback(client);
  if (FAILED(hr)) {
    client->Release();
    enumerator->Release();
    if (error) *error = "RegisterEndpointNotificationCallback failed " +
                        HresultMessage(hr);
    return false;
  }
  g_watch_enumerator = enumerator;
  g_watch_client = client;
  return true;
}

void StopWatching() {
  std::lock_guard<std::mutex> lock(g_watch_mu);
  StopWatchingLocked();
}

}  // namespace wasapi
}  // namespace lastwave
