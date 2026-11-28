import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/audio/stream_models.dart';
import 'package:lastwave_desktop/core/storage/app_database.dart';
import 'package:lastwave_desktop/features/library/playlists.dart';
import 'package:lastwave_desktop/ui/queue/queue_actions.dart';

void main() {
  PlayableTrack track(
    String title,
    String artist, {
    String album = '',
    String videoId = '',
    int seconds = 180,
  }) =>
      PlayableTrack(
        title: title,
        artist: artist,
        album: album,
        videoId: videoId,
        duration: Duration(seconds: seconds),
      );

  group('visibleQueueTracks & queueTracksToStored', () {
    test('returns current track plus upcoming tracks and ignores played history', () {
      final q = [
        track('Past Song', 'A'),
        track('Now Song', 'B', album: 'Album B', videoId: 'vidB'),
        track('Next Song', 'C', album: 'Album C', videoId: 'vidC'),
      ];

      final visible = visibleQueueTracks(q, 1);
      expect(visible.map((t) => t.title).toList(), ['Now Song', 'Next Song']);

      final stored = queueTracksToStored(visible, addedAtMillis: 12345);
      expect(stored, hasLength(2));
      expect(stored.first.name, 'Now Song');
      expect(stored.first.album, 'Album B');
      expect(stored.first.videoId, 'vidB');
      expect(stored.first.durationSeconds, 180);
      expect(stored.first.addedAtMillis, 12345);
    });

    test('deduplicates repeated tracks by title|artist', () {
      final q = [
        track('Midnight City', 'M83', videoId: '1'),
        track('midnight city', 'm83', videoId: '2'),
        track('Outro', 'M83', videoId: '3'),
      ];
      final stored = queueTracksToStored(q);
      expect(stored.map((s) => s.name).toList(), ['Midnight City', 'Outro']);
    });

    test('handles negative currentIndex and empty queue safely', () {
      expect(visibleQueueTracks(const [], 0), isEmpty);
      final q = [track('A', 'X'), track('B', 'Y')];
      expect(visibleQueueTracks(q, -1), hasLength(2));
    });
  });

  group('filterUpcomingTracks', () {
    test('matches title, artist, and album while preserving original queueIndex', () {
      final q = [
        track('Playing Now', 'Host', album: 'Now'),
        track('Golden Hour', 'JVKE', album: 'this is what ____ feels like'),
        track('Blinding Lights', 'The Weeknd', album: 'After Hours'),
        track('Midnight Rain', 'Taylor Swift', album: 'Midnights'),
      ];

      final byArtist = filterUpcomingTracks(q, 0, 'weeknd');
      expect(byArtist, hasLength(1));
      expect(byArtist.first.queueIndex, 2);
      expect(byArtist.first.track.title, 'Blinding Lights');

      final byAlbum = filterUpcomingTracks(q, 0, 'midnights');
      expect(byAlbum, hasLength(1));
      expect(byAlbum.first.queueIndex, 3);

      final all = filterUpcomingTracks(q, 0, '   ');
      expect(all.map((e) => e.queueIndex).toList(), [1, 2, 3]);
    });
  });

  group('uniqueQueuePlaylistTitle & PlaylistRepository save', () {
    test('avoids collisions with existing and reserved playlist names', () {
      const existing = [
        SavedPlaylist(id: 1, title: 'Liked Songs', mode: SavedPlaylist.likedMode),
        SavedPlaylist(id: 2, title: 'Queue Mix', mode: 'custom'),
        SavedPlaylist(id: 3, title: 'Queue Mix (2)', mode: 'custom'),
      ];

      expect(uniqueQueuePlaylistTitle('Queue Mix', existing), 'Queue Mix (3)');
      expect(uniqueQueuePlaylistTitle('Liked Songs', existing), 'Liked Songs (2)');
      expect(uniqueQueuePlaylistTitle('Local songs', existing), 'Local songs (2)');
      expect(uniqueQueuePlaylistTitle('   ', existing), 'Queue Mix (3)');
      expect(uniqueQueuePlaylistTitle('Road Trip', existing), 'Road Trip');
    });

    test('saves full queue atomically into a new SavedPlaylist', () async {
      final db = AppDatabase.inMemory();
      final repo = PlaylistRepository(db);
      final q = [
        track('Song One', 'Artist A', album: 'Alb 1', videoId: 'v1', seconds: 200),
        track('Song Two', 'Artist B', album: 'Alb 2', videoId: 'v2', seconds: 215),
      ];
      final title = uniqueQueuePlaylistTitle('Late Night Queue', repo.all);
      final created = await repo.createCustom(title);
      repo.applyBatch(created.id, add: queueTracksToStored(q));

      final saved = repo.state.firstWhere((p) => p.id == created.id);
      expect(saved.title, 'Late Night Queue');
      expect(saved.tracks, hasLength(2));
      expect(saved.tracks.first.album, 'Alb 1');
      expect(saved.tracks.last.durationSeconds, 215);
    });
  });

  group('QueueClearUndoNotifier', () {
    test('counts down 5 seconds and expires cleanly', () async {
      final notifier = QueueClearUndoNotifier();
      addTearDown(notifier.dispose);

      notifier.recordCleared(
        [track('Next', 'Artist')],
        expectedCurrentKey: 'now|artist',
      );
      expect(notifier.state, isNotNull);
      expect(notifier.state!.secondsLeft, 5);

      await Future<void>.delayed(const Duration(milliseconds: 5300));
      expect(notifier.state, isNull);
    });

    test('takeForUndo consumes snapshot once and dismiss/expire clear it', () {
      final notifier = QueueClearUndoNotifier();
      addTearDown(notifier.dispose);

      notifier.recordCleared(
        [track('A', '1'), track('B', '2')],
        expectedCurrentKey: 'cur|0',
      );
      final taken = notifier.takeForUndo();
      expect(taken, isNotNull);
      expect(taken!.tracks, hasLength(2));
      expect(notifier.state, isNull);
      expect(notifier.takeForUndo(), isNull);

      notifier.recordCleared(
        [track('C', '3')],
        expectedCurrentKey: 'cur|1',
      );
      notifier.expireIfTrackChanged('cur|1');
      expect(notifier.state, isNotNull);
      notifier.expireIfTrackChanged('cur|2');
      expect(notifier.state, isNull);
    });
  });
}
