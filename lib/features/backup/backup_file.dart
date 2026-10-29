import 'dart:convert';

import '../../core/app_info.dart';
import '../../core/storage/app_database.dart';
import '../library/playlist_file.dart' show youtubeIdOf;
import '../library/playlists.dart';
import 'backup_sync.dart';

/// LastWave-Native's backup file (`BackupRepository`, type
/// "lastwave-backup"), read and written here so saved playlists and the
/// "don't recommend" list move between the phone and the desktop.
///
/// Sync merges both ways (see `backup_sync.dart`). The phone's settings
/// (`prefs`) mean nothing here, but a phone restore replaces its settings
/// with whatever the file carries: they are kept from the last synced file
/// and written back unchanged.
const backupType = 'lastwave-backup';

/// Highest LastWave-Native backup schema this reads (and the one it writes).
const backupSchemaVersion = 8;

const _mobilePrefsKey = 'backup_mobile_prefs';

/// The file as this computer last synced it: the merge's common ancestor.
const _syncBaseKey = 'backup_sync_base';

const _emptyPrefs = {
  'strings': {},
  'booleans': {},
  'integers': {},
  'longs': {},
  'stringSets': {},
};

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

/// Every playlist and exclusion row, to notice edits made during a sync.
String _libraryState(AppDatabase db) => jsonEncode([
  for (final r in db.raw.select('SELECT * FROM saved_playlists ORDER BY id;'))
    r.values,
  for (final r in db.raw.select(
    'SELECT * FROM recommendation_exclusions ORDER BY track_key;',
  ))
    r.values,
]);

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
              .where(holdsTrack)
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
    'prefs': prefs is Map ? prefs : _emptyPrefs,
    'playlists': playlists,
    'recommendationExclusions': exclusions,
  });
}

/// Merges [content] (a backup file from the phone or another computer)
/// with this library, hands the merged file to [writeFile], then stores the
/// merged library here. The file is written first: if that fails nothing
/// changed, and if the local write fails the file is merely ahead, which
/// the next sync reads back as changes made elsewhere.
Future<BackupSummary> syncBackup(
  AppDatabase db,
  String content,
  Future<void> Function(String merged) writeFile,
) async {
  final remote = _parse(content);
  Map<String, dynamic>? base;
  try {
    base = _parse(db.kvGet(_syncBaseKey) ?? '');
  } catch (_) {}
  // What the merge starts from: if the library changes before it is
  // replaced (an edit during the upload), the replace is skipped.
  final before = _libraryState(db);
  final local = _parse(buildBackup(db));

  final merged = mergeLibraries(
    basePlaylists: base == null ? null : _playlists(base),
    baseExclusions: base == null ? null : _exclusions(base),
    localPlaylists: _playlists(local),
    localExclusions: _exclusions(local),
    remotePlaylists: _playlists(remote),
    // Schema 6 and older files say nothing about exclusions: keep ours.
    remoteExclusions: (remote['schemaVersion'] as int) >= 7
        ? _exclusions(remote)
        : _exclusions(local),
    holds: holdsTrack,
    holdsPlaylist: holdsPlaylist,
  );
  final output = const JsonEncoder.withIndent('  ').convert({
    'type': backupType,
    'schemaVersion': backupSchemaVersion,
    'createdAt': DateTime.now().millisecondsSinceEpoch,
    'appVersion': 'desktop-$appVersion',
    'prefs': remote['prefs'],
    'playlists': merged.playlists,
    'recommendationExclusions': merged.exclusions,
  });
  await writeFile(output);
  if (_libraryState(db) != before) {
    // Not lost: the next sync (30 s after the edit) merges it.
    throw const BackupException(
      'Your library changed during the sync; it will sync again.',
    );
  }

  // Keep what only this app knows (duration, matched video) for tracks
  // already here, and this app's own Liked Songs row id.
  final known = <String, StoredTrack>{};
  final likedIds = <int>[];
  for (final r in db.raw.select(
    'SELECT id, mode, tracks_json FROM saved_playlists;',
  )) {
    if (r['mode'] == SavedPlaylist.likedMode) likedIds.add(r['id'] as int);
    for (final t in _storedTracks(r['tracks_json'] as String?)) {
      known.putIfAbsent(trackKey(trackToBackup(t)), () => t);
    }
  }

  final raw = db.raw;
  raw.execute('BEGIN;');
  try {
    raw.execute('DELETE FROM saved_playlists;');
    for (final p in merged.playlists.where(holdsPlaylist)) {
      final tracks = [
        for (final t in tracksOf(p))
          if (holdsTrack(t)) known[trackKey(t)] ?? trackFromBackup(t),
      ];
      final liked = p['mode'] == SavedPlaylist.likedMode;
      raw.execute(
        'INSERT INTO saved_playlists (id, title, subtitle, mode, tracks_json, '
        'created_at_millis, discover_signature, custom_cover_uri, is_pinned) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);',
        [
          liked && likedIds.isNotEmpty
              ? likedIds.first
              : (p['id'] as num).toInt(),
          p['title']?.toString() ?? '',
          p['subtitle']?.toString() ?? '',
          p['mode']?.toString() ?? 'custom',
          jsonEncode(tracks.map((t) => t.toJson()).toList()),
          (p['createdAtMillis'] as num?)?.toInt() ?? 0,
          p['discoverSignature']?.toString(),
          p['customCoverUri']?.toString(),
          p['isPinned'] == true ? 1 : 0,
        ],
      );
    }
    raw.execute('DELETE FROM recommendation_exclusions;');
    for (final e in merged.exclusions) {
      raw.execute(
        'INSERT OR REPLACE INTO recommendation_exclusions '
        '(track_key, excluded_at_millis, track_name, artist_name) '
        'VALUES (?, ?, ?, ?);',
        [
          e['trackKey'].toString(),
          (e['excludedAtMillis'] as num?)?.toInt() ?? 0,
          e['trackName']?.toString() ?? '',
          e['artistName']?.toString() ?? '',
        ],
      );
    }
    db.kvSet(_mobilePrefsKey, jsonEncode(remote['prefs']));
    db.kvSet(_syncBaseKey, output);
    raw.execute('COMMIT;');
  } catch (e) {
    raw.execute('ROLLBACK;');
    throw BackupException(
      'The file was updated but this library was not ($e). Sync again.',
    );
  }
  return BackupSummary(
    playlists: merged.playlists.length,
    exclusions: merged.exclusions.length,
  );
}

/// The phone's built-in "Local songs" playlist: never imported here, and
/// never deleted from the file by this computer.
bool holdsPlaylist(Map<String, dynamic> playlist) =>
    playlist['mode'] != 'local';

/// The phone's local songs (a file path on the phone) mean nothing here:
/// never imported, and left untouched in the file.
bool holdsTrack(Map<String, dynamic> track) {
  final url = track['url']?.toString() ?? '';
  return !(url.startsWith('/') ||
      url.startsWith('content://') ||
      url.startsWith('file://'));
}

/// Validated backup root. Every playlist has a numeric id and readable
/// tracks, so the merge never meets a damaged entry halfway.
Map<String, dynamic> _parse(String content) {
  const notBackup = BackupException('This is not a LastWave backup file.');
  final Object? root;
  try {
    root = jsonDecode(content);
  } catch (_) {
    throw notBackup;
  }
  if (root is! Map || root['type'] != backupType) throw notBackup;
  final schema = root['schemaVersion'];
  if (schema is! int) throw notBackup;
  if (schema > backupSchemaVersion) {
    throw const BackupException(
      'This backup comes from a newer LastWave. Update the app first.',
    );
  }
  final playlists = root['playlists'];
  if (playlists is! List) {
    throw const BackupException('This backup has no playlist list.');
  }
  for (final p in playlists) {
    if (p is! Map || p['id'] is! num) {
      throw const BackupException('A playlist in this backup is damaged.');
    }
    try {
      tracksOf(Map<String, dynamic>.from(p));
    } catch (_) {
      throw BackupException('The tracks of "${p['title']}" are damaged.');
    }
  }
  return {
    ...Map<String, dynamic>.from(root),
    'prefs': root['prefs'] is Map ? root['prefs'] : _emptyPrefs,
    // Schema 6 and older carried no explicit exclusions.
    'recommendationExclusions': [
      if (schema >= 7 && root['recommendationExclusions'] is List)
        for (final e in root['recommendationExclusions'] as List)
          if (e is Map && '${e['trackKey'] ?? ''}'.isNotEmpty)
            Map<String, dynamic>.from(e),
    ],
  };
}

List<Map<String, dynamic>> _playlists(Map<String, dynamic> root) => [
  for (final p in root['playlists'] as List)
    Map<String, dynamic>.from(p as Map),
];

List<Map<String, dynamic>> _exclusions(Map<String, dynamic> root) =>
    List<Map<String, dynamic>>.from(root['recommendationExclusions'] as List);

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
