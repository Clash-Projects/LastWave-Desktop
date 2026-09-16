#include "wasapi_channel.h"

#include "wasapi_engine.h"

#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>
#include <vector>

namespace lastwave {
namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

EncodableMap DeviceToMap(const wasapi::DeviceInfo& d) {
  EncodableList formats;
  for (const auto& f : d.formats) {
    formats.push_back(EncodableValue(EncodableMap{
        {EncodableValue("sampleRateHz"), EncodableValue(f.sample_rate_hz)},
        {EncodableValue("bitDepth"), EncodableValue(f.bit_depth)},
        {EncodableValue("channels"), EncodableValue(f.channels)},
    }));
  }
  return EncodableMap{
      {EncodableValue("id"), EncodableValue(d.id)},
      {EncodableValue("name"), EncodableValue(d.name)},
      {EncodableValue("manufacturer"), EncodableValue(d.manufacturer)},
      {EncodableValue("enumerator"), EncodableValue(d.enumerator)},
      {EncodableValue("isDefault"), EncodableValue(d.is_default)},
      {EncodableValue("exclusiveSupported"),
       EncodableValue(d.exclusive_supported)},
      {EncodableValue("hardwareVolume"), EncodableValue(d.hardware_volume)},
      {EncodableValue("formats"), EncodableValue(formats)},
  };
}

}  // namespace

class WasapiChannel::Impl : public wasapi::DeviceListener {
 public:
  explicit Impl(flutter::BinaryMessenger* messenger) {
    method_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
        messenger, "lastwave/wasapi",
        &flutter::StandardMethodCodec::GetInstance());
    method_->SetMethodCallHandler(
        [this](const auto& call, auto result) { Handle(call, std::move(result)); });

    events_ = std::make_unique<flutter::EventChannel<EncodableValue>>(
        messenger, "lastwave/wasapi/events",
        &flutter::StandardMethodCodec::GetInstance());
    events_->SetStreamHandler(
        std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
            [this](const EncodableValue*,
                   std::unique_ptr<flutter::EventSink<EncodableValue>>&& sink)
                -> std::unique_ptr<
                    flutter::StreamHandlerError<EncodableValue>> {
              sink_ = std::move(sink);
              std::string error;
              wasapi::StartWatching(this, &error);
              return nullptr;
            },
            [this](const EncodableValue*)
                -> std::unique_ptr<
                    flutter::StreamHandlerError<EncodableValue>> {
              wasapi::StopWatching();
              sink_.reset();
              return nullptr;
            }));
  }

  ~Impl() override {
    wasapi::StopWatching();
    sink_.reset();
  }

  void OnDevicesChanged(const std::string& reason,
                        const std::string& device_id) override {
    if (!sink_) return;
    sink_->Success(EncodableValue(EncodableMap{
        {EncodableValue("reason"), EncodableValue(reason)},
        {EncodableValue("id"), EncodableValue(device_id)},
    }));
  }

 private:
  void Handle(const flutter::MethodCall<EncodableValue>& call,
              std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    const auto& method = call.method_name();
    if (method == "enumerateDevices") {
      std::vector<wasapi::DeviceInfo> devices;
      std::string error;
      if (!wasapi::EnumerateRenderDevices(&devices, &error)) {
        result->Error("wasapi", error);
        return;
      }
      EncodableList list;
      for (const auto& d : devices) {
        list.push_back(EncodableValue(DeviceToMap(d)));
      }
      result->Success(EncodableValue(list));
      return;
    }
    if (method == "probeDevice") {
      const auto* args = std::get_if<EncodableMap>(call.arguments());
      std::string id;
      if (args) {
        const auto it = args->find(EncodableValue("id"));
        if (it != args->end()) {
          if (const auto* s = std::get_if<std::string>(&it->second)) id = *s;
        }
      }
      wasapi::DeviceInfo info;
      std::string error;
      if (!wasapi::ProbeDevice(id, &info, &error)) {
        result->Error("wasapi", error);
        return;
      }
      result->Success(EncodableValue(DeviceToMap(info)));
      return;
    }
    if (method == "setHardwareVolume") {
      const auto* args = std::get_if<EncodableMap>(call.arguments());
      std::string id;
      double scalar = 1.0;
      if (args) {
        const auto id_it = args->find(EncodableValue("id"));
        if (id_it != args->end()) {
          if (const auto* s = std::get_if<std::string>(&id_it->second)) {
            id = *s;
          }
        }
        const auto v_it = args->find(EncodableValue("scalar"));
        if (v_it != args->end()) {
          if (const auto* d = std::get_if<double>(&v_it->second)) {
            scalar = *d;
          } else if (const auto* i = std::get_if<int32_t>(&v_it->second)) {
            scalar = *i;
          }
        }
      }
      std::string error;
      if (!wasapi::SetHardwareVolume(id, static_cast<float>(scalar), &error)) {
        result->Error("wasapi", error);
        return;
      }
      result->Success();
      return;
    }
    if (method == "getHardwareVolume") {
      const auto* args = std::get_if<EncodableMap>(call.arguments());
      std::string id;
      if (args) {
        const auto it = args->find(EncodableValue("id"));
        if (it != args->end()) {
          if (const auto* s = std::get_if<std::string>(&it->second)) id = *s;
        }
      }
      float scalar = 1.0f;
      std::string error;
      if (!wasapi::GetHardwareVolume(id, &scalar, &error)) {
        result->Error("wasapi", error);
        return;
      }
      result->Success(EncodableValue(static_cast<double>(scalar)));
      return;
    }
    if (method == "defaultDeviceId") {
      result->Success(EncodableValue(wasapi::DefaultDeviceId()));
      return;
    }
    result->NotImplemented();
  }

  std::unique_ptr<flutter::MethodChannel<EncodableValue>> method_;
  std::unique_ptr<flutter::EventChannel<EncodableValue>> events_;
  std::unique_ptr<flutter::EventSink<EncodableValue>> sink_;
};

WasapiChannel::WasapiChannel(flutter::BinaryMessenger* messenger)
    : impl_(std::make_unique<Impl>(messenger)) {}

WasapiChannel::~WasapiChannel() = default;

}  // namespace lastwave
