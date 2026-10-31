import 'dart:async';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/audio/stream_models.dart';
import '../../features/innertube/innertube_api.dart';
import '../../features/player/playback_service.dart';
import '../components/buttons.dart' show LWTooltip;
import '../components/select.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

const _videoExtensions = {'mp4', 'mkv', 'webm', 'mov', 'm4v'};

/// Opens the current track's video on its own player, muted, and keeps
/// it near the audio position. Closing this pane disposes only that
/// player — audio keeps going. A missing URL stays inside this pane.
class SyncedMusicVideoPane extends ConsumerStatefulWidget {
  final bool fullscreen;
  final VoidCallback onClose;
  final VoidCallback onToggleFullscreen;

  const SyncedMusicVideoPane({
    super.key,
    required this.fullscreen,
    required this.onClose,
    required this.onToggleFullscreen,
  });

  @override
  ConsumerState<SyncedMusicVideoPane> createState() =>
      _SyncedMusicVideoPaneState();
}

class _SyncedMusicVideoPaneState extends ConsumerState<SyncedMusicVideoPane> {
  Player? _player;
  VideoController? _controller;
  Timer? _sync;
  List<MusicVideoStream> _options = const [];
  int _selected = 0;
  bool _loading = true;
  String? _error;
  String _trackKey = '';
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(_load);
  }

  @override
  void dispose() {
    _sync?.cancel();
    final player = _player;
    _player = null;
    _controller = null;
    if (player != null) {
      unawaited(() async {
        try {
          await player.stop();
        } catch (_) {}
        try {
          await player.dispose();
        } catch (_) {}
      }());
    }
    super.dispose();
  }

  Future<void> _ensurePlayer() async {
    if (_player != null && _controller != null) return;
    MediaKit.ensureInitialized();
    final player = Player(
      configuration: const PlayerConfiguration(
        muted: true,
        title: 'LastWave Video',
        bufferSize: 8 * 1024 * 1024,
      ),
    );
    _player = player;
    _controller = VideoController(player);
    try {
      await player.setVolume(0);
    } catch (_) {}
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final track = ref.read(playbackServiceProvider).current;
    if (!mounted || generation != _generation) return;
    if (track == null) {
      await _haltVideo();
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = 'Nothing is playing.';
        _options = const [];
      });
      return;
    }
    final key = '${track.queueKey}|${track.videoId}|${track.playbackUrl}';
    if (key == _trackKey && _options.isNotEmpty && _error == null) return;
    _trackKey = key;
    setState(() {
      _loading = true;
      _error = null;
    });

    final local = _localVideo(track);
    List<MusicVideoStream> options = const [];
    if (local != null) {
      options = [local];
    } else if (track.videoId.isEmpty) {
      await _haltVideo();
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = 'This track has no video.';
        _options = const [];
      });
      return;
    } else {
      try {
        options = await ref.read(innerTubeProvider).resolveMusicVideo(track.videoId);
      } catch (_) {
        options = const [];
      }
    }
    if (!mounted || generation != _generation) return;
    if (options.isEmpty) {
      await _haltVideo();
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = 'Couldn’t find a video stream for this track.';
        _options = const [];
      });
      return;
    }
    final selected = _defaultQuality(options);
    setState(() {
      _options = options;
      _selected = selected;
      _loading = false;
      _error = null;
    });
    await _open(selected, generation);
  }

  Future<void> _open(int index, int generation) async {
    if (index < 0 || index >= _options.length) return;
    try {
      await _ensurePlayer();
      if (!mounted || generation != _generation) return;
      final option = _options[index];
      final audio = ref.read(playbackServiceProvider);
      final player = _player;
      if (player == null) return;
      await player.open(
        Media(option.url, httpHeaders: option.requestHeaders),
        play: false,
      );
      await player.setVolume(0);
      await player.seek(audio.position);
      if (audio.isPlaying) await player.play();
      _startSync();
      if (mounted && generation == _generation) {
        setState(() {
          _selected = index;
          _error = null;
          _loading = false;
        });
      }
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = 'Couldn’t open the video. Audio keeps playing.';
      });
    }
  }

  Future<void> _haltVideo() async {
    try {
      await _player?.pause();
    } catch (_) {}
  }

  void _startSync() {
    _sync?.cancel();
    _sync = Timer.periodic(const Duration(milliseconds: 400), (_) {
      final player = _player;
      if (player == null || !mounted) return;
      final audio = ref.read(playbackServiceProvider);
      final current = audio.current;
      final key = current == null
          ? ''
          : '${current.queueKey}|${current.videoId}|${current.playbackUrl}';
      if (key != _trackKey) {
        unawaited(_load());
        return;
      }
      final drift = (player.state.position - audio.position).inMilliseconds.abs();
      if (drift > 450) {
        unawaited(player.seek(audio.position));
      }
      final videoPlaying = player.state.playing;
      if (audio.isPlaying && !videoPlaying) {
        unawaited(player.play());
      } else if (!audio.isPlaying && videoPlaying) {
        unawaited(player.pause());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String>(
      playbackServiceProvider.select((s) {
        final t = s.current;
        if (t == null) return '';
        return '${t.queueKey}|${t.videoId}|${t.playbackUrl}';
      }),
      (previous, next) {
        if (previous == next) return;
        unawaited(_load());
      },
    );

    final dark = waveIsDark(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF0C0C0C),
        borderRadius: widget.fullscreen ? BorderRadius.zero : WaveRadius.heroRadius,
        border: widget.fullscreen
            ? null
            : Border.all(color: waveDivider(context)),
      ),
      child: ClipRRect(
        borderRadius: widget.fullscreen ? BorderRadius.zero : WaveRadius.heroRadius,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _bar(dark),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _bar(bool dark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Row(
        children: [
          Text('Music video', style: WaveType.trackTitle.copyWith(fontSize: 13)),
          const SizedBox(width: 12),
          if (_options.length > 1)
            SizedBox(
              width: 160,
              child: WaveSelect<int>(
                value: _selected,
                expanded: true,
                options: [
                  for (var i = 0; i < _options.length; i++)
                    WaveSelectOption(value: i, label: _options[i].label),
                ],
                onChanged: (index) => unawaited(_open(index, _generation)),
              ),
            )
          else if (_options.length == 1)
            Text(
              _options.first.label,
              style: WaveType.meta.copyWith(
                color: dark ? WaveColors.textSecondary : WaveColors.lightTextSecondary,
              ),
            ),
          const Spacer(),
          LWTooltip(
            message: widget.fullscreen ? 'Exit fullscreen' : 'Fullscreen',
            child: IconButton(
              icon: Icon(
                widget.fullscreen ? FluentIcons.back_to_window : FluentIcons.full_screen,
                size: 14,
              ),
              onPressed: widget.onToggleFullscreen,
            ),
          ),
          LWTooltip(
            message: 'Close video',
            child: IconButton(
              icon: const Icon(WaveIcons.close, size: 14),
              onPressed: widget.onClose,
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: ProgressRing());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: WaveType.body.copyWith(color: const Color(0xFFE8E8E8)),
              ),
              const SizedBox(height: 12),
              Button(
                onPressed: () {
                  _trackKey = '';
                  unawaited(_load());
                },
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
    }
    final controller = _controller;
    if (controller == null) return const SizedBox.expand();
    return Video(
      controller: controller,
      controls: NoVideoControls,
      fill: const Color(0xFF000000),
      fit: BoxFit.contain,
      wakelock: false,
      pauseUponEnteringBackgroundMode: false,
      resumeUponEnteringForegroundMode: false,
    );
  }
}

MusicVideoStream? _localVideo(PlayableTrack track) {
  final path = track.playbackUrl;
  if (path.isEmpty) return null;
  final ext = path.split('.').last.toLowerCase();
  if (!_videoExtensions.contains(ext)) return null;
  if (!File(path).existsSync()) return null;
  return MusicVideoStream(
    label: 'File',
    url: Uri.file(path).toString(),
    mimeType: 'video/$ext',
  );
}

int _defaultQuality(List<MusicVideoStream> options) {
  var best = 0;
  var bestScore = 1 << 30;
  for (var i = 0; i < options.length; i++) {
    final height = options[i].height;
    if (height <= 0) return i;
    final weighted = (height - 720).abs() + (height > 720 ? 180 : 0);
    if (weighted < bestScore) {
      bestScore = weighted;
      best = i;
    }
  }
  return best;
}
