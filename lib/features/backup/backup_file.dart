import 'dart:convert';

import '../../core/app_info.dart';
import '../../core/storage/app_database.dart';
import '../library/playlist_file.dart' show youtubeIdOf;
import '../library/playlists.dart';

/// LastWave-Native's backup file (`BackupRepository`, type
/// "lastwave-backup"), read and written here so saved playlists and the
/// "don't recommend" list move between the phone and the desktop.
///
/// A restore replaces both, like on the phone. The phone's settings
/// (`prefs`) mean nothing here, but a phone restore replaces its settings
/// with whatever the file carries: they are kept from the last imported
/// file and written back unchanged on export.
const backupType = 'lastwave-backup';

/// Highest LastWave-Native backup schema this reads (and the one it writes).
const backupSchemaVersion = 8;

const _mobilePrefsKey = 'backup_mobile_prefs';

class BackupException implements Exception {
  final String message;
  const BackupException(this.message);

  @override
  String toString() => message;
}

class BackupSummary {
  final int playlists;
  final int exclusions;
  const BackupSummary({required this.playlists, required this.exclusions});
}

/// Phone track: `StoredTrack(name, artist, url, image, album)`.
StoredTrack trackFromBackup(Map<String, dynamic> json) {
  final url = json['url']?.toString().trim() ?? '';
  final videoId = youtubeIdOf(url) ?? '';
  return StoredTrack(
    name: json['name']?.toString() ?? '',
    artist: json['artist']?.toString() ?? '',
    artworkUrl: json['image']?.toString() ?? '',
    videoId: videoId,
    album: json['album']?.toString() ?? '',
    url: videoId.isEmpty ? url : '',
  );
}

Map<String, dynamic> trackToBackup(StoredTrack track) {
  // A local path stays a local path on the phone; a web page (Last.fm)
  // gives way to the video this app matched since.
  final keepUrl =
      track.url.isNotEmpty &&
      (track.videoId.isEmpty || !track.url.startsWith('http'));
  return {
    'name': track.name,
    'artist': track.artist,
    'url': keepUrl ? track.url : track.videoId,
    'image': track.artworkUrl.isEmpty ? null : track.artworkUrl,
    'album': track.album.isEmpty ? null : track.album,
  };
}

String buildBackup(AppDatabase db) {
  final playlists = [
    for (final r in db.raw.select(
      'SELECT * FROM saved_playlists ORDER BY created_at_millis ASC;',
    ))
      {
        'id': r['id'],
        'title': r['title'] ?? '',
        'subtitle': r['subtitle'] ?? '',
        'mode': r['mode'] ?? 'custom',
        'tracksJson': jsonEncode(
          _storedTracks(r['tracks_json'] as String?)
              .map(trackToBackup)
              .toList(),
        ),
        'createdAtMillis': r['created_at_millis'] ?? 0,
        'discoverSignature': r['discover_signature'],
        'customCoverUri': r['custom_cover_uri'],
        'isPinned': (r['is_pinned'] ?? 0) == 1,
      },
  ];
  final exclusions = [
    for (final r in db.raw.select(
      'SELECT * FROM recommendation_exclusions ORDER BY excluded_at_millis ASC;',
    ))
      {
        'trackKey': r['track_key'],
        'excludedAtMillis': r['excluded_at_millis'] ?? 0,
        'trackName': r['track_name'] ?? '',
        'artistName': r['artist_name'] ?? '',
      },
  ];
  Object? prefs;
  try {
    prefs = jsonDecode(db.kvGet(_mobilePrefsKey) ?? '');
  } catch (_) {}
  return const JsonEncoder.withIndent('  ').convert({
    'type': backupType,
    'schemaVersion': backupSchemaVersion,
    'createdAt': DateTime.now().millisecondsSinceEpoch,
    'appVersion': 'desktop-$appVersion',
    'prefs': prefs is Map
        ? prefs
        : const {
            'strings': {},
            'booleans': {},
            'integers': {},
            'longs': {},
            'stringSets': {},
          },
    'playlists': playlists,
    'recommendationExclusions': exclusions,
  });
}

/// Replaces saved playlists (and exclusions, schema 7+) with the file's.
/// Everything is checked before the first write; the writes are one
/// transaction, so a bad file leaves the library untouched.
BackupSummary restoreBackup(AppDatabase db, String content) {
  final Object? root;
  try {
    root = jsonDecode(content);
  } catch (_) {
    throw const BackupException('This is not a LastWave backup file.');
  }
  if (root is! Map || root['type'] != backupType) {
    throw const BackupException('This is not a LastWave backup file.');
  }
  final schema = root['schemaVersion'];
  if (schema is! int) {
    throw const BackupException('This is not a LastWave backup file.');
  }
  if (schema > backupSchemaVersion) {
    throw const BackupException(
      'This backup comes from a newer LastWave. Update the app first.',
    );
  }
  final rawPlaylists = root['playlists'];
  if (rawPlaylists is! List) {
    throw const BackupException('This backup has no playlist list.');
  }

  final playlists = <List<Object?>>[];
  for (final p in rawPlaylists) {
    final id = p is Map ? p['id'] : null;
    if (p is! Map || id is! num) {
      throw const BackupException('A playlist in this backup is damaged.');
    }
    final title = p['title']?.toString() ?? '';
    final List<StoredTrack> tracks;
    try {
      final decoded = jsonDecode(p['tracksJson']?.toString() ?? '[]');
      tracks = [
        for (final t in decoded as List)
          trackFromBackup(Map<String, dynamic>.from(t as Map)),
      ];
    } catch (_) {
      throw BackupException('The tracks of "$title" are damaged.');
    }
    playlists.add([
      id.toInt(),
      title,
      p['subtitle']?.toString() ?? '',
      p['mode']?.toString() ?? 'custom',
      jsonEncode(tracks.map((t) => t.toJson()).toList()),
      (p['createdAtMillis'] as num?)?.toInt() ?? 0,
      p['discoverSignature']?.toString(),
      p['customCoverUri']?.toString(),
      p['isPinned'] == true ? 1 : 0,
    ]);
  }

  // Older phone backups carried no explicit exclusions: keep ours then.
  final rawExclusions = root['recommendationExclusions'];
  final exclusions = <List<Object?>>[
    if (schema >= 7 && rawExclusions is List)
      for (final e in rawExclusions)
        if (e is Map && (e['trackKey']?.toString() ?? '').isNotEmpty)
          [
            e['trackKey'].toString(),
            (e['excludedAtMillis'] as num?)?.toInt() ?? 0,
            e['trackName']?.toString() ?? '',
            e['artistName']?.toString() ?? '',
          ],
  ];
  final prefs = root['prefs'];

  final raw = db.raw;
  raw.execute('BEGIN;');
  try {
    raw.execute('DELETE FROM saved_playlists;');
    for (final row in playlists) {
      raw.execute(
        'INSERT INTO saved_playlists (id, title, subtitle, mode, tracks_json, '
        'created_at_millis, discover_signature, custom_cover_uri, is_pinned) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);',
        row,
      );
    }
    if (schema >= 7) {
      raw.execute('DELETE FROM recommendation_exclusions;');
      for (final row in exclusions) {
        raw.execute(
          'INSERT OR REPLACE INTO recommendation_exclusions '
          '(track_key, excluded_at_millis, track_name, artist_name) '
          'VALUES (?, ?, ?, ?);',
          row,
        );
      }
    }
    if (prefs is Map) db.kvSet(_mobilePrefsKey, jsonEncode(prefs));
    raw.execute('COMMIT;');
  } catch (e) {
    raw.execute('ROLLBACK;');
    throw BackupException('Restore failed, nothing was changed ($e).');
  }
  return BackupSummary(
    playlists: playlists.length,
    exclusions: schema >= 7 ? exclusions.length : 0,
  );
}

List<StoredTrack> _storedTracks(String? json) {
  try {
    final decoded = jsonDecode(json ?? '[]');
    if (decoded is List) {
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(StoredTrack.fromJson)
          .toList();
    }
  } catch (_) {}
  return const [];
}
