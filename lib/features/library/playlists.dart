// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/stream_models.dart';
import '../../core/storage/app_database.dart';
import '../innertube/innertube_api.dart';
import '../khinsider/khinsider_parser.dart';
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

  /// Direct source the player opens instead of a YouTube match, e.g. a
  /// `khinsider://` track page. Empty for YouTube tracks.
  final String playbackUrl;

  const StoredTrack({
    required this.name,
    required this.artist,
    this.artworkUrl = '',
    this.videoId = '',
    this.album = '',
    this.durationSeconds = 0,
    this.playbackUrl = '',
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'artist': artist,
        'artworkUrl': artworkUrl,
        'videoId': videoId,
        'album': album,
        'durationSeconds': durationSeconds,
        if (playbackUrl.isNotEmpty) 'playbackUrl': playbackUrl,
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

  const SavedPlaylist({
    required this.id,
    required this.title,
    this.subtitle = '',
    this.mode = 'custom',
    this.tracks = const [],
    this.createdAtMillis = 0,
    this.isPinned = false,
  });

  bool get isLikedSongs =>
      mode == likedMode ||
      title.toLowerCase() == likedTitle.toLowerCase() ||
      title.toLowerCase() == 'liked music';
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
    final updated = [...playlist.tracks, track];
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
    // A KHInsider track has no YouTube twin: liking it must not like
    // whatever a name search turns up.
    if (tube != null &&
        tube.connection.connected &&
        !KhInsiderParser.isPlaybackUri(track.playbackUrl)) {
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
}

final playlistRepositoryProvider =
    StateNotifierProvider<PlaylistRepository, List<SavedPlaylist>>(
        (ref) {
  return PlaylistRepository(
    ref.watch(databaseProvider),
    innerTube: ref.watch(innerTubeProvider),
  );
});
