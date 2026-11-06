<div align="center">

<img src="LastWave_Desktop_v7_1440p.png" alt="LastWave Desktop Banner" width="100%" style="border-radius: 16px;" />

<h1>LastWave</h1>

**Simple Desktop YouTube Music client with WinUI, Bit-Perfect playback, Automix, Lossless addons & advanced audiophile features.**

<br/>

<p align="center">
  <a href="https://t.me/clashprojects" target="_blank"><img src="docs/badges/btn_telegram_support.svg" alt="Telegram Support" height="42" /></a>
  <a href="https://t.me/MaterialYouApp" target="_blank"><img src="docs/badges/btn_telegram_channel.svg" alt="Telegram Channel" height="42" /></a>
  <a href="https://discord.gg/DmyM2p2fMe" target="_blank"><img src="docs/badges/btn_discord.svg" alt="Discord Community" height="42" /></a>
</p>

</div>

---

## Overview

LastWave Desktop is a fast, native desktop YouTube Music client with modern WinUI styling for Windows, Linux, and macOS. It delivers high-fidelity audio playback and a fluid interface that adapts to your music.

For audio lovers, LastWave Desktop packs Bit-Perfect audio output, Lossless FLAC addon support, 15-band parametric equalizer, smooth Automix transitions, Spotify Canvas & integration, and real-time synchronized lyrics, all in a lightweight desktop application.

---

## Features

<table>
  <tr>
    <td width="50%" valign="top">

#### Playback
- Stream any track or video from YouTube Music
- Background audio playback & system media controls
- High-res audio downloads with embedded metadata & `.lrc` lyrics
- Download & cache for offline listening
- Skip silence & sleep timer

</td>
    <td width="50%" valign="top">

#### Audio
- Bit-Perfect audio output (direct hardware bypass)
- Lossless FLAC addon support (up to 24-bit Hi-Res)
- 15-band Parametric Equalizer & AutoEQ presets
- Smart Automix transitions & smooth crossfade
- Audio normalization (ReplayGain / LUFS)
- Real-time tempo & pitch control

</td>
  </tr>
  <tr>
    <td width="50%" valign="top">

#### Lyrics & Discovery
- Live millisecond-synchronized lyrics (LRCLIB)
- Lyrics romanization for non-Latin scripts (Japanese, Korean, etc.)
- Multi-language lyrics translation
- Spotify Canvas & animated video backgrounds
- Personalized quick picks, mood radios & genre discovery
- Search songs, albums, artists, videos, and playlists

</td>
    <td width="50%" valign="top">

#### Library & Account
- Full library management & offline cached library
- Spotify Integration (Account login, Liked Songs sync & deep links)
- Import public playlists from Spotify & Apple Music
- YouTube Music account login & bidirectional sync
- Local & cloud playlists with custom reordering
- Custom audio tag editing & cover art selection

</td>
  </tr>
  <tr>
    <td width="50%" valign="top">

#### Social
- Listen together with friends in real-time
- Built-in Last.fm scrobbler with background tracking
- Safe Discord Rich Presence with live album art
- Export and share lyrics as aesthetic quote cards

</td>
    <td width="50%" valign="top">

#### Interface
- Clean WinUI & Fluent design interface
- Real-time acrylic blur and backdrop refraction
- Dynamic color theming + preset palettes
- Light, Dark, and Pure Black modes
- Global media hotkeys & mini-player

</td>
  </tr>
</table>

---

## Getting Started

### Installation

| Channel | Source | Compatibility |
|:---|:---|:---|
| **Windows** | [GitHub Releases](https://github.com/Clash-Projects/LastWave-Desktop/releases) | Windows 10 & 11 (.exe / .msix installer) |
| **Linux** | [GitHub Releases](https://github.com/Clash-Projects/LastWave-Desktop/releases) | AppImage / Flatpak / deb packages |
| **macOS** | [GitHub Releases](https://github.com/Clash-Projects/LastWave-Desktop/releases) | Apple Silicon & Intel (.dmg) |
| **Android App** | [LastWave-Native](https://github.com/Clash-Projects/LastWave-Native) | Official mobile client for Android devices |

### Quick Setup

1. Download and run the installer for your operating system.
2. *(Optional)* Navigate to **Settings → Audio** to configure:
   - **Bit-Perfect Output:** Enable exclusive output mode for bit-perfect audio.
   - **Equalizer Presets:** Apply parametric EQ curves or headphone correction.
   - **Lossless Addons:** Enable the modular addon service for Hi-Res FLAC playback.
3. Start streaming music, exploring smart radios, and enjoying synced lyrics!

---

## Building from Source

### Prerequisites
- **Flutter SDK:** Version 3.13+ or higher
- **C++ Build Tools:** Visual Studio (Windows), build-essential (Linux), or Xcode (macOS)

### Build Instructions

```bash
# Clone the repository
git clone https://github.com/Clash-Projects/LastWave-Desktop.git
cd LastWave-Desktop

# Install dependencies
flutter pub get

# Build release executable for your platform
flutter build windows --release   # Windows
flutter build linux --release     # Linux
flutter build macos --release     # macOS
```

> [!TIP]
> For local development and hot reload, connect your target environment and run `flutter run -d windows` (or `-d linux` / `-d macos`).

---

## Support the Project

If LastWave has been useful to you, consider supporting its development.

<div align="left">
  <table style="margin: 0 auto; border-collapse: collapse; border: none;">
    <tr>
      <td align="center" style="padding: 15px; border: none;">
        <a href="https://buymeacoffee.com/ajisth" target="_blank" style="text-decoration:none;"><img src="docs/badges/bmac.png" alt="Buy Me A Coffee" width="140" style="border-radius: 12px; box-shadow: 0 8px 16px rgba(0,0,0,0.2);"/></a>
      </td>
      <td align="center" style="padding: 15px; border: none;">
        <a href="https://buymeachai.ezee.li/ajisth69" target="_blank" style="text-decoration:none;"><img src="docs/badges/upi.png" alt="UPI (Buy Me A Chai)" width="140" style="border-radius: 12px; box-shadow: 0 8px 16px rgba(0,0,0,0.2);"/></a>
      </td>
      <td align="center" style="padding: 15px; border: none;">
        <a href="https://github.com/sponsors/ajisth69" target="_blank" style="text-decoration:none;"><img src="docs/badges/github_sponsors.svg" alt="GitHub Sponsors" width="140" style="border-radius: 12px; box-shadow: 0 8px 16px rgba(0,0,0,0.2);"/></a>
      </td>
    </tr>
  </table>
</div>

---

## Acknowledgements

LastWave Desktop is made possible thanks to these open-source projects:

- **[media_kit](https://github.com/media-kit/media-kit)** — Audio playback engine powered by libmpv
- **[Limusic](https://github.com/chenyandian/Limusic)** — InnerTube client registry & stream resolution fast path
- **[LRCLIB](https://lrclib.net/)** — Real-time millisecond-synchronized lyrics database
- **[SimpMusic](https://github.com/maxrave-dev/SimpMusic)** — Lyrics API integration & multi-source fallback
- **[NewPipe](https://github.com/TeamNewPipe/NewPipeExtractor)** — Signature decipher patterns & extraction logic
- **[fluent_ui](https://github.com/bdlukaa/fluent_ui)** — WinUI & Fluent design system for desktop

---

## Contributors

LastWave wouldn't be possible without our incredible community of contributors. Thank you for making it better every day!

<p align="center">
  <a href="https://github.com/Clash-Projects/LastWave-Desktop/graphs/contributors">
    <img src="https://contrib.rocks/image?repo=Clash-Projects/LastWave-Desktop" alt="Contributors" />
  </a>
</p>

---

## Disclaimer

LastWave is an open-source, non-commercial application developed strictly for educational and research purposes.

- **No Affiliation:** This project is not affiliated with, funded, authorized, endorsed by, or in any way associated with Google LLC, YouTube, YouTube Music, Spotify, Apple Inc., Last.fm, or any of their subsidiaries.
- **Content Delivery:** LastWave does not host, store on private servers, or distribute copyrighted media. All playback streams and metadata are resolved directly from public endpoints.
- **Trademarks:** All product names, logos, trademarks, and registered trademarks belong to their respective owners.
