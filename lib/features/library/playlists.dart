import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/stream_models.dart';
import '../../core/storage/app_database.dart';
import '../search/shared_providers.dart';

/// Stored playlist track (JSON-serialised inside `saved_playlists`).
class StoredTrack {
  final String name;
  final String artist;
  final String artworkUrl;
  final String videoId;

  const StoredTrack({
    required this.name,
    required this.artist,
    this.artworkUrl = '',
    this.videoId = '',
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'artist': artist,
        'artworkUrl': artworkUrl,
        'videoId': videoId,
      };

  factory StoredTrack.fromJson(Map<String, dynamic> json) =>
      StoredTrack(
        name: json['name']?.toString() ?? '',
        artist: json['artist']?.toString() ?? '',
        artworkUrl: json['artworkUrl']?.toString() ?? '',
        videoId: json['videoId']?.toString() ??
            json['youtubeVideoId']?.toString() ??
            '',
      );

  PlayableTrack toPlayable() => PlayableTrack(
        title: name,
        artist: artist,
        artworkUrl: artworkUrl,
        videoId: videoId,
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

  bool get isLikedSongs => mode == likedMode;
}

/// Playlist + liked-songs repository backed by SQLite.
/// Mirrors Android `PlaylistRepository` + `LikedSongsManager`.
class PlaylistRepository extends StateNotifier<List<SavedPlaylist>> {
  final AppDatabase _db;

  PlaylistRepository(this._db) : super(const []) {
    refresh();
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

  Future<SavedPlaylist> ensureLikedSongs() async {
    final existing = state.where((p) => p.isLikedSongs);
    if (existing.isNotEmpty) return existing.first;
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.raw.execute(
      'INSERT INTO saved_playlists(id, title, subtitle, mode, tracks_json, created_at_millis, is_pinned) '
      'VALUES(?, ?, ?, ?, ?, ?, 1);',
      [now, SavedPlaylist.likedTitle, 'Your loved tracks', SavedPlaylist.likedMode, '[]', now],
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
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.raw.execute(
      'INSERT INTO saved_playlists(id, title, mode, tracks_json, created_at_millis) '
      'VALUES(?, ?, ?, ?, ?);',
      [now, title.trim(), 'custom', '[]', now],
    );
    refresh();
    return state.firstWhere((p) => p.id == now);
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
  Future<bool> toggleLiked(StoredTrack track) async {
    final liked = await ensureLikedSongs();
    final key =
        '${track.name.toLowerCase()}|${track.artist.toLowerCase()}';
    final isLiked = liked.tracks.any((t) =>
        '${t.name.toLowerCase()}|${t.artist.toLowerCase()}' == key);
    if (isLiked) {
      await removeTrack(liked.id, key);
      return false;
    } else {
      await addTrack(liked.id, track);
      return true;
    }
  }
}

final playlistRepositoryProvider =
    StateNotifierProvider<PlaylistRepository, List<SavedPlaylist>>(
        (ref) {
  return PlaylistRepository(ref.watch(databaseProvider));
});
