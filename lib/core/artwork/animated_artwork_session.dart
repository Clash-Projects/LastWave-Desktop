import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'animated_artwork_service.dart';

/// App-scoped muted motion-art player.
///
/// The Now Playing page mounts and unmounts often. JSON lookup is already
/// cached; this keeps the decoded clip itself so returning to Now Playing or
/// skipping tracks on the same album does not reopen the file.
///
/// Crash hardening (Windows fail-fast in flutter_windows.dll, always seconds
/// after a canvas clip's first frames): the native video output
/// (VideoOutputManager.Create/SetSize/Dispose + texture register/unregister)
/// must never be thrashed. So this session keeps ONE player + ONE texture
/// for the whole app run — a track change is just a loadfile into the
/// existing texture — serializes every native op so two are never in flight,
/// and debounces rapid skips into a single open. There is deliberately no
/// mid-session teardown: destroying the texture while frames are in flight
/// is what aborted the engine.
class AnimatedArtworkSession extends ChangeNotifier {
  Player? _player;
  VideoController? _controller;
  StreamSubscription<int?>? _widthSub;
  Timer? _pauseTimer;
  Timer? _readyTimer;
  VoidCallback? _rectListener;
  int _generation = 0;
  int _refs = 0;
  String _url = '';
  bool _ready = false;
  bool _visible = false;
  bool _silenced = false;
  // Serializes native ops (open/stop/dispose): each waits for the previous.
  Future<void> _tail = Future.value();

  VideoController? get controller => _controller;
  String get url => _url;
  bool get ready => _ready;

  bool isReadyFor(String url) =>
      url.isNotEmpty && url == _url && _ready && _visible;

  bool _notifyPending = false;
  bool _disposed = false;

  /// Riverpod forbids modifying a provider inside widget lifecycles,
  /// but attach()/open() run from initState/didUpdateWidget — and
  /// open() notifies synchronously before its first await. So every
  /// notification is deferred to the event queue and coalesced.
  /// Future, not microtask: microtasks can still land inside the
  /// build scope; the event queue cannot.
  void _notify() {
    if (_notifyPending || _disposed) return;
    _notifyPending = true;
    Future(() {
      _notifyPending = false;
      if (_disposed) return;
      notifyListeners();
    });
  }

  void attach(String url) {
    _pauseTimer?.cancel();
    _refs++;
    unawaited(open(url));
  }

  /// Video widget is in the tree. Combined with [_ready] this fades the still.
  void showSurface() {
    if (_visible) return;
    _visible = true;
    if (_ready) _notify();
  }

  /// Now Playing left; keep the player but cover with the still again.
  void hideSurface() {
    _visible = false;
  }

  Future<void> open(String url) async {
    if (url.isEmpty || _disposed) return;
    if (url == _url && _player != null) {
      // Same clip: no native churn, just (re)play through the queue.
      await _serialized(() async {
        try {
          await _player?.play();
        } catch (_) {}
      });
      if (_ready) _notify();
      return;
    }
    final gen = ++_generation;
    _url = url;
    _ready = false;
    _notify();
    // Coalesce skip bursts: only the latest url reaches native code.
    await Future.delayed(const Duration(milliseconds: 250));
    if (gen != _generation || _disposed) return;
    await _serialized(() => _openLocked(url, gen));
  }

  /// Runs with no other native op in flight. Never throws.
  Future<void> _openLocked(String url, int gen) async {
    if (gen != _generation || _disposed) return;
    try {
      await _ensurePlayer();
      if (gen != _generation || _disposed) return;
      final player = _player;
      if (player == null) return;
      await player.setVolume(0);
      await player.setPlaylistMode(PlaylistMode.loop);
      await player.open(
        Media(url, httpHeaders: appleArtworkHeaders),
        play: true,
      );
      if (gen != _generation || _disposed) return;
      _watchReady(gen);
    } catch (_) {}
  }

  /// Appends [fn] to the native-op queue. Errors are swallowed per-op so
  /// the queue itself never breaks.
  Future<void> _serialized(Future<void> Function() fn) {
    final run = _tail.then((_) async {
      try {
        await fn();
      } catch (_) {}
    });
    _tail = run;
    return run;
  }

  void detach() {
    if (_refs > 0) _refs--;
    if (_refs > 0) return;
    _pauseTimer?.cancel();
    _pauseTimer = Timer(const Duration(milliseconds: 400), () {
      if (_refs == 0) unawaited(_serialized(() async {
        try {
          await _player?.pause();
        } catch (_) {}
      }));
    });
    // NOTE: no teardown timer on purpose. The player + texture live for the
    // whole app run (one idle 8MiB instance, decode paused above). Tearing
    // down mid-session destroyed the native texture while frames were in
    // flight and fail-fasted the engine.
  }

  void _watchReady(int gen) {
    _readyTimer?.cancel();
    _widthSub?.cancel();
    _unlistenRect();
    final player = _player;
    final controller = _controller;
    if (player == null || controller == null) return;

    void mark() {
      if (gen != _generation || _ready) return;
      _ready = true;
      if (_visible) _notify();
    }

    void onRect() {
      final rect = controller.rect.value;
      if (rect != null && rect.width > 1 && rect.height > 1) mark();
    }

    _rectListener = onRect;
    controller.rect.addListener(onRect);
    onRect();

    _widthSub = player.stream.width.listen((w) {
      if ((w ?? 0) > 0) mark();
    });
    _readyTimer = Timer(const Duration(milliseconds: 1200), () {
      if ((player.state.width ?? 0) > 0) mark();
    });
  }

  void _unlistenRect() {
    final listener = _rectListener;
    final controller = _controller;
    if (listener != null && controller != null) {
      controller.rect.removeListener(listener);
    }
    _rectListener = null;
  }

  Future<void> _ensurePlayer() async {
    if (_player != null && _controller != null) return;
    final player = Player(
      configuration: const PlayerConfiguration(
        muted: true,
        title: 'LastWave Artwork',
        bufferSize: 8 * 1024 * 1024,
      ),
    );
    _player = player;
    _controller = VideoController(
      player,
      configuration: const VideoControllerConfiguration(
        // Match the clips (~768px H.264) so the first frames don't force
        // a texture realloc via SetSize mid-decode.
        width: 768,
        height: 768,
        // Software decode only: media_kit defaults hwdec=auto, which on
        // Linux+Mesa tries VA-API dmabuf interop with vo=libmpv and
        // yields zero frames (still never fades; Windows D3D11-copy is
        // unaffected). These clips are ~768px H.264 — trivial for CPU.
        hwdec: 'no',
      ),
    );
    _notify();
    try {
      await _controller!.platform.future.timeout(const Duration(seconds: 6));
    } catch (_) {}
    if (!_silenced) {
      _silenced = true;
      await _silence(player);
    }
  }

  Future<void> _silence(Player player) async {
    try {
      final platform = player.platform;
      if (platform == null) return;
      final dyn = platform as dynamic;
      try {
        await dyn.setProperty('ao', 'null');
      } catch (_) {}
      try {
        await dyn.setProperty('aid', 'no');
      } catch (_) {}
      try {
        await dyn.setProperty('loop-file', 'inf');
      } catch (_) {}
      try {
        await dyn.setProperty('demuxer-lavf-o', 'extension_picky=0');
      } catch (_) {}
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _pauseTimer?.cancel();
    _readyTimer?.cancel();
    _widthSub?.cancel();
    _unlistenRect();
    // App-scoped provider: this only runs at engine shutdown. Still
    // ordered and serialized — pause, then stop, then dispose — so a
    // lingering open can never race the native teardown.
    final player = _player;
    _player = null;
    _controller = null;
    if (player != null) {
      unawaited(_serialized(() async {
        try {
          await player.pause();
        } catch (_) {}
        try {
          await player.stop();
        } catch (_) {}
        try {
          await player.dispose();
        } catch (_) {}
      }));
    }
    super.dispose();
  }
}

final animatedArtworkSessionProvider =
    ChangeNotifierProvider<AnimatedArtworkSession>((ref) {
  return AnimatedArtworkSession();
});
