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
/// - `local_plays` (v5: on-device play log driving the keyless-guest
///   taste algorithm — no Last.fm account needed)
///
/// Migrations are additive and never drop user data (no destructive
/// fallback, unlike the temporary Android `fallbackToDestructiveMigration`).
class AppDatabase {
  static const int schemaVersion = 6;

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
    if (version < 5) {
      _createV5();
      _db.execute('PRAGMA user_version=5;');
    }
    if (version < 6) {
      _createV6();
      _db.execute('PRAGMA user_version=6;');
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

  // -- recommendation exclusions ("don't recommend") --------------------
  //
  // Key format matches GeneratedTrack.key / HomeTrack.key exactly
  // ('name|artist', lowercased) so feed filtering is a set lookup.

  static String exclusionKey(String name, String artist) =>
      '${name.toLowerCase()}|${artist.toLowerCase()}';

  Set<String> loadExclusionKeys() {
    return {
      for (final r in _db.select(
          'SELECT track_key FROM recommendation_exclusions;'))
        (r['track_key'] as String?) ?? '',
    }..remove('');
  }

  void addExclusion({
    required String name,
    required String artist,
  }) {
    _db.execute(
      'INSERT OR REPLACE INTO recommendation_exclusions '
      '(track_key, excluded_at_millis, track_name, artist_name) '
      'VALUES (?, ?, ?, ?);',
      [
        exclusionKey(name, artist),
        DateTime.now().millisecondsSinceEpoch,
        name,
        artist,
      ],
    );
  }

  void removeExclusion(String key) {
    _db.execute(
        'DELETE FROM recommendation_exclusions WHERE track_key = ?;',
        [key]);
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
        watchtime_url TEXT NOT NULL DEFAULT '',
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

  void _createV5() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS local_plays (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL DEFAULT '',
        artist TEXT NOT NULL DEFAULT '',
        played_at_millis INTEGER NOT NULL DEFAULT 0
      );
    ''');
    _db.execute('''
      CREATE INDEX IF NOT EXISTS idx_local_plays_recent
      ON local_plays(played_at_millis DESC);
    ''');
  }

  /// v6: pre-signed YT watchtime base on cached streams, so repeat
  /// plays (served from disk without a fresh player response) can
  /// still sync watch history with session-bound tokens.
  void _createV6() {
    try {
      _db.execute(
        'ALTER TABLE stream_cache ADD COLUMN watchtime_url '
        'TEXT NOT NULL DEFAULT \'\';',
      );
    } catch (_) {}
  }

  // -- local play log (keyless-guest taste) --------------------------------
  //
  // Every resolved track opening records one row (see PlaybackService),
  // capped at 500 newest. Same track replayed within 10 minutes is not
  // re-logged (repeat-one would spam). Powers affinities, discovery
  // seeds, jump-back-in and personal-mix seeds without any account.

  /// Max rows kept; oldest pruned on insert.
  static const int localPlaysCap = 500;

  void recordLocalPlay({required String title, required String artist}) {
    final t = title.trim();
    final a = artist.trim();
    if (t.isEmpty || a.isEmpty) return;
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final last = _db.select(
        'SELECT title, artist, played_at_millis FROM local_plays '
        'ORDER BY id DESC LIMIT 1;',
      );
      if (last.isNotEmpty) {
        final lt = (last.first['title'] as String?) ?? '';
        final la = (last.first['artist'] as String?) ?? '';
        final lat = (last.first['played_at_millis'] as int?) ?? 0;
        if (lt == t && la == a && now - lat < 10 * 60 * 1000) return;
      }
      _db.execute(
        'INSERT INTO local_plays (title, artist, played_at_millis) '
        'VALUES (?, ?, ?);',
        [t, a, now],
      );
      _db.execute(
        'DELETE FROM local_plays WHERE id NOT IN ('
        'SELECT id FROM local_plays ORDER BY id DESC LIMIT ?);',
        [localPlaysCap],
      );
    } catch (_) {}
  }

  List<({String title, String artist, int atMillis})> loadRecentPlays({
    int limit = 100,
  }) {
    try {
      return _db
          .select(
            'SELECT title, artist, played_at_millis FROM local_plays '
            'ORDER BY id DESC LIMIT ?;',
            [limit],
          )
          .map((r) => (
                title: (r['title'] as String?) ?? '',
                artist: (r['artist'] as String?) ?? '',
                atMillis:
                    (r['played_at_millis'] as int?) ?? 0,
              ))
          .where((p) => p.title.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  List<Map<String, Object?>> loadStreamEntries({int limit = 256}) {
    try {
      // watchtime_url may be absent on pre-v6 rows if the migration
      // was skipped: fall back to the v5 column list.
      try {
        return _db
            .select(
              'SELECT video_id, client_profile, itag, url, headers_json, '
              'mime, bitrate_kbps, codec, expires_at_ms, cached_at_ms, '
              'auth_scope, watchtime_url FROM stream_cache '
              'ORDER BY cached_at_ms DESC LIMIT ?;',
              [limit],
            )
            .map((r) => Map<String, Object?>.from(r))
            .toList();
      } catch (_) {
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
      }
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
    String watchtimeUrl = '',
  }) {
    try {
      // v6 column when migrated; plain v5 insert otherwise.
      try {
        _db.execute(
          'INSERT INTO stream_cache(video_id, client_profile, itag, url, '
          'headers_json, mime, bitrate_kbps, codec, expires_at_ms, '
          'cached_at_ms, auth_scope, watchtime_url) '
          'VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
          'ON CONFLICT(video_id, client_profile, itag, auth_scope) '
          'DO UPDATE SET url = excluded.url, '
          'headers_json = excluded.headers_json, mime = excluded.mime, '
          'bitrate_kbps = excluded.bitrate_kbps, codec = excluded.codec, '
          'expires_at_ms = excluded.expires_at_ms, '
          'cached_at_ms = excluded.cached_at_ms, '
          'watchtime_url = excluded.watchtime_url;',
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
            watchtimeUrl,
          ],
        );
      } catch (_) {
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
      }
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
