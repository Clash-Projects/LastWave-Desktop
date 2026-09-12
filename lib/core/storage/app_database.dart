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
  static const int schemaVersion = 1;

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

  void close() => _db.close();
}
