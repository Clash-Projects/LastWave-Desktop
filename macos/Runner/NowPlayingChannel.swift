import Cocoa
import FlutterMacOS
import MediaPlayer

/// macOS counterpart of `windows/runner/smtc_channel.cpp`.
///
/// Serves the same `lastwave/smtc` method channel that
/// `lib/features/smtc/smtc_service.dart` drives, publishing metadata to
/// `MPNowPlayingInfoCenter` (menu bar Now Playing, Control Center, lock
/// screen, AirPods/Bluetooth) and routing `MPRemoteCommandCenter`
/// events (hardware media keys, Control Center buttons) back to Dart
/// as `onButton` / `onSeek` calls.
final class NowPlayingChannel: NSObject {
  private static let statusStopped = 0
  private static let statusPlaying = 1
  private static let statusPaused = 2
  private static let statusChanging = 3

  private let channel: FlutterMethodChannel
  private let center = MPNowPlayingInfoCenter.default()
  private let commands = MPRemoteCommandCenter.shared()

  /// Last pushed timeline anchor, so a late artwork patch can republish
  /// the extrapolated position instead of snapping back to it.
  private var anchorPosition: Double = 0
  private var anchorTime = Date()
  private var anchorRate: Double = 0

  private var artUrl = ""
  private var artTask: URLSessionDataTask?
  private var artwork: MPMediaItemArtwork?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "lastwave/smtc", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      switch call.method {
      case "update":
        if let args = call.arguments as? [String: Any] {
          self.update(args)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    setupCommands()
  }

  // MARK: - Dart -> system

  private func update(_ args: [String: Any]) {
    let hasTrack = args["hasTrack"] as? Bool ?? false
    let status = (args["status"] as? NSNumber)?.intValue ?? Self.statusStopped

    guard hasTrack, status != Self.statusStopped else {
      center.nowPlayingInfo = nil
      center.playbackState = .stopped
      setTransportEnabled(false, canNext: false, canPrev: false)
      cancelArtwork()
      return
    }

    let positionMs = (args["positionMs"] as? NSNumber)?.doubleValue ?? 0
    let durationMs = (args["durationMs"] as? NSNumber)?.doubleValue ?? 0
    let rate = (args["rate"] as? NSNumber)?.doubleValue ?? 0

    anchorPosition = positionMs / 1000
    anchorTime = Date()
    anchorRate = rate

    var info: [String: Any] = [
      MPMediaItemPropertyTitle: args["title"] as? String ?? "",
      MPMediaItemPropertyArtist: args["artist"] as? String ?? "",
      MPMediaItemPropertyAlbumTitle: args["album"] as? String ?? "",
      MPMediaItemPropertyPlaybackDuration: durationMs / 1000,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: anchorPosition,
      MPNowPlayingInfoPropertyPlaybackRate: rate,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
    ]

    let newArtUrl = args["artUrl"] as? String ?? ""
    if newArtUrl != artUrl {
      artUrl = newArtUrl
      artwork = nil
      loadArtwork(newArtUrl)
    }
    if let artwork {
      info[MPMediaItemPropertyArtwork] = artwork
    }

    center.nowPlayingInfo = info
    // Buffering while playing still counts as playing (SMTC "Changing").
    center.playbackState =
      (status == Self.statusPlaying || status == Self.statusChanging) ? .playing : .paused

    setTransportEnabled(
      true,
      canNext: args["canNext"] as? Bool ?? false,
      canPrev: args["canPrev"] as? Bool ?? false)
  }

  private func cancelArtwork() {
    artTask?.cancel()
    artTask = nil
    artUrl = ""
    artwork = nil
  }

  private func loadArtwork(_ urlString: String) {
    artTask?.cancel()
    artTask = nil
    guard !urlString.isEmpty, let url = URL(string: urlString) else { return }

    if url.isFileURL {
      if let image = NSImage(contentsOf: url) {
        applyArtwork(image, for: urlString)
      }
      return
    }

    let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
      guard let data, let image = NSImage(data: data) else { return }
      DispatchQueue.main.async {
        self?.applyArtwork(image, for: urlString)
      }
    }
    artTask = task
    task.resume()
  }

  private func applyArtwork(_ image: NSImage, for urlString: String) {
    // A newer track may have arrived while the download was in flight.
    guard urlString == artUrl else { return }
    let art = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    artwork = art

    guard var info = center.nowPlayingInfo else { return }
    info[MPMediaItemPropertyArtwork] = art
    let elapsed = anchorPosition + Date().timeIntervalSince(anchorTime) * anchorRate
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
    center.nowPlayingInfo = info
  }

  // MARK: - System -> Dart

  private func setupCommands() {
    commands.playCommand.addTarget { [weak self] _ in self?.button("play") ?? .commandFailed }
    commands.pauseCommand.addTarget { [weak self] _ in self?.button("pause") ?? .commandFailed }
    commands.togglePlayPauseCommand.addTarget { [weak self] _ in
      self?.button("toggle") ?? .commandFailed
    }
    commands.stopCommand.addTarget { [weak self] _ in self?.button("stop") ?? .commandFailed }
    commands.nextTrackCommand.addTarget { [weak self] _ in self?.button("next") ?? .commandFailed }
    commands.previousTrackCommand.addTarget { [weak self] _ in
      self?.button("previous") ?? .commandFailed
    }
    commands.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else {
        return .commandFailed
      }
      let ms = Int((event.positionTime * 1000).rounded())
      DispatchQueue.main.async {
        self.channel.invokeMethod("onSeek", arguments: ms)
      }
      return .success
    }

    // Unsupported transports stay hidden from Control Center.
    commands.skipForwardCommand.isEnabled = false
    commands.skipBackwardCommand.isEnabled = false
    commands.seekForwardCommand.isEnabled = false
    commands.seekBackwardCommand.isEnabled = false
    commands.changePlaybackRateCommand.isEnabled = false

    setTransportEnabled(false, canNext: false, canPrev: false)
  }

  private func setTransportEnabled(_ enabled: Bool, canNext: Bool, canPrev: Bool) {
    commands.playCommand.isEnabled = enabled
    commands.pauseCommand.isEnabled = enabled
    commands.togglePlayPauseCommand.isEnabled = enabled
    commands.stopCommand.isEnabled = enabled
    commands.changePlaybackPositionCommand.isEnabled = enabled
    commands.nextTrackCommand.isEnabled = enabled && canNext
    commands.previousTrackCommand.isEnabled = enabled && canPrev
  }

  private func button(_ name: String) -> MPRemoteCommandHandlerStatus {
    DispatchQueue.main.async { [weak self] in
      self?.channel.invokeMethod("onButton", arguments: name)
    }
    return .success
  }
}
