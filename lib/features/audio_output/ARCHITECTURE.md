# WASAPI Exclusive / bit-perfect output

LastWave keeps **media_kit / libmpv** as the PCM renderer. This module adds
Windows endpoint probing, format negotiation, hardware volume, and an honest
bit-perfect status machine around that existing player.

```
Application (Riverpod)
    ↓
Music Decoder (libmpv)
    ↓
PCM Audio
    ↓
Audio Processing / DSP   ← bypassed in bit-perfect
    ↓
Bit-Perfect Decision Layer   FormatNegotiator
    ↓
Audio Format Manager         AudioOutputController
    ↓
Windows WASAPI Engine        wasapi_engine.cpp + mpv ao=wasapi
    ↓
WASAPI Exclusive Mode        audio-exclusive=yes
    ↓
USB DAC
```

Windows-specific Core Audio lives only in `windows/runner/wasapi_*.cpp`.
Dart never talks to IMMDevice directly.

## Signal path

| Mode | Mixer | DSP / PEQ / ReplayGain | Software volume | Resampling |
| --- | --- | --- | --- | --- |
| Bit-perfect | Bypassed (exclusive) | Off | Off (unity / hardware) | Off when DAC matches source |
| DSP / shared | Windows mixer | Allowed | Allowed | Allowed |

Bit-perfect is **not** implied by exclusive mode. It is true only when:

- WASAPI Exclusive is requested **and** applied
- source format equals negotiated output
- no DSP / PEQ / crossfade / speed ≠ 1.0
- software volume is not modifying PCM
- the DAC actually listed the format via `IAudioClient::IsFormatSupported`

## Sample-rate / bit-depth switching

`gapless-audio=weak` while exclusive is on:

- same format consecutive tracks keep the WASAPI stream (gapless)
- a new rate/depth closes and reopens the exclusive client at the source format

Capabilities are queried, never hard-coded. 32-bit is listed only when the
endpoint accepts exclusive 32-bit PCM or float.

## Files

### Native (isolated)

- `windows/runner/wasapi_engine.h` / `.cpp` — `IMMDeviceEnumerator`, `IMMDevice`,
  `IAudioClient::IsFormatSupported`, `IAudioEndpointVolume`,
  `IMMNotificationClient`, `WAVEFORMATEXTENSIBLE`
- `windows/runner/wasapi_channel.h` / `.cpp` — MethodChannel `lastwave/wasapi`,
  EventChannel `lastwave/wasapi/events`
- `windows/runner/flutter_window.cpp` — registers the channel
- `windows/runner/CMakeLists.txt` — compiles the engine, links ole32/uuid

### Dart

- `lib/features/audio_output/pcm_format.dart`
- `lib/features/audio_output/dac_device.dart`
- `lib/features/audio_output/format_negotiator.dart`
- `lib/features/audio_output/output_path_status.dart`
- `lib/features/audio_output/wasapi_engine.dart`
- `lib/features/audio_output/output_controller.dart`
- `lib/features/audio_output/output_path_sheet.dart`

### Playback / prefs / UI hooks

- `lib/features/player/playback_service.dart` — `configureWasapi`, hardware-volume lock, live `audioParams`
- `lib/features/player/player_state.dart` — `outputFormat`
- `lib/core/storage/prefs.dart` — `lw_bit_perfect`, `lw_audio_device_id`, `lw_wasapi_exclusive`
- `lib/features/settings/app.dart` — `audioOutputProvider.attach()` after player warm-start
- `lib/ui/settings/settings_page.dart` — Audio output device / exclusive / bit-perfect / stream path
- `lib/ui/player_dock/player_dock.dart` — quality flyout + device picker + volume routing

### Tests

- `test/audio_output_test.dart` — native match, fallbacks, bit-perfect reasons
