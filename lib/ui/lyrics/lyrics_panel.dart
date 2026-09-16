import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/stream_models.dart';
import '../../features/lyrics/karaoke_lyrics_view.dart';
import '../../features/lyrics/lyrics_models.dart';
import '../../features/lyrics/lyrics_repository.dart';
import '../../features/player/playback_service.dart';

// Lyrics fetch is keyed by track identity — never by the playback clock
// or duration (duration arrives late and would refetch). Position ticks
// only drive the highlight index.
final waveLyricsProvider = StreamProvider.autoDispose
    .family<LyricsResult, String>((ref, key) {
  final current = ref.watch(
      playbackServiceProvider.select((s) => s.current));
  if (current == null || current.queueKey != key) {
    return Stream.value(const LyricsResult.empty());
  }
  final repo = ref.watch(lyricsRepositoryProvider);
  // Duration read once (no watch) so late duration arrival doesn't refetch.
  final durationSecs =
      ref.read(playbackServiceProvider).duration.inSeconds;
  final results = StreamController<LyricsResult>();
  var disposed = false;
  ref.onDispose(() {
    disposed = true;
    unawaited(results.close());
  });
  unawaited(repo.getLyrics(
    title: current.title,
    artist: current.artist,
    album: current.album,
    durationSeconds: durationSecs > 0 ? durationSecs : null,
    onPartialResult: (result) {
      if (!disposed) results.add(result);
    },
  ).then((result) {
    if (!disposed) results.add(result);
  }, onError: (Object error, StackTrace stack) {
    if (!disposed) results.addError(error, stack);
  }).whenComplete(() {
    if (!disposed) unawaited(results.close());
  }));
  return results.stream;
});

/// Premium Apple Music Karaoke lyrics reading experience.
///
/// Backed by [WaveKaraokeLyricsView] with word-level progressive syllable wipe,
/// blur falloff, active line pop, timing offset controls, and autoscroll.
class WaveLyricsPanel extends StatelessWidget {
  final PlayableTrack track;
  final bool compact;
  final bool showHeaderControls;
  final VoidCallback? onClose;

  const WaveLyricsPanel({
    super.key,
    required this.track,
    this.compact = false,
    this.showHeaderControls = true,
    this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return WaveKaraokeLyricsView(
      track: track,
      compact: compact,
      showHeaderControls: showHeaderControls,
      onClose: onClose,
    );
  }
}

