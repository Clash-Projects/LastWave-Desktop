import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

/// Desktop persistent storage. Schema mirrors LastWave-native
/// `AppDatabase` (Room, v12) tables plus desktop additions:
/// - `artwork_cache`, `recommendation_exclusions`, `saved_playlists`,
///   `downloaded_tracks` (same logical columns)
/// - `kv_store` (DataStore/ prefs equivalent for misc state)
/// - `playback_session` (single-row persisted queue snapshot)
/// - `search_history` (replaces SharedPreferences query list)
///
/// Migrations are additive and never drop user data (no destructive
/// fallback, unlike the temporary Android `fallbackToDestructiveMigration`).
class AppDatabase {
  static const int schemaVersion = 4;

  final Database _db;

  AppDatabase._(this._db);

  static Future<AppDatabase> open() async {
    final dir = await getApplicationSupportDirectory();
    final file = p.join(dir.path, 'lastwave.db');
    final db = sqlite3.open(file);
    final instance = AppDatabase._(db);
    instance._migrate();
    return instance;
  }

  /// In-memory instance for tests.
  factory AppDatabase.inMemory() {
    final db = sqlite3.openInMemory();
    final instance = AppDatabase._(db);
    instance._migrate();
    return instance;
  }

  Database get raw => _db;

  void _migrate() {
    _db.execute('PRAGMA journal_mode=WAL;');
    final version =
        _db.select('PRAGMA user_version;').first['user_version'] as int;
    if (version < 1) {
      _createV1();
      _db.execute('PRAGMA user_version=1;');
    }
    if (version < 2) {
      _createV2();
      _db.execute('PRAGMA user_version=2;');
    }
    if (version < 3) {
      _createV3();
      _db.execute('PRAGMA user_version=3;');
    }
    if (version < 4) {
      _createV4();
      _db.execute('PRAGMA user_version=4;');
    }
  }

  void _createV1() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS artwork_cache (
        cache_key TEXT PRIMARY KEY,
        url TEXT NOT NULL DEFAULT '',
        provider TEXT NOT NULL DEFAULT '',
        timestamp_millis INTEGER NOT NULL DEFAULT 0
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS recommendation_exclusions (
        track_key TEXT PRIMARY KEY,
        excluded_at_millis INTEGER NOT NULL DEFAULT 0,
        track_name TEXT NOT NULL DEFAULT '',
        artist_name TEXT NOT NULL DEFAULT ''
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS saved_playlists (
        id INTEGER PRIMARY KEY,
        title TEXT NOT NULL DEFAULT '',
        subtitle TEXT NOT NULL DEFAULT '',
        mode TEXT NOT NULL DEFAULT 'custom',
        tracks_json TEXT NOT NULL DEFAULT '[]',
        created_at_millis INTEGER NOT NULL DEFAULT 0,
        discover_signature TEXT,
        custom_cover_uri TEXT,
        is_pinned INTEGER NOT NULL DEFAULT 0
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS downloaded_tracks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        track_key TEXT NOT NULL,
        title TEXT NOT NULL DEFAULT '',
        artist TEXT NOT NULL DEFAULT '',
        album TEXT NOT NULL DEFAULT '',
        artwork_url TEXT NOT NULL DEFAULT '',
        file_path TEXT NOT NULL DEFAULT '',
        file_size_bytes INTEGER NOT NULL DEFAULT 0,
        format_badge TEXT NOT NULL DEFAULT '',
        duration_ms INTEGER NOT NULL DEFAULT 0,
        bitrate_kbps INTEGER NOT NULL DEFAULT 0,
        is_lossless INTEGER NOT NULL DEFAULT 0,
        has_lyrics INTEGER NOT NULL DEFAULT 0,
        lrc_file_path TEXT NOT NULL DEFAULT '',
        downloaded_at_millis INTEGER NOT NULL DEFAULT 0
      );
    ''');
    _db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_downloaded_track_key
      ON downloaded_tracks(track_key);
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS kv_store (
        k TEXT PRIMARY KEY,
        v TEXT NOT NULL DEFAULT ''
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS playback_session (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        payload_json TEXT NOT NULL DEFAULT '{}'
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS search_history (
        query TEXT PRIMARY KEY,
        updated_at_millis INTEGER NOT NULL DEFAULT 0
      );
    ''');
  }

  // -- kv helpers ------------------------------------------------------

  String? kvGet(String key) {
    final rows =
        _db.select('SELECT v FROM kv_store WHERE k = ?', [key]);
    if (rows.isEmpty) return null;
    return rows.first['v'] as String;
  }

  void kvSet(String key, String value) {
    _db.execute(
      'INSERT INTO kv_store(k, v) VALUES(?, ?) '
      'ON CONFLICT(k) DO UPDATE SET v = excluded.v;',
      [key, value],
    );
  }

  // -- search history --------------------------------------------------

  List<String> loadSearchHistory({int limit = 25}) {
    return _db
        .select(
          'SELECT query FROM search_history '
          'ORDER BY updated_at_millis DESC LIMIT ?;',
          [limit],
        )
        .map((r) => r['query'] as String)
        .toList();
  }

  void pushSearchHistory(String query) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute(
      'INSERT INTO search_history(query, updated_at_millis) VALUES(?, ?) '
      'ON CONFLICT(query) DO UPDATE SET updated_at_millis = excluded.updated_at_millis;',
      [query, now],
    );
    _db.execute(
      'DELETE FROM search_history WHERE query NOT IN ('
      'SELECT query FROM search_history '
      'ORDER BY updated_at_millis DESC LIMIT 25);',
    );
  }

  void clearSearchHistory() {
    _db.execute('DELETE FROM search_history;');
  }

  void removeSearchHistory(String query) {
    _db.execute('DELETE FROM search_history WHERE query = ?;', [query]);
  }

  // -- playback session -------------------------------------------------

  Map<String, dynamic> loadPlaybackSession() {
    final rows = _db.select(
        'SELECT payload_json FROM playback_session WHERE id = 1;');
    if (rows.isEmpty) return const {};
    try {
      final decoded = jsonDecode(rows.first['payload_json'] as String);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return const {};
  }

  void savePlaybackSession(Map<String, dynamic> payload) {
    _db.execute(
      'INSERT INTO playback_session(id, payload_json) VALUES(1, ?) '
      'ON CONFLICT(id) DO UPDATE SET payload_json = excluded.payload_json;',
      [jsonEncode(payload)],
    );
  }

  void clearPlaybackSession() {
    _db.execute('DELETE FROM playback_session WHERE id = 1;');
  }

  // -- stream disk cache (Limusic fast-path) -------------------------------
  //
  // Persistent copy of resolved YouTube stream URLs + match metadata.
  // Memory cache stays authoritative for speed; disk is warm-start +
  // cross-restart reuse. Entries are keyed by
  // (video_id, client_profile, itag, auth_scope) and considered fresh
  // until `expires_at_ms - margin`. Only expiry or a real playback
  // failure (403) invalidates — no network probes on the hot path.

  void _createV2() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS stream_cache (
        video_id TEXT NOT NULL,
        client_profile TEXT NOT NULL DEFAULT '',
        itag INTEGER NOT NULL DEFAULT -1,
        url TEXT NOT NULL DEFAULT '',
        headers_json TEXT NOT NULL DEFAULT '{}',
        mime TEXT NOT NULL DEFAULT '',
        bitrate_kbps INTEGER NOT NULL DEFAULT 0,
        codec TEXT NOT NULL DEFAULT '',
        expires_at_ms INTEGER NOT NULL DEFAULT 0,
        cached_at_ms INTEGER NOT NULL DEFAULT 0,
        auth_scope TEXT NOT NULL DEFAULT 'anonymous',
        PRIMARY KEY (video_id, client_profile, itag, auth_scope)
      );
    ''');
    _db.execute('''
      CREATE INDEX IF NOT EXISTS idx_stream_cache_video
      ON stream_cache(video_id, cached_at_ms DESC);
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS match_cache (
        key TEXT PRIMARY KEY,
        video_id TEXT NOT NULL DEFAULT '',
        title TEXT NOT NULL DEFAULT '',
        artist TEXT NOT NULL DEFAULT '',
        album TEXT NOT NULL DEFAULT '',
        artwork_url TEXT NOT NULL DEFAULT '',
        updated_at_ms INTEGER NOT NULL DEFAULT 0
      );
    ''');
  }

  void _createV3() {
    try {
      _db.execute(
        'ALTER TABLE match_cache ADD COLUMN duration_seconds '
        'INTEGER NOT NULL DEFAULT 0;',
      );
    } catch (_) {}
  }

  void _createV4() {
    try {
      _db.execute('DELETE FROM match_cache;');
    } catch (_) {}
  }

  List<Map<String, Object?>> loadStreamEntries({int limit = 256}) {
    try {
      return _db
          .select(
            'SELECT video_id, client_profile, itag, url, headers_json, '
            'mime, bitrate_kbps, codec, expires_at_ms, cached_at_ms, '
            'auth_scope FROM stream_cache '
            'ORDER BY cached_at_ms DESC LIMIT ?;',
            [limit],
          )
          .map((r) => Map<String, Object?>.from(r))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  void saveStreamEntry({
    required String videoId,
    required String clientProfile,
    required int itag,
    required String url,
    required String headersJson,
    required String mime,
    required int bitrateKbps,
    required String codec,
    required int expiresAtMs,
    required int cachedAtMs,
    required String authScope,
  }) {
    try {
      _db.execute(
        'INSERT INTO stream_cache(video_id, client_profile, itag, url, '
        'headers_json, mime, bitrate_kbps, codec, expires_at_ms, '
        'cached_at_ms, auth_scope) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
        'ON CONFLICT(video_id, client_profile, itag, auth_scope) '
        'DO UPDATE SET url = excluded.url, '
        'headers_json = excluded.headers_json, mime = excluded.mime, '
        'bitrate_kbps = excluded.bitrate_kbps, codec = excluded.codec, '
        'expires_at_ms = excluded.expires_at_ms, '
        'cached_at_ms = excluded.cached_at_ms;',
        [
          videoId,
          clientProfile,
          itag,
          url,
          headersJson,
          mime,
          bitrateKbps,
          codec,
          expiresAtMs,
          cachedAtMs,
          authScope,
        ],
      );
      _db.execute(
        'DELETE FROM stream_cache WHERE rowid NOT IN ('
        'SELECT rowid FROM stream_cache '
        'ORDER BY cached_at_ms DESC LIMIT 256);',
      );
    } catch (_) {}
  }

  void deleteStreamEntries(String videoId) {
    try {
      _db.execute(
        'DELETE FROM stream_cache WHERE video_id = ?;',
        [videoId],
      );
    } catch (_) {}
  }

  void pruneExpiredStreams(int nowMs) {
    try {
      _db.execute(
        'DELETE FROM stream_cache WHERE expires_at_ms > 0 AND expires_at_ms < ?;',
        [nowMs],
      );
    } catch (_) {}
  }

  Map<String, Object?>? loadMatchEntry(String key) {
    try {
      final rows = _db.select(
        'SELECT key, video_id, title, artist, album, artwork_url, '
        'duration_seconds, updated_at_ms FROM match_cache WHERE key = ?;',
        [key],
      );
      if (rows.isEmpty) return null;
      return Map<String, Object?>.from(rows.first);
    } catch (_) {
      return null;
    }
  }

  void saveMatchEntry({
    required String key,
    required String videoId,
    required String title,
    required String artist,
    String album = '',
    String artworkUrl = '',
    int durationSeconds = 0,
  }) {
    try {
      _db.execute(
        'INSERT INTO match_cache(key, video_id, title, artist, album, '
        'artwork_url, duration_seconds, updated_at_ms) '
        'VALUES(?, ?, ?, ?, ?, ?, ?, ?) '
        'ON CONFLICT(key) DO UPDATE SET video_id = excluded.video_id, '
        'title = excluded.title, artist = excluded.artist, '
        'album = excluded.album, artwork_url = excluded.artwork_url, '
        'duration_seconds = excluded.duration_seconds, '
        'updated_at_ms = excluded.updated_at_ms;',
        [
          key,
          videoId,
          title,
          artist,
          album,
          artworkUrl,
          durationSeconds,
          DateTime.now().millisecondsSinceEpoch,
        ],
      );
      _db.execute(
        'DELETE FROM match_cache WHERE key NOT IN ('
        'SELECT key FROM match_cache '
        'ORDER BY updated_at_ms DESC LIMIT 1024);',
      );
    } catch (_) {}
  }

  void deleteMatchesForVideo(String videoId) {
    try {
      _db.execute(
        'DELETE FROM match_cache WHERE video_id = ?;',
        [videoId],
      );
    } catch (_) {}
  }

  // -- artwork cache ---------------------------------------------------

  Map<String, String>? loadArtworkEntry(String cacheKey) {
    try {
      final rows = _db.select(
        'SELECT url, provider FROM artwork_cache WHERE cache_key = ?;',
        [cacheKey],
      );
      if (rows.isEmpty) return null;
      return {
        'url': rows.first['url'] as String,
        'provider': rows.first['provider'] as String,
      };
    } catch (_) {
      return null;
    }
  }

  /// Same row as [loadArtworkEntry], plus [timestamp_millis] for TTL.
  Map<String, dynamic>? loadArtworkRecord(String cacheKey) {
    try {
      final rows = _db.select(
        'SELECT url, provider, timestamp_millis FROM artwork_cache '
        'WHERE cache_key = ?;',
        [cacheKey],
      );
      if (rows.isEmpty) return null;
      return {
        'url': rows.first['url'] as String,
        'provider': rows.first['provider'] as String,
        'timestamp_millis':
            (rows.first['timestamp_millis'] as num?)?.toInt() ?? 0,
      };
    } catch (_) {
      return null;
    }
  }

  void saveArtworkEntry({
    required String cacheKey,
    required String url,
    String provider = 'official',
  }) {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      _db.execute(
        'INSERT INTO artwork_cache(cache_key, url, provider, timestamp_millis) '
        'VALUES(?, ?, ?, ?) '
        'ON CONFLICT(cache_key) DO UPDATE SET '
        'url = excluded.url, '
        'provider = excluded.provider, '
        'timestamp_millis = excluded.timestamp_millis;',
        [cacheKey, url, provider, now],
      );
    } catch (_) {}
  }

  void close() => _db.close();
}
