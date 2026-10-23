import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/stream_models.dart';
import '../../core/storage/prefs.dart';
import '../../features/lyrics/karaoke_lyrics_view.dart';
import '../../features/lyrics/lyrics_models.dart';
import '../../features/lyrics/lyrics_repository.dart';
import '../../features/player/playback_service.dart';

// Lyrics fetch is keyed by track identity — never by the playback clock
// or duration (duration arrives late and would refetch). Position ticks
// only drive the highlight index.
final lyricsProviderOverrideProvider =
    StateProvider.autoDispose.family<String?, String>((_, _) => null);
final lyricsExcludedProvidersProvider =
    StateProvider.autoDispose.family<Set<String>, String>((_, _) => <String>{});

final waveLyricsProvider = StreamProvider.autoDispose
    .family<LyricsResult, PlayableTrack>((ref, track) {
  final repo = ref.watch(lyricsRepositoryProvider);
  final wordByWord = ref.watch(prefsProvider.select((p) => p.wordByWord));
  final defaultProviderId =
      ref.watch(prefsProvider.select((p) => p.lyricsProviderId));
  // Per-track source control (Task 9): an explicit provider pick
  // (null = follow the Settings default) plus excluded providers.
  // Watched, so switching sources refetches through a new cache key.
  final override = ref.watch(lyricsProviderOverrideProvider(track.queueKey));
  final excludes = ref.watch(lyricsExcludedProvidersProvider(track.queueKey));
  // Duration read initially; if 0 (stream loading/buffering), we listen for arrival
  // so lyrics are fetched automatically without requiring a manual refresh.
  final playback = ref.read(playbackServiceProvider);
  final initialDurationSecs = playback.current?.queueKey == track.queueKey
      ? playback.duration.inSeconds
      : 0;
  final results = StreamController<LyricsResult>();
  var disposed = false;
  // The controller is closed by the first fetch that produced content,
  // while a second fetch (the duration-arrival refetch) may still be in
  // flight. `disposed` alone does not cover that: closing here used to
  // throw "Cannot add event after closing" from a late result.
  var closed = false;
  var hasEmittedContent = false;
  void emit(LyricsResult result) {
    if (disposed || closed || results.isClosed) return;
    results.add(result);
  }

  void finish() {
    if (disposed || closed) return;
    closed = true;
    unawaited(results.close());
  }

  ref.onDispose(() {
    disposed = true;
    closed = true;
    unawaited(results.close());
  });

  void runFetch(int? secs) {
    unawaited(repo.getLyrics(
      title: track.title,
      artist: track.artist,
      album: track.album,
      durationSeconds: secs != null && secs > 0 ? secs : null,
      wordByWord: wordByWord,
      videoId: track.videoId.isNotEmpty ? track.videoId : null,
      preferredProviderId: override ?? defaultProviderId,
      excludeProviderIds: excludes,
      onPartialResult: (result) {
        if (!disposed && !result.isEmpty) {
          hasEmittedContent = true;
          emit(result);
        }
      },
    ).then((result) {
      if (!disposed) {
        if (!result.isEmpty) {
          hasEmittedContent = true;
          emit(result);
        } else if (!hasEmittedContent && (secs == null || secs <= 0)) {
          final curSecs = ref.read(playbackServiceProvider).duration.inSeconds;
          if (curSecs > 0) {
            runFetch(curSecs);
            return;
          }
          emit(result);
        } else if (!hasEmittedContent) {
          emit(result);
        }
      }
    }, onError: (Object error, StackTrace stack) {
      if (!disposed && !closed && !results.isClosed) {
        results.addError(error, stack);
      }
    }).whenComplete(() {
      if (!disposed && (hasEmittedContent || (secs != null && secs > 0))) {
        finish();
      }
    }));
  }

  runFetch(initialDurationSecs > 0 ? initialDurationSecs : null);

  if (initialDurationSecs <= 0) {
    ref.listen<int>(
      playbackServiceProvider.select((s) =>
          s.current?.queueKey == track.queueKey ? s.duration.inSeconds : 0),
      (prev, next) {
        if (!disposed && !hasEmittedContent && next > 0 && (prev == null || prev <= 0)) {
          runFetch(next);
        }
      },
    );
  }

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
  final bool isActive;

  const WaveLyricsPanel({
    super.key,
    required this.track,
    this.compact = false,
    this.showHeaderControls = true,
    this.onClose,
    this.isActive = true,
  });

  @override
  Widget build(BuildContext context) {
    return WaveKaraokeLyricsView(
      track: track,
      compact: compact,
      showHeaderControls: showHeaderControls,
      onClose: onClose,
      isActive: isActive,
    );
  }
}

