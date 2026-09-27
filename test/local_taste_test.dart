import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/storage/app_database.dart';
import 'package:lastwave_desktop/features/feed/local_taste.dart';
import 'package:lastwave_desktop/features/lastfm/home_repository.dart';

void main() {
  group('local_plays log', () {
    test('records and returns newest-first', () {
      final db = AppDatabase.inMemory();
      db.recordLocalPlay(title: 'Song A', artist: 'Artist X');
      db.recordLocalPlay(title: 'Song B', artist: 'Artist Y');
      final plays = db.loadRecentPlays(limit: 10);
      expect(plays.length, 2);
      expect(plays.first.title, 'Song B');
      expect(plays.last.title, 'Song A');
    });

    test('skips empty titles/artists', () {
      final db = AppDatabase.inMemory();
      db.recordLocalPlay(title: '', artist: 'Artist X');
      db.recordLocalPlay(title: 'Song A', artist: '');
      db.recordLocalPlay(title: '  ', artist: '  ');
      expect(db.loadRecentPlays(limit: 10), isEmpty);
    });

    test('dedupes same-track replays within 10 minutes', () {
      final db = AppDatabase.inMemory();
      db.recordLocalPlay(title: 'Looped', artist: 'Artist X');
      db.recordLocalPlay(title: 'Looped', artist: 'Artist X');
      db.recordLocalPlay(title: 'Other', artist: 'Artist Y');
      db.recordLocalPlay(title: 'Looped', artist: 'Artist X');
      final plays = db.loadRecentPlays(limit: 10);
      // Other breaks the run, so the final Looped is a fresh row.
      expect(plays.length, 3);
      expect(
        plays.where((p) => p.title == 'Looped').length,
        2,
      );
    });

    test('prunes to the newest 500 rows', () {
      final db = AppDatabase.inMemory();
      for (var i = 0; i < AppDatabase.localPlaysCap + 5; i++) {
        db.recordLocalPlay(
          title: 'Song $i',
          artist: 'Artist $i',
        );
      }
      final plays =
          db.loadRecentPlays(limit: AppDatabase.localPlaysCap + 10);
      expect(plays.length, AppDatabase.localPlaysCap);
      expect(plays.first.title,
          'Song ${AppDatabase.localPlaysCap + 4}');
    });
  });

  group('LocalTaste.seedPool', () {
    test('orders recents, then liked, then downloads; dedupes', () {
      const taste = LocalTaste(
        recentPlays: [
          HomeTrack(name: 'Recent', artist: 'A'),
          HomeTrack(name: 'Dup', artist: 'B'),
        ],
        likedTracks: [
          HomeTrack(name: 'Dup', artist: 'B'),
          HomeTrack(name: 'Liked', artist: 'C'),
        ],
        downloadedTracks: [
          HomeTrack(name: 'Owned', artist: 'D'),
        ],
      );
      final pool = taste.seedPool(limit: 10);
      expect(
        pool.map((t) => t.name).toList(),
        ['Recent', 'Dup', 'Liked', 'Owned'],
      );
      expect(taste.isEmpty, isFalse);
      expect(const LocalTaste().isEmpty, isTrue);
    });

    test('respects the limit', () {
      const taste = LocalTaste(
        recentPlays: [
          HomeTrack(name: 'One', artist: 'A'),
          HomeTrack(name: 'Two', artist: 'B'),
          HomeTrack(name: 'Three', artist: 'C'),
        ],
      );
      expect(taste.seedPool(limit: 2).length, 2);
    });
  });
}
