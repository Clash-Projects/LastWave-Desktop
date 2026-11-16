#ifndef RUNNER_APP_AUDIO_CAPTURE_H_
#define RUNNER_APP_AUDIO_CAPTURE_H_

#include <flutter/binary_messenger.h>

#include <memory>

namespace lastwave {

// MethodChannel `lastwave/app_audio`: captures ONLY this process's audio
// output (WASAPI process loopback, no microphone, no permission prompt) as
// 48 kHz stereo s16 PCM and writes it to a loopback TCP port Dart opened.
// Used for Jam browser guests.
class AppAudioCapture {
 public:
  explicit AppAudioCapture(flutter::BinaryMessenger* messenger);
  ~AppAudioCapture();

  AppAudioCapture(const AppAudioCapture&) = delete;
  AppAudioCapture& operator=(const AppAudioCapture&) = delete;

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace lastwave

#endif  // RUNNER_APP_AUDIO_CAPTURE_H_
