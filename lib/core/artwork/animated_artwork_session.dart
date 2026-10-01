import 'dart:async';
import 'dart:io';

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
  // URL actually opened on the native player (vs [_url], which leads
  // by up to 250ms during coalesce). Same-clip resume requires both
  // to match — otherwise a remount mid-load would hijack the pending
  // new-clip open and latch ready for the wrong clip.
  String _openedUrl = '';
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
  /// Notifies: watchers gate the fading sleeve on `isReadyFor`, which
  /// includes [_visible] — without this the sleeve stays transparent
  /// after the video unmounts and the tile sits black forever.
  void hideSurface() {
    if (!_visible) return;
    _visible = false;
    _notify();
  }

  Future<void> open(String url) async {
    if (url.isEmpty || _disposed) return;
    if (url == _url && _player != null) {
      // New clip still loading (coalesce window): the in-flight open
      // owns it and plays on completion — don't disturb it.
      if (url != _openedUrl) return;
      // Same-clip resume (visualizer toggle, same-album skip):
      // playback restarts, so the ready latch must reset — otherwise
      // the sleeve (gated on motionReady) stays transparent through
      // black reload frames. Re-armed short: resume renders in a few
      // hundred ms, and staleness is impossible (no synchronous mark,
      // no width replay — timer only).
      await _serialized(() async {
        try {
          await _player?.play();
        } catch (_) {}
      });
      _ready = false;
      _notify();
      _watchReady(++_generation,
          timeout: const Duration(milliseconds: 500),
          immediate: false,
          watchWidth: false);
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
      _openedUrl = url;
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
      if (_refs == 0) {
        unawaited(
          _serialized(() async {
            try {
              await _player?.pause();
            } catch (_) {}
          }),
        );
      }
    });
    // NOTE: no teardown timer on purpose. The player + texture live for the
    // whole app run (one idle 8MiB instance, decode paused above). Tearing
    // down mid-session destroyed the native texture while frames were in
    // flight and fail-fasted the engine.
  }

  void _watchReady(int gen,
      {Duration timeout = const Duration(milliseconds: 1200),
      bool immediate = true,
      bool watchWidth = true}) {
    _readyTimer?.cancel();
    _widthSub?.cancel();
    _unlistenRect();
    final player = _player;
    final controller = _controller;
    if (player == null || controller == null) return;

    void mark() {
      if (gen != _generation || _ready) return;
      _ready = true;
      if (kDebugMode) {
        // Perf attribution for motion-art jank: resolution + height
        // decide decode/upload cost (a 1080p+ clip explains 25ms+
        // raster that no widget-layer fix can move).
        debugPrint(
            '[motion] ready ${player.state.width}x${player.state.height} $_url');
      }
      if (_visible) _notify();
    }

    void onRect() {
      final rect = controller.rect.value;
      if (rect != null && rect.width > 1 && rect.height > 1) mark();
    }

    _rectListener = onRect;
    controller.rect.addListener(onRect);
    if (immediate) onRect();

    if (watchWidth) {
      _widthSub = player.stream.width.listen((w) {
        if ((w ?? 0) > 0) mark();
      });
    }
    _readyTimer = Timer(timeout, () {
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
      configuration: VideoControllerConfiguration(
        // Fixed output size avoids a texture realloc via SetSize on
        // the first frames (the surface later snaps to stream-native
        // on video params, so this is first-frame stability only).
        width: 384,
        height: 384,
        // CPU presentation on Linux: media_kit's H/W path renders in
        // an isolated EGL context shared with Flutter's ("H/W
        // rendering with isolated EGL context" in the log), and the
        // per-frame cross-context sync stalled raster to ~25ms on
        // Mesa/RADV at 120Hz. The sw path uploads pixel buffers in
        // Flutter's own context — no second context, no fence stalls.
        // Decode stays software either way (hwdec pin below).
        // Windows/macOS keep H/W (D3D11-copy/METAL are healthy there).
        enableHardwareAcceleration: !Platform.isLinux,
        // Software decode only: media_kit defaults hwdec=auto, which on
        // Linux+Mesa tries VA-API dmabuf interop with vo=libmpv and
        // yields zero frames (still never fades; Windows D3D11-copy is
        // unaffected). These clips are trivial for CPU.
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
      unawaited(
        _serialized(() async {
          try {
            await player.pause();
          } catch (_) {}
          try {
            await player.stop();
          } catch (_) {}
          try {
            await player.dispose();
          } catch (_) {}
        }),
      );
    }
    super.dispose();
  }
}

final animatedArtworkSessionProvider =
    ChangeNotifierProvider<AnimatedArtworkSession>((ref) {
      return AnimatedArtworkSession();
    });
