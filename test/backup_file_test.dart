import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/storage/app_database.dart';
import 'package:lastwave_desktop/features/backup/backup_file.dart';
import 'package:lastwave_desktop/features/library/playlists.dart';

/// Shape written by LastWave-Native's BackupRepository (schema 8).
String phoneBackup({int schema = 8, String? likedTracksJson}) => jsonEncode({
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
              'url': '/storage/emulated/0/Music/demo.flac',
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
      'tracksJson': jsonEncode([
        {
          'name': 'Hello',
          'artist': 'Adele',
          'url': 'https://www.last.fm/music/Adele/_/Hello',
        },
      ]),
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

void main() {
  test('restores a phone backup into desktop playlists and exclusions', () {
    final db = AppDatabase.inMemory();
    final summary = restoreBackup(db, phoneBackup());

    expect(summary.playlists, 2);
    expect(summary.exclusions, 1);
    final playlists = playlistsOf(db);
    final liked = playlists.firstWhere((p) => p.isLikedSongs);
    expect(liked.isPinned, isTrue);
    expect(liked.tracks.first.videoId, 'A_MjCqQoLLA');
    expect(liked.tracks.first.artworkUrl, startsWith('https://i.ytimg.com'));
    expect(liked.tracks.first.album, 'Past Masters');
    expect(liked.tracks.first.url, isEmpty);
    expect(liked.tracks[1].videoId, isEmpty);
    expect(liked.tracks[1].url, '/storage/emulated/0/Music/demo.flac');
    expect(db.loadExclusionKeys(), {'baby|justin bieber'});
  });

  test('export gives the phone back its links, cover and settings', () {
    final db = AppDatabase.inMemory();
    restoreBackup(db, phoneBackup());

    final out = jsonDecode(buildBackup(db)) as Map<String, dynamic>;
    expect(out['type'], 'lastwave-backup');
    expect(out['schemaVersion'], 8);
    expect(out['prefs']['strings'], {'lw_theme': 'midnight'});
    expect(out['prefs']['longs'], {'ytm_last_sync_at': 1761299999000});
    final liked = (out['playlists'] as List).first as Map<String, dynamic>;
    expect(liked['mode'], 'liked');
    expect(liked['isPinned'], isTrue);
    expect(liked['customCoverUri'], 'content://media/external/images/1');
    final tracks = jsonDecode(liked['tracksJson'] as String) as List;
    expect(tracks[0]['url'], 'A_MjCqQoLLA');
    expect(tracks[1]['url'], '/storage/emulated/0/Music/demo.flac');
    expect(out['recommendationExclusions'], hasLength(1));
  });

  test('a matched video replaces a web page link, not a local file', () {
    expect(
      trackToBackup(
        const StoredTrack(
          name: 'Hello',
          artist: 'Adele',
          videoId: 'YQHsXMglC9A',
          url: 'https://www.last.fm/music/Adele/_/Hello',
        ),
      )['url'],
      'YQHsXMglC9A',
    );
    expect(
      trackToBackup(
        const StoredTrack(
          name: 'Demo',
          artist: 'Me',
          videoId: 'YQHsXMglC9A',
          url: '/storage/emulated/0/Music/demo.flac',
        ),
      )['url'],
      '/storage/emulated/0/Music/demo.flac',
    );
  });

  test(
    'export without a phone backup restored still has every phone field',
    () {
      final db = AppDatabase.inMemory();
      final out = jsonDecode(buildBackup(db)) as Map<String, dynamic>;
      expect(
        out['prefs'].keys,
        containsAll(['strings', 'booleans', 'integers', 'longs', 'stringSets']),
      );
      expect(out['playlists'], isEmpty);
    },
  );

  test('bad files throw and leave the library untouched', () {
    final db = AppDatabase.inMemory();
    restoreBackup(db, phoneBackup());

    expect(
      () => restoreBackup(db, 'not json'),
      throwsA(isA<BackupException>()),
    );
    expect(
      () => restoreBackup(
        db,
        '{"type":"other","schemaVersion":1,"playlists":[]}',
      ),
      throwsA(isA<BackupException>()),
    );
    expect(
      () => restoreBackup(db, phoneBackup(schema: 9)),
      throwsA(isA<BackupException>()),
    );
    expect(
      () => restoreBackup(db, phoneBackup(likedTracksJson: '{broken')),
      throwsA(isA<BackupException>()),
    );
    expect(playlistsOf(db), hasLength(2));
    expect(db.loadExclusionKeys(), {'baby|justin bieber'});
  });

  test('schema 6 backups keep the existing exclusions', () {
    final db = AppDatabase.inMemory();
    db.addExclusion(name: 'Gangnam Style', artist: 'PSY');
    final summary = restoreBackup(db, phoneBackup(schema: 6));
    expect(summary.exclusions, 0);
    expect(db.loadExclusionKeys(), {'gangnam style|psy'});
  });
}
