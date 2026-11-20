import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// Keeps the Now Playing bridge (media keys, Control Center) alive for
  /// the lifetime of the main window.
  private var nowPlaying: NowPlayingChannel?
  private var windowControlChannel: FlutterMethodChannel?
  private var interceptMinimize = false

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    nowPlaying = NowPlayingChannel(messenger: flutterViewController.engine.binaryMessenger)
    let control = FlutterMethodChannel(
      name: "lastwave/window_control",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    control.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      if call.method == "setInterceptMinimize" {
        self.interceptMinimize = (call.arguments as? Bool) ?? false
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    windowControlChannel = control

    super.awakeFromNib()
  }

  override func performMiniaturize(_ sender: Any?) {
    if interceptMinimize {
      windowControlChannel?.invokeMethod("onMinimize", arguments: nil)
      return
    }
    super.performMiniaturize(sender)
  }

  override func miniaturize(_ sender: Any?) {
    if interceptMinimize {
      windowControlChannel?.invokeMethod("onMinimize", arguments: nil)
      return
    }
    super.miniaturize(sender)
  }
}
