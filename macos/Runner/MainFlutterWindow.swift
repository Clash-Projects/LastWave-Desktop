import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// Keeps the Now Playing bridge (media keys, Control Center) alive for
  /// the lifetime of the main window.
  private var nowPlaying: NowPlayingChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    nowPlaying = NowPlayingChannel(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}
