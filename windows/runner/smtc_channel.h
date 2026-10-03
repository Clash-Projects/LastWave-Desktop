#ifndef RUNNER_SMTC_CHANNEL_H_
#define RUNNER_SMTC_CHANNEL_H_

#include <windows.h>

#include <flutter/binary_messenger.h>

#include <memory>

namespace lastwave {

// Windows System Media Transport Controls (SMTC) bridge — the Windows
// counterpart to the Linux MPRIS endpoint.
//
// Exposes now-playing metadata + transport in the volume flyout, lock
// screen, Bluetooth/AVRCP and hardware media keys. Never renders audio:
// libmpv stays the sole PCM renderer, same separation as the WASAPI
// probe engine. Every failure degrades to silence so startup is never
// blocked. Constructed with the main window HWND only (the hidden
// BotGuard WebView must never register its own SMTC instance).
class SmtcChannel {
 public:
  SmtcChannel(flutter::BinaryMessenger* messenger, HWND hwnd);
  ~SmtcChannel();

  SmtcChannel(const SmtcChannel&) = delete;
  SmtcChannel& operator=(const SmtcChannel&) = delete;

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace lastwave

#endif  // RUNNER_SMTC_CHANNEL_H_
