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

  group('uniqueQueuePlaylistTitle, new playlist, & existing playlist add', () {
    test('avoids collisions and filters editable target playlists', () {
      const existing = [
        SavedPlaylist(id: 1, title: 'Liked Songs', mode: SavedPlaylist.likedMode),
        SavedPlaylist(id: 2, title: 'Local songs', mode: SavedPlaylist.localMode),
        SavedPlaylist(id: 3, title: 'Queue Mix', mode: 'custom'),
        SavedPlaylist(id: 4, title: 'Queue Mix (2)', mode: 'custom'),
        SavedPlaylist(id: 5, title: 'On PC', mode: SavedPlaylist.libraryMode),
      ];

      expect(uniqueQueuePlaylistTitle('Queue Mix', existing), 'Queue Mix (3)');
      expect(uniqueQueuePlaylistTitle('Liked Songs', existing), 'Liked Songs (2)');
      expect(uniqueQueuePlaylistTitle('Local songs', existing), 'Local songs (2)');
      expect(uniqueQueuePlaylistTitle('   ', existing), 'Queue Mix (3)');
      expect(uniqueQueuePlaylistTitle('Road Trip', existing), 'Road Trip');

      final targets = editableQueuePlaylists(existing);
      expect(targets.map((p) => p.title).toList(), [
        'Queue Mix',
        'Queue Mix (2)',
        'On PC',
      ]);
    });

    test('saves queue into a new playlist and merges without duplicates into existing playlist', () async {
      final db = AppDatabase.inMemory();
      final repo = PlaylistRepository(db);
      final q = [
        track('Song One', 'Artist A', album: 'Alb 1', videoId: 'v1', seconds: 200),
        track('Song Two', 'Artist B', album: 'Alb 2', videoId: 'v2', seconds: 215),
      ];
      final stored = queueTracksToStored(q);

      final createdRes = await saveQueueToNewPlaylist(
        repo,
        () => repo.all,
        title: 'Late Night Queue',
        tracks: stored,
      );
      expect(createdRes.createdNew, isTrue);
      expect(createdRes.addedCount, 2);
      expect(createdRes.playlist.tracks, hasLength(2));
      expect(createdRes.playlist.tracks.first.album, 'Alb 1');

      final extra = queueTracksToStored([
        track('song one', 'artist a', videoId: 'v1', seconds: 200),
        track('Song Three', 'Artist C', album: 'Alb 3', videoId: 'v3', seconds: 240),
      ]);
      expect(countNewTracksForPlaylist(createdRes.playlist, extra), 1);

      final mergedRes = addQueueToExistingPlaylist(
        repo,
        () => repo.all,
        target: createdRes.playlist,
        tracks: extra,
      );
      expect(mergedRes.createdNew, isFalse);
      expect(mergedRes.addedCount, 1);
      expect(mergedRes.totalCount, 2);
      expect(mergedRes.playlist.tracks.map((t) => t.name).toList(), [
        'Song One',
        'Song Two',
        'Song Three',
      ]);

      final noopRes = addQueueToExistingPlaylist(
        repo,
        () => repo.all,
        target: mergedRes.playlist,
        tracks: extra,
      );
      expect(noopRes.addedCount, 0);
      expect(noopRes.playlist.tracks, hasLength(3));
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
