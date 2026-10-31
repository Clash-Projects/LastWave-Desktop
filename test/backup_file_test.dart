import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/storage/app_database.dart';
import 'package:lastwave_desktop/features/backup/backup_file.dart';
import 'package:lastwave_desktop/features/library/playlists.dart';

const phoneSong = '/storage/emulated/0/Music/demo.flac';

/// Shape written by LastWave-Native's BackupRepository (schema 8).
String phoneBackup({
  int schema = 8,
  String? likedTracksJson,
  List<Map<String, dynamic>> roadTrip = const [
    {
      'name': 'Hello',
      'artist': 'Adele',
      'url': 'https://www.last.fm/music/Adele/_/Hello',
    },
  ],
}) => jsonEncode({
  'type': 'lastwave-backup',
  'schemaVersion': schema,
  'createdAt': 1761300000000,
  'appVersion': '4.3.1',
  'prefs': {
    'strings': {'lw_theme': 'midnight'},
    'booleans': {'lw_bit_perfect': true},
    'integers': {},
    'longs': {'ytm_last_sync_at': 1761299999000},
    'stringSets': {},
  },
  'playlists': [
    {
      'id': 1761000000000,
      'title': 'Liked Songs',
      'subtitle': 'Your loved tracks',
      'mode': 'liked',
      'tracksJson':
          likedTracksJson ??
          jsonEncode([
            {
              'name': 'Hey Jude',
              'artist': 'The Beatles',
              'url': 'https://music.youtube.com/watch?v=A_MjCqQoLLA',
              'image': 'https://i.ytimg.com/vi/A_MjCqQoLLA/hq.jpg',
              'album': 'Past Masters',
            },
            {
              'name': 'Demo',
              'artist': 'Me',
              'url': phoneSong,
              'image': null,
              'album': null,
            },
          ]),
      'createdAtMillis': 1761000000000,
      'discoverSignature': null,
      'customCoverUri': 'content://media/external/images/1',
      'isPinned': true,
    },
    {
      'id': 1761000000001,
      'title': 'Road Trip',
      'subtitle': '',
      'mode': 'custom',
      'tracksJson': jsonEncode(roadTrip),
      'createdAtMillis': 1761000000001,
      'isPinned': false,
    },
  ],
  'recommendationExclusions': [
    {
      'trackKey': 'baby|justin bieber',
      'excludedAtMillis': 1761000000002,
      'trackName': 'Baby',
      'artistName': 'Justin Bieber',
    },
  ],
});

List<SavedPlaylist> playlistsOf(AppDatabase db) =>
    (PlaylistRepository(db)..refresh()).state;

/// Runs a sync and returns the file content it wrote.
Future<String> sync(AppDatabase db, String file) async {
  late String written;
  await syncBackup(db, file, (merged) async => written = merged);
  return written;
}

List<Map<String, dynamic>> fileTracks(String file, String title) {
  final root = jsonDecode(file) as Map<String, dynamic>;
  final p = (root['playlists'] as List).cast<Map<String, dynamic>>().firstWhere(
    (p) => p['title'] == title,
  );
  return (jsonDecode(p['tracksJson'] as String) as List)
      .cast<Map<String, dynamic>>();
}

void main() {
  test(
    'first sync imports the phone library without its local songs',
    () async {
      final db = AppDatabase.inMemory();
      final file = await sync(db, phoneBackup());

      final liked = playlistsOf(db).firstWhere((p) => p.isLikedSongs);
      expect(liked.isPinned, isTrue);
      expect(liked.tracks, hasLength(1));
      expect(liked.tracks.single.videoId, 'A_MjCqQoLLA');
      expect(liked.tracks.single.album, 'Past Masters');
      expect(db.loadExclusionKeys(), {'baby|justin bieber'});

      // The file still gives the phone its local song, cover and settings.
      expect(fileTracks(file, 'Liked Songs').map((t) => t['url']), [
        'https://music.youtube.com/watch?v=A_MjCqQoLLA',
        phoneSong,
      ]);
      final root = jsonDecode(file) as Map<String, dynamic>;
      expect(root['prefs']['strings'], {'lw_theme': 'midnight'});
      expect(
        (root['playlists'] as List).first['customCoverUri'],
        'content://media/external/images/1',
      );
    },
  );

  test('later syncs carry edits both ways', () async {
    final db = AppDatabase.inMemory();
    await sync(db, phoneBackup());

    // Desktop: remove Hello from Road Trip. Phone: add Skyfall to it.
    final repo = PlaylistRepository(db);
    final road = repo.state.firstWhere((p) => p.title == 'Road Trip');
    db.raw.execute('UPDATE saved_playlists SET tracks_json = ? WHERE id = ?;', [
      '[]',
      road.id,
    ]);
    final file = await sync(
      db,
      phoneBackup(
        roadTrip: const [
          {'name': 'Hello', 'artist': 'Adele', 'url': ''},
          {'name': 'Skyfall', 'artist': 'Adele', 'url': 'a3Ue-LN5B9U'},
        ],
      ),
    );

    expect(fileTracks(file, 'Road Trip').map((t) => t['name']), ['Skyfall']);
    final synced = playlistsOf(db).firstWhere((p) => p.title == 'Road Trip');
    expect(synced.tracks.map((t) => t.videoId), ['a3Ue-LN5B9U']);
  });

  test('tracks already here keep what only the desktop knows', () async {
    final db = AppDatabase.inMemory();
    await sync(db, phoneBackup());
    final repo = PlaylistRepository(db);
    final liked = repo.state.firstWhere((p) => p.isLikedSongs);
    db.raw.execute('UPDATE saved_playlists SET tracks_json = ? WHERE id = ?;', [
      jsonEncode([
        const StoredTrack(
          name: 'Hey Jude',
          artist: 'The Beatles',
          videoId: 'A_MjCqQoLLA',
          durationSeconds: 431,
        ).toJson(),
      ]),
      liked.id,
    ]);
    await sync(db, phoneBackup());
    final after = playlistsOf(db).firstWhere((p) => p.isLikedSongs);
    expect(after.id, liked.id);
    expect(after.tracks.single.durationSeconds, 431);
  });

  test('a bad file or a failed write leaves everything untouched', () async {
    final db = AppDatabase.inMemory();
    await sync(db, phoneBackup());

    var wrote = false;
    for (final bad in [
      'not json',
      '{"type":"other","schemaVersion":1,"playlists":[]}',
      phoneBackup(schema: 9),
      phoneBackup(likedTracksJson: '{broken'),
    ]) {
      await expectLater(
        syncBackup(db, bad, (_) async => wrote = true),
        throwsA(isA<BackupException>()),
      );
    }
    expect(wrote, isFalse);

    await expectLater(
      syncBackup(
        db,
        phoneBackup(roadTrip: const []),
        (_) async => throw Exception('disk full'),
      ),
      throwsException,
    );
    expect(
      playlistsOf(db).firstWhere((p) => p.title == 'Road Trip').tracks,
      hasLength(1),
    );
  });

  test('an edit made during the upload is kept', () async {
    final db = AppDatabase.inMemory();
    await sync(db, phoneBackup());
    final roadTrip = playlistsOf(db).firstWhere((p) => p.title == 'Road Trip');

    await expectLater(
      syncBackup(db, phoneBackup(roadTrip: const []), (_) async {
        db.raw.execute(
          'UPDATE saved_playlists SET title = ? WHERE id = ?;',
          ['Road Trip 2', roadTrip.id],
        );
      }),
      throwsA(isA<BackupException>()),
    );
    final after = playlistsOf(db).firstWhere((p) => p.id == roadTrip.id);
    expect(after.title, 'Road Trip 2');
    expect(after.tracks, hasLength(1));
  });

  test(
    'export never writes local songs and keeps the phone settings',
    () async {
      final db = AppDatabase.inMemory();
      await sync(db, phoneBackup());
      db.raw.execute(
        'INSERT INTO saved_playlists (id, title, mode, tracks_json) VALUES (?, ?, ?, ?);',
        [
          5,
          'Old restore',
          'custom',
          jsonEncode([
            {'name': 'X', 'artist': 'Y', 'url': phoneSong},
          ]),
        ],
      );
      final out = jsonDecode(buildBackup(db)) as Map<String, dynamic>;
      expect(out['prefs']['longs'], {'ytm_last_sync_at': 1761299999000});
      expect(fileTracks(jsonEncode(out), 'Old restore'), isEmpty);
    },
  );

  test('the phone\'s Local songs playlist stays on the phone only', () async {
    final db = AppDatabase.inMemory();
    final withLocal = jsonDecode(phoneBackup()) as Map<String, dynamic>;
    (withLocal['playlists'] as List).add({
      'id': 7,
      'title': 'Local songs',
      'subtitle': '',
      'mode': 'local',
      'tracksJson': jsonEncode([
        {'name': 'Demo', 'artist': 'Me', 'url': phoneSong},
      ]),
      'createdAtMillis': 7,
      'isPinned': false,
    });
    final file = jsonEncode(withLocal);
    await sync(db, file);
    expect(playlistsOf(db).map((p) => p.mode), isNot(contains('local')));

    final again = await sync(db, file);
    expect(fileTracks(again, 'Local songs').single['url'], phoneSong);
  });

  test('a schema 6 file keeps the exclusions made here', () async {
    final db = AppDatabase.inMemory();
    await sync(db, phoneBackup());
    db.addExclusion(name: 'Gangnam Style', artist: 'PSY');
    await sync(db, phoneBackup(schema: 6));
    expect(db.loadExclusionKeys(), {'baby|justin bieber', 'gangnam style|psy'});
  });

  test('export from a fresh install still has every phone field', () {
    final out =
        jsonDecode(buildBackup(AppDatabase.inMemory())) as Map<String, dynamic>;
    expect(
      out['prefs'].keys,
      containsAll(['strings', 'booleans', 'integers', 'longs', 'stringSets']),
    );
    expect(out['playlists'], isEmpty);
  });
}
