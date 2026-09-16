#ifndef RUNNER_WASAPI_ENGINE_H_
#define RUNNER_WASAPI_ENGINE_H_

#include <string>
#include <vector>

/// Isolated WASAPI capability / hardware-volume engine.
/// Does not render PCM — libmpv remains the exclusive-mode renderer.
/// This layer enumerates endpoints, probes exclusive PCM formats via
/// IAudioClient::IsFormatSupported, and drives IAudioEndpointVolume.
namespace lastwave {
namespace wasapi {

struct PcmFormat {
  int sample_rate_hz = 0;
  int bit_depth = 0;
  int channels = 0;
};

struct DeviceInfo {
  std::string id;
  std::string name;
  std::string manufacturer;
  std::string enumerator;
  bool is_default = false;
  bool exclusive_supported = false;
  bool hardware_volume = false;
  std::vector<PcmFormat> formats;
};

bool EnumerateRenderDevices(std::vector<DeviceInfo>* out,
                            std::string* error);

bool ProbeDevice(const std::string& device_id, DeviceInfo* out,
                 std::string* error);

bool SetHardwareVolume(const std::string& device_id, float scalar,
                       std::string* error);

bool GetHardwareVolume(const std::string& device_id, float* scalar,
                       std::string* error);

std::string DefaultDeviceId();

/// Callbacks run on the thread that registered (STA UI thread here).
class DeviceListener {
 public:
  virtual ~DeviceListener() = default;
  virtual void OnDevicesChanged(const std::string& reason,
                                const std::string& device_id) = 0;
};

bool StartWatching(DeviceListener* listener, std::string* error);
void StopWatching();

}  // namespace wasapi
}  // namespace lastwave

#endif  // RUNNER_WASAPI_ENGINE_H_
