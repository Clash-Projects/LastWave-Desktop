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
class AnimatedArtworkSession extends ChangeNotifier {
  Player? _player;
  VideoController? _controller;
  StreamSubscription<int?>? _widthSub;
  Timer? _pauseTimer;
  Timer? _disposeTimer;
  Timer? _readyTimer;
  VoidCallback? _rectListener;
  int _generation = 0;
  int _refs = 0;
  String _url = '';
  bool _ready = false;
  bool _visible = false;
  bool _silenced = false;

  VideoController? get controller => _controller;
  String get url => _url;
  bool get ready => _ready;

  bool isReadyFor(String url) =>
      url.isNotEmpty && url == _url && _ready && _visible;

  void attach(String url) {
    _pauseTimer?.cancel();
    _disposeTimer?.cancel();
    _refs++;
    unawaited(open(url));
  }

  /// Video widget is in the tree. Combined with [_ready] this fades the still.
  void showSurface() {
    if (_visible) return;
    _visible = true;
    if (_ready) notifyListeners();
  }

  /// Now Playing left; keep the player but cover with the still again.
  void hideSurface() {
    _visible = false;
  }

  Future<void> open(String url) async {
    if (url.isEmpty) return;
    if (url == _url && _player != null) {
      await _player!.play();
      if (_ready) notifyListeners();
      return;
    }
    final gen = ++_generation;
    _url = url;
    _ready = false;
    notifyListeners();
    try {
      await _ensurePlayer();
      if (gen != _generation) return;
      await _player!.setVolume(0);
      await _player!.setPlaylistMode(PlaylistMode.loop);
      await _player!.open(
        Media(url, httpHeaders: appleArtworkHeaders),
        play: true,
      );
      if (gen != _generation) return;
      _watchReady(gen);
    } catch (_) {}
  }

  void detach() {
    if (_refs > 0) _refs--;
    if (_refs > 0) return;
    _pauseTimer?.cancel();
    _pauseTimer = Timer(const Duration(milliseconds: 400), () {
      if (_refs == 0) unawaited(_player?.pause());
    });
    // Full teardown after 30s unreferenced: drops the second libmpv
    // instance (8MiB buffer + video decode pipeline), which otherwise
    // lived forever — the provider is app-scoped so dispose() never
    // runs. Re-attach recreates on demand (stills cover the gap).
    _disposeTimer?.cancel();
    _disposeTimer = Timer(const Duration(seconds: 30), () {
      if (_refs != 0) return;
      _teardownPlayer();
    });
  }

  void _teardownPlayer() {
    // Invalidate in-flight open()/watchers.
    _generation++;
    _readyTimer?.cancel();
    _widthSub?.cancel();
    _unlistenRect();
    final player = _player;
    _player = null;
    _controller = null;
    _ready = false;
    notifyListeners();
    if (player != null) {
      unawaited(player.stop().whenComplete(player.dispose));
    }
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
      if (_visible) notifyListeners();
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
        width: 720,
        height: 720,
      ),
    );
    notifyListeners();
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
    _pauseTimer?.cancel();
    _disposeTimer?.cancel();
    _readyTimer?.cancel();
    _widthSub?.cancel();
    _unlistenRect();
    final player = _player;
    _player = null;
    _controller = null;
    if (player != null) {
      unawaited(player.stop().whenComplete(player.dispose));
    }
    super.dispose();
  }
}

final animatedArtworkSessionProvider =
    ChangeNotifierProvider<AnimatedArtworkSession>((ref) {
  return AnimatedArtworkSession();
});
