import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/stream_models.dart';
import '../../features/library/playlists.dart';
import '../components/buttons.dart';
import '../components/inputs.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

/// One upcoming queue entry paired with its exact index inside `state.queue`.
typedef IndexedQueueTrack = ({int queueIndex, PlayableTrack track});

/// Normalized dedupe key shared with [PlaylistRepository].
String storedTrackKey(StoredTrack track) =>
    '${track.name.toLowerCase()}|${track.artist.toLowerCase()}';

/// Result returned after saving/adding queued tracks to a new or existing playlist.
class QueueSaveResult {
  final SavedPlaylist playlist;
  final int addedCount;
  final int totalCount;
  final bool createdNew;

  const QueueSaveResult({
    required this.playlist,
    required this.addedCount,
    required this.totalCount,
    required this.createdNew,
  });
}

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

/// Filters [playlists] to editable user targets (excludes Liked Songs & auto Local scan).
List<SavedPlaylist> editableQueuePlaylists(Iterable<SavedPlaylist> playlists) =>
    playlists
        .where((p) => !p.isLikedSongs && !p.isLocal)
        .toList(growable: false);

/// Counts how many unique tracks in [tracks] are not already present in [playlist].
int countNewTracksForPlaylist(
  SavedPlaylist playlist,
  Iterable<StoredTrack> tracks,
) {
  final seen = playlist.tracks.map(storedTrackKey).toSet();
  var added = 0;
  for (final t in tracks) {
    if (seen.add(storedTrackKey(t))) {
      added++;
    }
  }
  return added;
}

/// Generates a non-colliding playlist title so creating a new playlist never
/// merges into an existing or reserved one.
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

/// Creates a brand-new custom playlist with [tracks] atomically.
Future<QueueSaveResult> saveQueueToNewPlaylist(
  PlaylistRepository repo,
  List<SavedPlaylist> Function() readPlaylists, {
  required String title,
  required List<StoredTrack> tracks,
}) async {
  final finalTitle = uniqueQueuePlaylistTitle(title, readPlaylists());
  final created = await repo.createCustom(finalTitle);
  repo.applyBatch(created.id, add: tracks);
  final updated = readPlaylists()
      .firstWhere((p) => p.id == created.id, orElse: () => created);
  return QueueSaveResult(
    playlist: updated,
    addedCount: tracks.length,
    totalCount: tracks.length,
    createdNew: true,
  );
}

/// Appends only non-duplicate [tracks] from queue into an existing [target] playlist.
QueueSaveResult addQueueToExistingPlaylist(
  PlaylistRepository repo,
  List<SavedPlaylist> Function() readPlaylists, {
  required SavedPlaylist target,
  required List<StoredTrack> tracks,
}) {
  final added = countNewTracksForPlaylist(target, tracks);
  if (added > 0) {
    repo.applyBatch(target.id, add: tracks);
  }
  final updated = readPlaylists()
      .firstWhere((p) => p.id == target.id, orElse: () => target);
  return QueueSaveResult(
    playlist: updated,
    addedCount: added,
    totalCount: tracks.length,
    createdNew: false,
  );
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

sealed class _QueuePlaylistChoice {
  const _QueuePlaylistChoice();
}

class _CreateNewQueuePlaylist extends _QueuePlaylistChoice {
  final String title;
  const _CreateNewQueuePlaylist(this.title);
}

class _PickExistingQueuePlaylist extends _QueuePlaylistChoice {
  final SavedPlaylist playlist;
  const _PickExistingQueuePlaylist(this.playlist);
}

/// Prompts to save [tracks] into a new playlist or add them to an existing one.
Future<QueueSaveResult?> showWaveSaveQueuePlaylist(
  BuildContext context,
  WidgetRef ref,
  List<PlayableTrack> tracks,
) async {
  if (tracks.isEmpty) return null;
  final stored = queueTracksToStored(tracks);
  if (stored.isEmpty) return null;

  final allPlaylists = ref.read(playlistRepositoryProvider);
  final existingTargets = editableQueuePlaylists(allPlaylists);
  final suggested = uniqueQueuePlaylistTitle('Queue Mix', allPlaylists);
  final controller = TextEditingController(text: suggested);

  _QueuePlaylistChoice? choice;
  try {
    choice = await showDialog<_QueuePlaylistChoice>(
      context: context,
      builder: (context) => ContentDialog(
        title: const Text('Add queue to playlist'),
        constraints: const BoxConstraints(maxWidth: 420),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
            Text(
              'Save ${stored.length} track${stored.length == 1 ? '' : 's'} into a new playlist or add to an existing one.',
              style: WaveType.meta.copyWith(
                color: waveTextSecondary(context),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'NEW PLAYLIST',
              style: WaveType.overline.copyWith(
                fontSize: 9.5,
                color: waveTextTertiary(context),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: TextBox(
                    decoration: waveInputDecoration(),
                    controller: controller,
                    placeholder: 'Playlist name',
                    autofocus: true,
                    onSubmitted: (v) {
                      final clean = v.trim();
                      if (clean.isNotEmpty) {
                        Navigator.of(context)
                            .pop(_CreateNewQueuePlaylist(clean));
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: controller,
                  builder: (context, value, _) {
                    final clean = value.text.trim();
                    return WaveFilledButton(
                      onPressed: clean.isEmpty
                          ? null
                          : () => Navigator.of(context)
                              .pop(_CreateNewQueuePlaylist(clean)),
                      child: const Text('Create'),
                    );
                  },
                ),
              ],
            ),
            if (existingTargets.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(
                'ADD TO EXISTING (${existingTargets.length})',
                style: WaveType.overline.copyWith(
                  fontSize: 9.5,
                  color: waveTextTertiary(context),
                ),
              ),
              const SizedBox(height: 6),
              Container(
                decoration: BoxDecoration(
                  color: waveSurfaceOverlay(context).withValues(alpha: 0.45),
                  borderRadius: WaveRadius.controlsRadius,
                  border: Border.all(color: waveOutlineSoft(context)),
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 210),
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    itemCount: existingTargets.length,
                    itemBuilder: (context, i) {
                      final p = existingTargets[i];
                      final newCount = countNewTracksForPlaylist(p, stored);
                      final trackWord =
                          p.tracks.length == 1 ? 'track' : 'tracks';
                      final status =
                          newCount == 0 ? 'already added' : '+$newCount new';
                      return MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: ListTile.selectable(
                          shape: RoundedRectangleBorder(
                            borderRadius: WaveRadius.controlsRadius,
                          ),
                          leading: const Icon(WaveIcons.playlists, size: 15),
                          title: Text(
                            p.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${p.tracks.length} $trackWord · $status',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          selectionMode: ListTileSelectionMode.single,
                          selected: false,
                          onPressed: () => Navigator.of(context)
                              .pop(_PickExistingQueuePlaylist(p)),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
            ],
          ),
        ),
        actions: [
          WaveButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  } finally {
    controller.dispose();
  }

  if (choice == null) return null;
  final repo = ref.read(playlistRepositoryProvider.notifier);
  List<SavedPlaylist> readPlaylists() => ref.read(playlistRepositoryProvider);

  return switch (choice) {
    _CreateNewQueuePlaylist(:final title) => saveQueueToNewPlaylist(
        repo,
        readPlaylists,
        title: title,
        tracks: stored,
      ),
    _PickExistingQueuePlaylist(:final playlist) => addQueueToExistingPlaylist(
        repo,
        readPlaylists,
        target: playlist,
        tracks: stored,
      ),
  };
}
