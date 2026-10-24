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
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<bool>? _bufferingSub;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<String>? _errorSub;
  Timer? _pauseTimer;
  Timer? _readyTimer;
  int _generation = 0;
  int _refs = 0;
  String _url = '';
  String _fallbackUrl = '';
  bool _ready = false;
  // URL actually opened on the native player (vs [_url], which leads
  // by up to 250ms during coalesce). Same-clip resume requires both
  // to match — otherwise a remount mid-load would hijack the pending
  // new-clip open and latch ready for the wrong clip.
  String _openedUrl = '';
  bool _visible = false;
  bool _silenced = false;
  // True only while paused solely because the window is minimized or
  // tray-hidden. Resume on restore fires exclusively on this flag — user
  // pauses, detach pauses, and track-change reloads never resume through
  // it. Merely unfocused (side-by-side) never sets it.
  bool _pausedForBackground = false;
  // Serializes native ops (open/stop/dispose): each waits for the previous.
  Future<void> _tail = Future.value();

  VideoController? get controller => _controller;
  String get url => _url;
  bool get ready => _ready;

  bool isReadyFor(String url) =>
      url.isNotEmpty &&
      (url == _url || url == _openedUrl) &&
      _ready &&
      _visible;

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

  void attach(String url, {String fallbackUrl = ''}) {
    _pauseTimer?.cancel();
    _refs++;
    unawaited(open(url, fallbackUrl: fallbackUrl));
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

  /// Window minimize/restore from WindowLifecycle. Pauses decode while the
  /// window is minimized or tray-hidden; resumes on restore only when
  /// this pause caused it. Pause/play are the lightest native ops — no
  /// stop/dispose, no texture teardown (see class docs) — serialized like
  /// every native op, never throws. Autoplay advancing tracks while
  /// hidden still opens clips (attach path); the open guards below
  /// re-pause them so nothing decodes invisibly. Side-by-side
  /// (unfocused but visible) never calls this.
  void setBackgrounded(bool backgrounded) {
    if (_disposed) return;
    if (!backgrounded) {
      if (!_pausedForBackground) return;
      _pausedForBackground = false;
      unawaited(
        _serialized(() async {
          try {
            // Detached tiles stay paused: detach's own timer owns them,
            // and resuming a dead surface would flash black on return.
            if (_refs > 0 && _player != null) {
              await _ensureLoopProperties(_player!);
              if (_player!.state.completed) {
                await _player!.seek(Duration.zero);
              }
              await _player!.play();
            }
          } catch (_) {}
        }),
      );
      return;
    }
    if (_refs == 0 || _pausedForBackground) return;
    _pausedForBackground = true;
    unawaited(
      _serialized(() async {
        try {
          await _player?.pause();
        } catch (_) {}
      }),
    );
  }

  Future<void> open(String url, {String fallbackUrl = ''}) async {
    if (url.isEmpty || _disposed) return;
    _fallbackUrl = fallbackUrl;
    if (url == _url && _player != null) {
      // New clip still loading (coalesce window): the in-flight open
      // owns it and plays on completion — don't disturb it.
      if (url != _openedUrl &&
          (_fallbackUrl.isEmpty || _fallbackUrl != _openedUrl)) {
        return;
      }
      // Same-clip resume (same-album track switch, Now Playing re-entry,
      // visualizer toggle): the decoded frame is already in the texture
      // (detach only pauses, never stops). Keep [_ready] true when already
      // ready so same-album track changes never flash or re-fade.
      final alreadyReady = _ready && (_player!.state.width ?? 0) > 0;
      await _serialized(() async {
        try {
          if (_player != null) {
            await _ensureLoopProperties(_player!);
            if (_player!.state.completed) {
              await _player!.seek(Duration.zero);
            }
            if (!_pausedForBackground) {
              await _player!.play();
            } else {
              await _player!.pause();
            }
          }
        } catch (_) {}
      });
      if (alreadyReady) {
        if (_visible) _notify();
        return;
      }
      _watchReady(_generation);
      return;
    }
    final gen = ++_generation;
    _url = url;
    _ready = false;
    _cancelReadyWatchers();
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
      // Pause any previous stream before loadfile so stale position ticks
      // from an outgoing clip cannot fire while the new stream opens.
      try {
        await player.pause();
      } catch (_) {}
      // IMPORTANT: PlaylistMode.single sets mpv `loop-file=yes` so the file
      // loops seamlessly inside the demuxer buffer without closing/reopening
      // the stream on each pass (PlaylistMode.loop sets `loop-file=no`, which
      // causes single-item remote streams to stop at EOF).
      await player.setPlaylistMode(PlaylistMode.single);
      await _ensureLoopProperties(player);

      // Prefer a locally cached .mp4 file on disk when available; otherwise
      // stream over HTTP(S) and warm the disk cache in the background.
      final cachedFile = CanvasDiskCache.instance.peekFilePath(url);
      final playTarget = cachedFile ?? url;
      if (cachedFile == null) {
        unawaited(CanvasDiskCache.instance.warm(url));
      }

      await player.open(
        Media(
          playTarget,
          httpHeaders:
              cachedFile == null ? headersForAnimatedArtworkUrl(url) : null,
        ),
        play: true,
      );
      await _ensureLoopProperties(player);
      if (gen != _generation || _disposed) return;
      if (_pausedForBackground) {
        // Autoplay advanced while hidden: keep the new clip paused
        // (flag stays set so restore resumes into it).
        try {
          await player.pause();
        } catch (_) {}
      }
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
    // whole app run (one idle instance, decode paused above). Tearing
    // down mid-session destroyed the native texture while frames were in
    // flight and fail-fasted the engine.
  }

  void _cancelReadyWatchers() {
    _readyTimer?.cancel();
    _readyTimer = null;
    _widthSub?.cancel();
    _widthSub = null;
    _positionSub?.cancel();
    _positionSub = null;
    _bufferingSub?.cancel();
    _bufferingSub = null;
  }

  /// Waits until the newly opened clip has genuinely decoded its first frames,
  /// finished initial buffering, and begun advancing its playhead before
  /// latching [_ready] = true.
  ///
  /// Never relies on `controller.rect` (which is pre-allocated at 384x384 on
  /// controller creation before any video frame is decoded) or a blind timer
  /// (which used to fire while the stream was still downloading, exposing a
  /// black video surface before playback started).
  void _watchReady(int gen) {
    _cancelReadyWatchers();
    final player = _player;
    final controller = _controller;
    if (player == null || controller == null) return;

    Duration? anchorPos;

    void mark() {
      if (gen != _generation || _ready || _disposed) return;
      _cancelReadyWatchers();
      _ready = true;
      if (kDebugMode) {
        debugPrint(
          '[motion] ready ${player.state.width}x${player.state.height} $_openedUrl',
        );
      }
      if (_visible) _notify();
    }

    void scheduleMark(Duration settleDelay) {
      if (gen != _generation || _ready || _disposed) return;
      if (_readyTimer?.isActive == true) return;
      _readyTimer = Timer(settleDelay, () {
        _readyTimer = null;
        if (gen != _generation || _ready || _disposed) return;
        final w = player.state.width ?? 0;
        final h = player.state.height ?? 0;
        if (w <= 0 || h <= 0 || player.state.buffering) return;
        mark();
      });
    }

    void evaluateProgress(Duration pos) {
      if (gen != _generation || _ready || _disposed) return;
      if (player.state.buffering) {
        _readyTimer?.cancel();
        _readyTimer = null;
        return;
      }
      final w = player.state.width ?? 0;
      final h = player.state.height ?? 0;
      if (w <= 0 || h <= 0 || !player.state.playing) {
        if (pos == Duration.zero) {
          anchorPos = Duration.zero;
        }
        return;
      }

      if (anchorPos == null) {
        if (pos <= const Duration(milliseconds: 1500)) {
          anchorPos = pos;
          if (pos >= const Duration(milliseconds: 90)) {
            scheduleMark(const Duration(milliseconds: 90));
          }
        }
        return;
      }

      if (pos < anchorPos!) {
        anchorPos = pos;
      }
      if (pos > anchorPos! && pos >= const Duration(milliseconds: 50)) {
        scheduleMark(const Duration(milliseconds: 80));
      } else if (pos >= const Duration(milliseconds: 120) &&
          pos <= const Duration(milliseconds: 1500)) {
        scheduleMark(const Duration(milliseconds: 90));
      }
    }

    _positionSub = player.stream.position.listen(evaluateProgress);

    _bufferingSub = player.stream.buffering.listen((buffering) {
      if (gen != _generation || _ready || _disposed) return;
      if (buffering) {
        _readyTimer?.cancel();
        _readyTimer = null;
      } else {
        evaluateProgress(player.state.position);
      }
    });

    _widthSub = player.stream.width.listen((w) {
      if (gen != _generation || _ready || _disposed) return;
      if ((w ?? 0) > 0 && !player.state.buffering) {
        evaluateProgress(player.state.position);
      }
    });
  }

  Future<void> _ensurePlayer() async {
    if (_player != null && _controller != null) return;
    // Defensive + idempotent: media_kit's libmpv dlopen normally comes from
    // PlaybackService.ensurePlayer, but this session owns its own Player()
    // and must not depend on that having run first.
    MediaKit.ensureInitialized();
    final player = Player(
      configuration: const PlayerConfiguration(
        muted: true,
        title: 'LastWave Artwork',
        // 16 MiB holds an entire Apple fMP4, Tidal 1280x1280 MP4, or
        // Community Canvas loop in the demuxer back-buffer so `loop-file=inf`
        // seeks back to 0 purely in memory without re-downloading.
        bufferSize: 16 * 1024 * 1024,
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
    _bindLoopWatchdogs(player);
    _notify();
    try {
      await _controller!.platform.future.timeout(const Duration(seconds: 6));
    } catch (_) {}
    if (!_silenced) {
      _silenced = true;
      await _silence(player);
    }
  }

  void _bindLoopWatchdogs(Player player) {
    _completedSub?.cancel();
    _errorSub?.cancel();

    // Safety net: if a stream ever emits EOF (`completed == true`) despite
    // `loop-file=inf` (e.g. non-byterange HLS playlists), immediately seek
    // back to 0 and resume so the canvas animation never stops.
    _completedSub = player.stream.completed.listen((completed) {
      if (!completed || _disposed || _refs == 0 || _pausedForBackground) return;
      final gen = _generation;
      final activeUrl = _openedUrl;
      unawaited(
        _serialized(() async {
          if (_disposed ||
              gen != _generation ||
              _refs == 0 ||
              _pausedForBackground) {
            return;
          }
          final p = _player;
          if (p == null) return;
          try {
            await _ensureLoopProperties(p);
            await p.seek(Duration.zero);
            await p.play();
          } catch (_) {
            if (activeUrl.isNotEmpty) {
              try {
                final cachedFile =
                    CanvasDiskCache.instance.peekFilePath(activeUrl);
                final playTarget = cachedFile ?? activeUrl;
                await p.open(
                  Media(
                    playTarget,
                    httpHeaders: cachedFile == null
                        ? headersForAnimatedArtworkUrl(activeUrl)
                        : null,
                  ),
                  play: true,
                );
                await _ensureLoopProperties(p);
              } catch (_) {}
            }
          }
        }),
      );
    });

    // Fallback URL support: if primary URL fails to decode/open and an
    // alternate URL was provided, switch to the fallback stream.
    _errorSub = player.stream.error.listen((_) {
      if (_disposed || _ready) return;
      final alt = _fallbackUrl;
      if (alt.isEmpty || alt == _openedUrl) return;
      final gen = _generation;
      unawaited(
        _serialized(() => _openLocked(alt, gen)),
      );
    });
  }

  Future<void> _ensureLoopProperties(Player player) async {
    try {
      final platform = player.platform;
      if (platform == null) return;
      final dyn = platform as dynamic;
      try {
        await dyn.setProperty('loop-file', 'inf');
      } catch (_) {}
      try {
        await dyn.setProperty('loop-playlist', 'inf');
      } catch (_) {}
      try {
        await dyn.setProperty('keep-open', 'no');
      } catch (_) {}
    } catch (_) {}
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
        await dyn.setProperty('cache', 'yes');
      } catch (_) {}
      try {
        await dyn.setProperty('demuxer-max-bytes', '${16 * 1024 * 1024}');
      } catch (_) {}
      try {
        await dyn.setProperty('demuxer-max-back-bytes', '${16 * 1024 * 1024}');
      } catch (_) {}
      try {
        await dyn.setProperty('loop-file', 'inf');
      } catch (_) {}
      try {
        await dyn.setProperty('loop-playlist', 'inf');
      } catch (_) {}
      try {
        await dyn.setProperty('keep-open', 'no');
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
    _cancelReadyWatchers();
    _completedSub?.cancel();
    _errorSub?.cancel();
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
