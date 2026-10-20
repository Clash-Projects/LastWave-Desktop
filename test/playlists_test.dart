import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/storage/app_database.dart';
import 'package:lastwave_desktop/features/library/playlists.dart';

void main() {
  test('SavedPlaylist isLikedSongs matches mode and title variants', () {
    const p1 = SavedPlaylist(id: 1, title: 'Liked Songs', mode: 'liked');
    const p2 = SavedPlaylist(id: 2, title: 'liked songs', mode: 'custom');
    const p3 = SavedPlaylist(id: 3, title: 'Liked Music', mode: 'custom');
    const p4 = SavedPlaylist(id: 4, title: 'My Mix', mode: 'custom');

    expect(p1.isLikedSongs, isTrue);
    expect(p2.isLikedSongs, isTrue);
    expect(p3.isLikedSongs, isTrue);
    expect(p4.isLikedSongs, isFalse);
  });

  test('createCustom with Liked Songs routes to ensureLikedSongs', () async {
    final db = AppDatabase.inMemory();
    final repo = PlaylistRepository(db);

    final liked = await repo.ensureLikedSongs();
    final customLiked = await repo.createCustom('Liked Songs');

    expect(customLiked.id, liked.id);
    expect(repo.state.where((p) => p.isLikedSongs).length, 1);
  });

  test('collapseDuplicateLikedRows collapses duplicate rows into one and merges tracks', () async {
    final db = AppDatabase.inMemory();

    // Insert two duplicate liked rows directly into DB
    final track1 = const StoredTrack(name: 'Song A', artist: 'Artist 1');
    final track2 = const StoredTrack(name: 'Song B', artist: 'Artist 2');
    final track1Dup = const StoredTrack(name: 'Song A', artist: 'Artist 1');

    db.raw.execute(
      'INSERT INTO saved_playlists(id, title, subtitle, mode, tracks_json, created_at_millis, is_pinned) '
      'VALUES(?, ?, ?, ?, ?, ?, 1);',
      [101, 'Liked Songs', 'sub', 'liked', jsonEncode([track1.toJson()]), 1000],
    );
    db.raw.execute(
      'INSERT INTO saved_playlists(id, title, subtitle, mode, tracks_json, created_at_millis, is_pinned) '
      'VALUES(?, ?, ?, ?, ?, ?, 0);',
      [102, 'Liked Songs', 'sub', 'custom', jsonEncode([track2.toJson(), track1Dup.toJson()]), 2000],
    );

    // Initializing repository should auto-collapse duplicates
    final repo = PlaylistRepository(db);

    final likedPlaylists = repo.state.where((p) => p.isLikedSongs).toList();
    expect(likedPlaylists.length, 1);

    final keeper = likedPlaylists.first;
    expect(keeper.mode, SavedPlaylist.likedMode);
    expect(keeper.tracks.length, 2);
    expect(keeper.tracks.map((t) => t.name).toSet(), {'Song A', 'Song B'});

    // Verify leftover row was deleted from sqlite
    final rows = db.raw.select('SELECT id FROM saved_playlists WHERE id = 101;');
    expect(rows.isEmpty, isTrue);
  });

  test('toggleLiked toggles locally and does not create duplicate playlists', () async {
    final db = AppDatabase.inMemory();
    final repo = PlaylistRepository(db);

    const track = StoredTrack(name: 'Midnight City', artist: 'M83');
    final loved = await repo.toggleLiked(track);
    expect(loved, isTrue);

    expect(repo.state.where((p) => p.isLikedSongs).length, 1);
    expect(repo.likedKeys(), contains('midnight city|m83'));

    final unloved = await repo.toggleLiked(track);
    expect(unloved, isFalse);
    expect(repo.state.where((p) => p.isLikedSongs).length, 1);
    expect(repo.likedKeys(), isNot(contains('midnight city|m83')));
  });
}
