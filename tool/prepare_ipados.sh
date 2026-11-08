#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v flutter >/dev/null 2>&1; then
  echo "Flutter SDK is required to generate the iPadOS host project." >&2
  exit 1
fi

# Generate only the missing iOS host. This leaves the shared Dart source and
# the existing macOS host untouched.
if [[ ! -d ios ]]; then
  flutter create \
    --platforms=ios \
    --org com.lastwave \
    --project-name lastwave \
    .
fi

# flutter create emits a generic starter test when the repository has no
# starter widget_test.dart. It targets MyApp in lib/main.dart, which LastWave
# does not define. Delete only that exact generated template, never project tests.
STARTER_TEST="test/widget_test.dart"
if [[ -f "$STARTER_TEST" ]] && \
   grep -q "package:lastwave/main.dart" "$STARTER_TEST" && \
   grep -q "MyApp" "$STARTER_TEST"; then
  rm "$STARTER_TEST"
fi

PBXPROJ="ios/Runner.xcodeproj/project.pbxproj"
INFO_PLIST="ios/Runner/Info.plist"
if [[ ! -f "$PBXPROJ" || ! -f "$INFO_PLIST" ]]; then
  echo "Flutter did not generate the expected iOS Runner project." >&2
  exit 1
fi

python3 - "$PBXPROJ" "$INFO_PLIST" <<'PY'
import pathlib
import plistlib
import re
import sys

pbx_path = pathlib.Path(sys.argv[1])
plist_path = pathlib.Path(sys.argv[2])
bundle_id = "com.lastwave.lastwaveDesktop"

pbx = pbx_path.read_text(encoding="utf-8")

def replace_bundle(match: re.Match[str]) -> str:
    old_id = match.group(2).strip()
    suffix = ".RunnerTests" if old_id.endswith(".RunnerTests") else ""
    return f"{match.group(1)}{bundle_id}{suffix}{match.group(3)}"

pbx, bundle_count = re.subn(
    r"(PRODUCT_BUNDLE_IDENTIFIER\s*=\s*)([^;]+)(;)",
    replace_bundle,
    pbx,
)
if bundle_count == 0:
    raise SystemExit("No PRODUCT_BUNDLE_IDENTIFIER settings found in iOS project.")

pbx, target_count = re.subn(
    r"IPHONEOS_DEPLOYMENT_TARGET\s*=\s*[^;]+;",
    "IPHONEOS_DEPLOYMENT_TARGET = 15.0;",
    pbx,
)
if target_count == 0:
    raise SystemExit("No iOS deployment target settings found in Xcode project.")
pbx_path.write_text(pbx, encoding="utf-8")

with plist_path.open("rb") as handle:
    info = plistlib.load(handle)

info["CFBundleDisplayName"] = "LastWave"
info["CFBundleName"] = "LastWave"

# Permit continuous audio playback while the application is backgrounded.
# This declares the capability; the native audio session and remote-control
# bridge must still be implemented and tested before background playback can
# be considered verified.
modes = list(info.get("UIBackgroundModes", []))
if "audio" not in modes:
    modes.append("audio")
info["UIBackgroundModes"] = modes

# Use all standard iPad orientations; the Flutter UI remains responsible for
# adapting its layout to the available size and safe areas.
info["UISupportedInterfaceOrientations~ipad"] = [
    "UIInterfaceOrientationPortrait",
    "UIInterfaceOrientationPortraitUpsideDown",
    "UIInterfaceOrientationLandscapeLeft",
    "UIInterfaceOrientationLandscapeRight",
]

plist_path.write_bytes(
    plistlib.dumps(info, fmt=plistlib.FMT_XML, sort_keys=False)
)
print("Configured LastWave bundle metadata, iOS 15 minimum, and audio background capability.")
PY

# Reuse the actual LastWave macOS app icon as the iPadOS app icon.
ICON_SOURCE="macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png"
ICON_DIR="ios/Runner/Assets.xcassets/AppIcon.appiconset"
if [[ -f "$ICON_SOURCE" && -d "$ICON_DIR" ]]; then
  cp "$ICON_SOURCE" "$ICON_DIR/AppIcon.png"
  cat > "$ICON_DIR/Contents.json" <<'JSON'
{
  "images" : [
    {
      "filename" : "AppIcon.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON
fi

# Replace Flutter's minimal AppDelegate with the native playback-session bridge.
# Flutter 3.47.9 uses the implicit-engine/UIScene lifecycle.
cat > ios/Runner/AppDelegate.swift <<'SWIFT'
import AVFoundation
import Flutter
import MediaPlayer
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var audioChannel: FlutterMethodChannel?
  private var interruptionObserver: NSObjectProtocol?
  private var routeChangeObserver: NSObjectProtocol?
  private var artworkTask: URLSessionDataTask?
  private var currentArtworkURL: String?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "LastWaveAudioBridge")
    let channel = FlutterMethodChannel(
      name: "com.lastwave/audio",
      binaryMessenger: registrar.messenger()
    )
    audioChannel = channel

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "unavailable", message: "LastWave audio bridge is unavailable.", details: nil))
        return
      }

      switch call.method {
      case "configure":
        self.configureAudioSession()
        self.configureRemoteCommands()
        self.installAudioSessionObservers()
        result(nil)
      case "updateNowPlaying":
        guard let values = call.arguments as? [String: Any] else {
          result(FlutterError(code: "bad_arguments", message: "Expected Now Playing metadata.", details: nil))
          return
        }
        self.updateNowPlaying(values)
        result(nil)
      case "clearNowPlaying":
        self.clearNowPlaying()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // Dart calls "configure" before constructing the playback player.
    // Avoid registering duplicate remote-command targets here.
  }

  private func configureAudioSession() {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(
        .playback,
        mode: .default,
        options: [.allowAirPlay, .allowBluetoothA2DP]
      )
    } catch {
      NSLog("LastWave: unable to configure the playback audio session (%@)", String(describing: error))
    }
  }

  private func configureRemoteCommands() {
    let center = MPRemoteCommandCenter.shared()

    center.playCommand.isEnabled = true
    center.pauseCommand.isEnabled = true
    center.togglePlayPauseCommand.isEnabled = true
    center.nextTrackCommand.isEnabled = true
    center.previousTrackCommand.isEnabled = true
    center.changePlaybackPositionCommand.isEnabled = true

    center.playCommand.addTarget { [weak self] _ in
      return self?.sendRemoteCommand("play") ?? .commandFailed
    }
    center.pauseCommand.addTarget { [weak self] _ in
      return self?.sendRemoteCommand("pause") ?? .commandFailed
    }
    center.togglePlayPauseCommand.addTarget { [weak self] _ in
      return self?.sendRemoteCommand("toggle") ?? .commandFailed
    }
    center.nextTrackCommand.addTarget { [weak self] _ in
      return self?.sendRemoteCommand("next") ?? .commandFailed
    }
    center.previousTrackCommand.addTarget { [weak self] _ in
      return self?.sendRemoteCommand("previous") ?? .commandFailed
    }
    center.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let seekEvent = event as? MPChangePlaybackPositionCommandEvent else {
        return .commandFailed
      }
      return self?.sendRemoteCommand("seek", arguments: seekEvent.positionTime) ?? .commandFailed
    }
  }

  private func sendRemoteCommand(
    _ method: String,
    arguments: Any? = nil
  ) -> MPRemoteCommandHandlerStatus {
    guard let channel = audioChannel else { return .commandFailed }
    DispatchQueue.main.async {
      channel.invokeMethod(method, arguments: arguments)
    }
    return .success
  }

  private func installAudioSessionObservers() {
    let center = NotificationCenter.default
    let session = AVAudioSession.sharedInstance()

    if interruptionObserver == nil {
      interruptionObserver = center.addObserver(
        forName: AVAudioSession.interruptionNotification,
        object: session,
        queue: .main
      ) { [weak self] notification in
        guard
          let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }

        if type == .began {
          _ = self?.sendRemoteCommand("pause")
        } else if type == .ended {
          let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
          let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
          if options.contains(.shouldResume) {
            try? AVAudioSession.sharedInstance().setActive(true)
            _ = self?.sendRemoteCommand("resume")
          }
        }
      }
    }

    if routeChangeObserver == nil {
      routeChangeObserver = center.addObserver(
        forName: AVAudioSession.routeChangeNotification,
        object: session,
        queue: .main
      ) { [weak self] notification in
        guard
          let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
          let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
        else { return }

        if reason == .oldDeviceUnavailable {
          // Pause when wired headphones or another active output is removed.
          _ = self?.sendRemoteCommand("pause")
        }
      }
    }
  }

  private func updateNowPlaying(_ values: [String: Any]) {
    let title = values["title"] as? String ?? "LastWave"
    let artist = values["artist"] as? String ?? ""
    let album = values["album"] as? String ?? ""
    let artworkURL = values["artworkUrl"] as? String ?? ""
    let duration = max(0, values["durationSeconds"] as? Double ?? 0)
    let position = max(0, values["positionSeconds"] as? Double ?? 0)
    let isPlaying = values["isPlaying"] as? Bool ?? false
    let speed = max(0.1, values["speed"] as? Double ?? 1.0)

    if isPlaying {
      try? AVAudioSession.sharedInstance().setActive(true)
    }

    var info: [String: Any] = [
      MPMediaItemPropertyTitle: title,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
      MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? speed : 0.0,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
    ]
    if !artist.isEmpty { info[MPMediaItemPropertyArtist] = artist }
    if !album.isEmpty { info[MPMediaItemPropertyAlbumTitle] = album }
    if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }

    if artworkURL == currentArtworkURL,
       let artwork = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] {
      info[MPMediaItemPropertyArtwork] = artwork
    }

    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    loadArtwork(from: artworkURL)
  }

  private func loadArtwork(from rawURL: String) {
    guard rawURL != currentArtworkURL else { return }
    currentArtworkURL = rawURL
    artworkTask?.cancel()
    artworkTask = nil

    guard let url = URL(string: rawURL), url.scheme == "https" || url.scheme == "http" else {
      return
    }

    artworkTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
      guard let self = self, let data = data, let image = UIImage(data: data) else { return }
      DispatchQueue.main.async {
        guard self.currentArtworkURL == rawURL else { return }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
      }
    }
    artworkTask?.resume()
  }

  private func clearNowPlaying() {
    artworkTask?.cancel()
    artworkTask = nil
    currentArtworkURL = nil
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    MPNowPlayingInfoCenter.default().playbackState = .stopped
    try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
  }

  deinit {
    if let observer = interruptionObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    if let observer = routeChangeObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    artworkTask?.cancel()
  }
}
SWIFT

echo "iPadOS host project is ready."
