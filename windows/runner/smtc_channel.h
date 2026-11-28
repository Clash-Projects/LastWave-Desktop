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

  // Posted to the main window when a flyout / media-key button is pressed.
  // SMTC raises ButtonPressed on a thread-pool thread, and Flutter only
  // delivers channel messages sent from the platform thread, so the press
  // is marshalled here and forwarded by OnButtonMessage. WPARAM carries
  // the SystemMediaTransportControlsButton value.
  static constexpr UINT kButtonMessage = WM_APP + 0x51;

  // Call from the window procedure (platform thread) for kButtonMessage.
  void OnButtonMessage(WPARAM button);

  // Posted to the main window when the shell asks to seek (flyout scrubber).
  // Same marshalling as buttons: SMTC raises PlaybackPositionChangeRequested
  // on a thread-pool thread. WPARAM carries the requested position in ms.
  static constexpr UINT kSeekMessage = WM_APP + 0x52;

  // Call from the window procedure (platform thread) for kSeekMessage.
  void OnSeekMessage(WPARAM positionMs);

  SmtcChannel(const SmtcChannel&) = delete;
  SmtcChannel& operator=(const SmtcChannel&) = delete;

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace lastwave

#endif  // RUNNER_SMTC_CHANNEL_H_
