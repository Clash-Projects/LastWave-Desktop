// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/audio/stream_models.dart';
import '../../core/storage/app_database.dart';
import '../innertube/innertube_api.dart';
import '../search/shared_providers.dart';

/// Stored playlist track (JSON-serialised inside `saved_playlists`).
class StoredTrack {
  final String name;
  final String artist;
  final String artworkUrl;
  final String videoId;

  /// Album / length from the source row. Persisted so a track queued from
  /// a saved playlist still reaches the lossless matcher with the film
  /// (soundtrack rows billed to the composer) and its real duration.
  /// Rows written before this existed simply read back empty/zero.
  final String album;
  final int durationSeconds;

  /// On-disk path for a Local songs row. Empty for streamed tracks.
  final String playbackUrl;

  /// When the row was added. Zero on playlists saved before this field.
  final int addedAtMillis;

  const StoredTrack({
    required this.name,
    required this.artist,
    this.artworkUrl = '',
    this.videoId = '',
    this.album = '',
    this.durationSeconds = 0,
    this.playbackUrl = '',
    this.addedAtMillis = 0,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'artist': artist,
        'artworkUrl': artworkUrl,
        'videoId': videoId,
        'album': album,
        'durationSeconds': durationSeconds,
        'playbackUrl': playbackUrl,
        'addedAtMillis': addedAtMillis,
      };

  factory StoredTrack.fromJson(Map<String, dynamic> json) =>
      StoredTrack(
        name: json['name']?.toString() ?? '',
        artist: json['artist']?.toString() ?? '',
        artworkUrl: json['artworkUrl']?.toString() ?? '',
        videoId: json['videoId']?.toString() ??
            json['youtubeVideoId']?.toString() ??
            '',
        album: json['album']?.toString() ?? '',
        durationSeconds:
            int.tryParse('${json['durationSeconds'] ?? 0}') ?? 0,
        playbackUrl: json['playbackUrl']?.toString() ?? '',
        addedAtMillis:
            int.tryParse('${json['addedAtMillis'] ?? 0}') ?? 0,
      );

  PlayableTrack toPlayable() => PlayableTrack(
        title: name,
        artist: artist,
        album: album,
        artworkUrl: artworkUrl,
        videoId: videoId,
        playbackUrl: playbackUrl,
        duration: Duration(seconds: durationSeconds),
      );
}

/// Saved playlist entity. Mirrors Android `SavedPlaylist`.
class SavedPlaylist {
  static const String likedMode = 'liked';
  static const String likedTitle = 'Liked Songs';

  final int id;
  final String title;
  final String subtitle;
  final String mode;
  final List<StoredTrack> tracks;
  final int createdAtMillis;
  final bool isPinned;
  final String customCoverUri;

  static const String localMode = 'local';
  static const String localTitle = 'Local songs';

  const SavedPlaylist({
    required this.id,
    required this.title,
    this.subtitle = '',
    this.mode = 'custom',
    this.tracks = const [],
    this.createdAtMillis = 0,
    this.isPinned = false,
    this.customCoverUri = '',
  });

  bool get isLikedSongs =>
      mode == likedMode ||
      title.toLowerCase() == likedTitle.toLowerCase() ||
      title.toLowerCase() == 'liked music';

  bool get isLocal =>
      mode == localMode || title.toLowerCase() == localTitle.toLowerCase();
}

/// Playlist + liked-songs repository backed by SQLite.
/// Mirrors Android `PlaylistRepository` + `LikedSongsManager`.
class PlaylistRepository extends StateNotifier<List<SavedPlaylist>> {
  final AppDatabase _db;
  final InnerTubeMusicApi? _innerTube;

  PlaylistRepository(this._db, {InnerTubeMusicApi? innerTube})
      : _innerTube = innerTube,
        super(const []) {
    refresh();
    collapseDuplicateLikedRows();
  }

  /// Current rows for callers that are not the notifier itself.
  List<SavedPlaylist> get all => state;

  void refresh() {
    final rows = _db.raw.select(
      'SELECT * FROM saved_playlists ORDER BY is_pinned DESC, created_at_millis DESC;',
    );
    state = rows.map((r) {
      List<StoredTrack> tracks = const [];
      try {
        final decoded = jsonDecode(r['tracks_json'] as String);
        if (decoded is List) {
          tracks = decoded
              .whereType<Map<String, dynamic>>()
              .map(StoredTrack.fromJson)
              .toList();
        }
      } catch (_) {}
      return SavedPlaylist(
        id: r['id'] as int,
        title: r['title'] as String? ?? '',
        subtitle: r['subtitle'] as String? ?? '',
        mode: r['mode'] as String? ?? 'custom',
        tracks: tracks,
        createdAtMillis: r['created_at_millis'] as int? ?? 0,
        isPinned: (r['is_pinned'] as int? ?? 0) == 1,
        customCoverUri: r['custom_cover_uri'] as String? ?? '',
      );
    }).toList();
  }

  /// Collapses pre-existing duplicate Liked Songs rows into the one with the
  /// most tracks, merging distinct tracks and deleting leftovers from SQLite.
  /// Mirrors Android LikedSongsManager.collapseDuplicateLikedRows.
  void collapseDuplicateLikedRows() {
    final liked = state.where((p) => p.isLikedSongs).toList();
    if (liked.length <= 1) return;
    liked.sort((a, b) {
      final cmp = b.tracks.length.compareTo(a.tracks.length);
      if (cmp != 0) return cmp;
      return a.createdAtMillis.compareTo(b.createdAtMillis);
    });
    final keeper = liked.first;
    final others = liked.sublist(1);

    final seen = <String>{};
    final merged = <StoredTrack>[];
    for (final p in liked) {
      for (final t in p.tracks) {
        final key = '${t.name.toLowerCase()}|${t.artist.toLowerCase()}';
        if (seen.add(key)) {
          merged.add(t);
        }
      }
    }

    _db.raw.execute(
      'UPDATE saved_playlists SET title = ?, subtitle = ?, mode = ?, tracks_json = ? WHERE id = ?;',
      [
        SavedPlaylist.likedTitle,
        'Your loved tracks',
        SavedPlaylist.likedMode,
        jsonEncode(merged.map((t) => t.toJson()).toList()),
        keeper.id,
      ],
    );
    for (final other in others) {
      _db.raw.execute('DELETE FROM saved_playlists WHERE id = ?;', [other.id]);
    }
    refresh();
  }

  /// Creation id for a playlist row. Millisecond timestamps collide when
  /// two rows are created inside the same millisecond (library seeding
  /// plus an immediate "New playlist"), which the primary key rejects;
  /// keep it monotonic against what the table already holds.
  int _newId() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final row = _db.raw.select('SELECT MAX(id) AS m FROM saved_playlists;').first;
    final maxId = (row['m'] as int?) ?? 0;
    return now > maxId ? now : maxId + 1;
  }

  Future<SavedPlaylist> ensureLikedSongs() async {
    collapseDuplicateLikedRows();
    final existing = state.where((p) => p.isLikedSongs);
    if (existing.isNotEmpty) return existing.first;
    final id = _newId();
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.raw.execute(
      'INSERT INTO saved_playlists(id, title, subtitle, mode, tracks_json, created_at_millis, is_pinned) '
      'VALUES(?, ?, ?, ?, ?, ?, 1);',
      [id, SavedPlaylist.likedTitle, 'Your loved tracks', SavedPlaylist.likedMode, '[]', now],
    );
    refresh();
    return state.firstWhere((p) => p.isLikedSongs);
  }

  Set<String> likedKeys() {
    final liked = state.where((p) => p.isLikedSongs);
    if (liked.isEmpty) return const {};
    return liked.first.tracks
        .map((t) =>
            '${t.name.toLowerCase()}|${t.artist.toLowerCase()}')
        .toSet();
  }

  Future<SavedPlaylist> createCustom(String title) async {
    final clean = title.trim();
    if (clean.toLowerCase() == SavedPlaylist.likedTitle.toLowerCase() ||
        clean.toLowerCase() == 'liked music') {
      return ensureLikedSongs();
    }
    final existing = state.where((p) =>
        p.mode == 'custom' && p.title.toLowerCase() == clean.toLowerCase());
    if (existing.isNotEmpty) return existing.first;

    final id = _newId();
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.raw.execute(
      'INSERT INTO saved_playlists(id, title, mode, tracks_json, created_at_millis) '
      'VALUES(?, ?, ?, ?, ?);',
      [id, clean, 'custom', '[]', now],
    );
    refresh();
    return state.firstWhere((p) => p.id == id);
  }

  Future<void> rename(int id, String title) async {
    _db.raw.execute(
      'UPDATE saved_playlists SET title = ? WHERE id = ?;',
      [title.trim(), id],
    );
    refresh();
  }

  Future<void> setPinned(int id, bool pinned) async {
    _db.raw.execute(
      'UPDATE saved_playlists SET is_pinned = ? WHERE id = ?;',
      [pinned ? 1 : 0, id],
    );
    refresh();
  }

  Future<void> delete(int id) async {
    _db.raw.execute('DELETE FROM saved_playlists WHERE id = ?;', [id]);
    refresh();
  }

  Future<bool> addTrack(int id, StoredTrack track) async {
    final playlist = state.firstWhere((p) => p.id == id);
    final key =
        '${track.name.toLowerCase()}|${track.artist.toLowerCase()}';
    final exists = playlist.tracks.any((t) =>
        '${t.name.toLowerCase()}|${t.artist.toLowerCase()}' == key);
    if (exists) return false;
    final stamped = track.addedAtMillis == 0
        ? StoredTrack(
            name: track.name,
            artist: track.artist,
            artworkUrl: track.artworkUrl,
            videoId: track.videoId,
            album: track.album,
            durationSeconds: track.durationSeconds,
            playbackUrl: track.playbackUrl,
            addedAtMillis: DateTime.now().millisecondsSinceEpoch,
          )
        : track;
    final updated = [...playlist.tracks, stamped];
    _db.raw.execute(
      'UPDATE saved_playlists SET tracks_json = ? WHERE id = ?;',
      [jsonEncode(updated.map((t) => t.toJson()).toList()), id],
    );
    refresh();
    return true;
  }

  Future<void> removeTrack(int id, String trackKey) async {
    final playlist = state.firstWhere((p) => p.id == id);
    final updated = playlist.tracks
        .where((t) =>
            '${t.name.toLowerCase()}|${t.artist.toLowerCase()}' !=
            trackKey)
        .toList();
    _db.raw.execute(
      'UPDATE saved_playlists SET tracks_json = ? WHERE id = ?;',
      [jsonEncode(updated.map((t) => t.toJson()).toList()), id],
    );
    refresh();
  }

  Future<void> replaceTracks(int id, List<StoredTrack> tracks) async {
    _db.raw.execute(
      'UPDATE saved_playlists SET tracks_json = ? WHERE id = ?;',
      [jsonEncode(tracks.map((t) => t.toJson()).toList()), id],
    );
    refresh();
  }

  Future<SavedPlaylist> ensureLocalSongs() async {
    final existing = state.where((p) => p.isLocal);
    if (existing.isNotEmpty) return existing.first;
    final id = _newId();
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.raw.execute(
      'INSERT INTO saved_playlists(id, title, subtitle, mode, tracks_json, created_at_millis, is_pinned) '
      'VALUES(?, ?, ?, ?, ?, ?, 0);',
      [
        id,
        SavedPlaylist.localTitle,
        'Files from folders you added',
        SavedPlaylist.localMode,
        '[]',
        now,
      ],
    );
    refresh();
    return state.firstWhere((p) => p.id == id);
  }

  Future<SavedPlaylist> saveGenerated(
    String title,
    List<StoredTrack> tracks,
  ) async {
    final clean = title.trim().isEmpty ? 'Generated mix' : title.trim();
    final existing = state.where((p) =>
        p.mode == 'custom' && p.title.toLowerCase() == clean.toLowerCase());
    if (existing.isNotEmpty) {
      await replaceTracks(existing.first.id, tracks);
      return state.firstWhere((p) => p.id == existing.first.id);
    }
    final created = await createCustom(clean);
    await replaceTracks(created.id, tracks);
    return state.firstWhere((p) => p.id == created.id);
  }

  Future<void> setCustomCover(int id, String sourcePath) async {
    final dir = await getApplicationSupportDirectory();
    final covers = Directory(p.join(dir.path, 'playlist_covers'));
    if (!await covers.exists()) await covers.create(recursive: true);
    final ext = p.extension(sourcePath);
    final dest = p.join(covers.path, '$id${ext.isEmpty ? '.jpg' : ext}');
    await File(sourcePath).copy(dest);
    _db.raw.execute(
      'UPDATE saved_playlists SET custom_cover_uri = ? WHERE id = ?;',
      [dest, id],
    );
    refresh();
  }

  /// Idempotent like toggle; returns new liked state.
  /// Also mirrors to connected YouTube Music account's Liked Music auto playlist.
  Future<bool> toggleLiked(StoredTrack track) async {
    final liked = await ensureLikedSongs();
    final key =
        '${track.name.toLowerCase()}|${track.artist.toLowerCase()}';
    final isLiked = liked.tracks.any((t) =>
        '${t.name.toLowerCase()}|${t.artist.toLowerCase()}' == key);
    final result = !isLiked;
    if (isLiked) {
      await removeTrack(liked.id, key);
    } else {
      await addTrack(liked.id, track);
    }

    final tube = _innerTube;
    if (tube != null && tube.connection.connected) {
      unawaited(() async {
        try {
          var vid = track.videoId;
          if (vid.isEmpty) {
            final hit = await tube.searchSongs('${track.name} ${track.artist}', limit: 1);
            if (hit.isNotEmpty) {
              vid = hit.first.videoId;
            }
          }
          if (vid.isNotEmpty) {
            if (result) {
              await tube.likeVideo(vid);
            } else {
              await tube.removeVideoLike(vid);
            }
          }
        } catch (_) {}
      }());
    }

    return result;
  }

  /// Insert or replace one playlist row from a backup. Caller decides
  /// whether a newer local row may be overwritten.
  void upsertBackupRow({
    required int id,
    required String title,
    required String subtitle,
    required String mode,
    required String tracksJson,
    required int createdAtMillis,
    required bool isPinned,
    String? discoverSignature,
    String? customCoverUri,
  }) {
    _db.raw.execute(
      'INSERT INTO saved_playlists('
      'id, title, subtitle, mode, tracks_json, created_at_millis, '
      'discover_signature, custom_cover_uri, is_pinned) '
      'VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET '
      'title = excluded.title, subtitle = excluded.subtitle, '
      'mode = excluded.mode, tracks_json = excluded.tracks_json, '
      'created_at_millis = excluded.created_at_millis, '
      'discover_signature = excluded.discover_signature, '
      'custom_cover_uri = excluded.custom_cover_uri, '
      'is_pinned = excluded.is_pinned;',
      [
        id,
        title,
        subtitle,
        mode,
        tracksJson,
        createdAtMillis,
        discoverSignature,
        customCoverUri,
        isPinned ? 1 : 0,
      ],
    );
  }
}

final playlistRepositoryProvider =
    StateNotifierProvider<PlaylistRepository, List<SavedPlaylist>>(
        (ref) {
  return PlaylistRepository(
    ref.watch(databaseProvider),
    innerTube: ref.watch(innerTubeProvider),
  );
});
