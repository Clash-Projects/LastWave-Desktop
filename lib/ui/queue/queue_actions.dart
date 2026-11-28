import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/stream_models.dart';
import '../../features/library/playlists.dart';
import '../components/buttons.dart';
import '../components/inputs.dart';

/// One upcoming queue entry paired with its exact index inside `state.queue`.
typedef IndexedQueueTrack = ({int queueIndex, PlayableTrack track});

/// Visible queue tracks starting from the currently playing track onward.
List<PlayableTrack> visibleQueueTracks(
  List<PlayableTrack> queue,
  int currentIndex,
) {
  if (queue.isEmpty) return const [];
  if (currentIndex < 0 || currentIndex >= queue.length) {
    return List<PlayableTrack>.unmodifiable(queue);
  }
  return List<PlayableTrack>.unmodifiable(queue.sublist(currentIndex));
}

/// Converts [tracks] into deduplicated [StoredTrack] rows ready for a playlist.
List<StoredTrack> queueTracksToStored(
  List<PlayableTrack> tracks, {
  int? addedAtMillis,
}) {
  final now = addedAtMillis ?? DateTime.now().millisecondsSinceEpoch;
  final seen = <String>{};
  final out = <StoredTrack>[];
  for (final t in tracks) {
    final key = '${t.title.toLowerCase()}|${t.artist.toLowerCase()}';
    if (!seen.add(key)) continue;
    out.add(
      StoredTrack(
        name: t.title,
        artist: t.artist,
        artworkUrl: t.artworkUrl,
        videoId: t.videoId,
        album: t.album,
        durationSeconds: t.duration.inSeconds,
        playbackUrl: t.playbackUrl,
        addedAtMillis: now,
      ),
    );
  }
  return List<StoredTrack>.unmodifiable(out);
}

/// Filters upcoming queue tracks case-insensitively across title, artist, and
/// album while retaining each track's real `state.queue` index.
List<IndexedQueueTrack> filterUpcomingTracks(
  List<PlayableTrack> queue,
  int currentIndex,
  String query,
) {
  if (queue.isEmpty) return const [];
  final start = currentIndex >= 0
      ? (currentIndex + 1).clamp(0, queue.length)
      : 0;
  final q = query.trim().toLowerCase();
  final out = <IndexedQueueTrack>[];
  for (var i = start; i < queue.length; i++) {
    final track = queue[i];
    if (q.isEmpty ||
        track.title.toLowerCase().contains(q) ||
        track.artist.toLowerCase().contains(q) ||
        track.album.toLowerCase().contains(q)) {
      out.add((queueIndex: i, track: track));
    }
  }
  return List<IndexedQueueTrack>.unmodifiable(out);
}

/// Generates a non-colliding playlist title so saving the queue always creates
/// a new custom playlist instead of merging into an existing or reserved one.
String uniqueQueuePlaylistTitle(
  String desired,
  Iterable<SavedPlaylist> existing,
) {
  var base = desired.trim();
  if (base.isEmpty) base = 'Queue Mix';

  final taken = <String>{
    SavedPlaylist.likedTitle.toLowerCase(),
    'liked music',
    SavedPlaylist.localTitle.toLowerCase(),
    for (final p in existing) p.title.trim().toLowerCase(),
  };

  if (!taken.contains(base.toLowerCase())) return base;

  var n = 2;
  while (taken.contains('$base ($n)'.toLowerCase())) {
    n++;
  }
  return '$base ($n)';
}

/// Snapshot of recently cleared upcoming tracks held for the 5-second Undo bar.
class QueueClearUndoState {
  final List<PlayableTrack> tracks;
  final String? expectedCurrentKey;
  final int secondsLeft;

  const QueueClearUndoState({
    required this.tracks,
    required this.expectedCurrentKey,
    required this.secondsLeft,
  });

  QueueClearUndoState copyWith({int? secondsLeft}) => QueueClearUndoState(
        tracks: tracks,
        expectedCurrentKey: expectedCurrentKey,
        secondsLeft: secondsLeft ?? this.secondsLeft,
      );
}

/// Manages the 5-second countdown for undoing `Clear` in [WaveQueuePanel].
class QueueClearUndoNotifier extends StateNotifier<QueueClearUndoState?> {
  static const int windowSeconds = 5;
  Timer? _timer;

  QueueClearUndoNotifier() : super(null);

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void recordCleared(
    List<PlayableTrack> tracks, {
    String? expectedCurrentKey,
  }) {
    _timer?.cancel();
    if (tracks.isEmpty) {
      state = null;
      return;
    }
    state = QueueClearUndoState(
      tracks: List<PlayableTrack>.unmodifiable(tracks),
      expectedCurrentKey: expectedCurrentKey,
      secondsLeft: windowSeconds,
    );
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final current = state;
      if (current == null) {
        _timer?.cancel();
        return;
      }
      final next = current.secondsLeft - 1;
      if (next <= 0) {
        dismiss();
      } else {
        state = current.copyWith(secondsLeft: next);
      }
    });
  }

  /// Consumes and clears the snapshot atomically so Undo fires at most once.
  QueueClearUndoState? takeForUndo() {
    _timer?.cancel();
    final current = state;
    state = null;
    return current;
  }

  void dismiss() {
    _timer?.cancel();
    if (state != null) {
      state = null;
    }
  }

  void expireIfTrackChanged(String? currentKey) {
    final current = state;
    if (current != null && current.expectedCurrentKey != currentKey) {
      dismiss();
    }
  }
}

final queueClearUndoProvider =
    StateNotifierProvider<QueueClearUndoNotifier, QueueClearUndoState?>(
  (_) => QueueClearUndoNotifier(),
);

/// Prompts for a playlist name and saves all [tracks] into a new playlist.
Future<({SavedPlaylist playlist, int savedCount})?> showWaveSaveQueuePlaylist(
  BuildContext context,
  WidgetRef ref,
  List<PlayableTrack> tracks,
) async {
  if (tracks.isEmpty) return null;
  final stored = queueTracksToStored(tracks);
  if (stored.isEmpty) return null;

  final existing = ref.read(playlistRepositoryProvider);
  final suggested = uniqueQueuePlaylistTitle('Queue Mix', existing);
  final controller = TextEditingController(text: suggested);

  final chosen = await showDialog<String>(
    context: context,
    builder: (context) => ContentDialog(
      title: const Text('Save queue as playlist'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Save ${stored.length} track${stored.length == 1 ? '' : 's'} into a new playlist.',
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 10),
          TextBox(
            decoration: waveInputDecoration(),
            controller: controller,
            placeholder: 'Playlist name',
            autofocus: true,
            onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
          ),
        ],
      ),
      actions: [
        WaveButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        WaveFilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  controller.dispose();

  if (chosen == null || chosen.isEmpty) return null;
  final repo = ref.read(playlistRepositoryProvider.notifier);
  final finalTitle = uniqueQueuePlaylistTitle(
    chosen,
    ref.read(playlistRepositoryProvider),
  );
  final created = await repo.createCustom(finalTitle);
  repo.applyBatch(created.id, add: stored);
  final updated = ref
      .read(playlistRepositoryProvider)
      .firstWhere((p) => p.id == created.id, orElse: () => created);
  return (playlist: updated, savedCount: stored.length);
}
