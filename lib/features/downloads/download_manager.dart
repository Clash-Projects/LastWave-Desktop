import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/audio/stream_models.dart';
import '../../core/network/dio_factory.dart';
import '../../core/storage/app_database.dart';
import '../../core/storage/prefs.dart';
import '../innertube/innertube_api.dart';
import '../addons/addon_api.dart';
import '../lossless/lossless_source.dart';
import '../lyrics/lyrics_repository.dart';
import '../search/shared_providers.dart';

enum DownloadStatus { queued, downloading, done, error }

class DownloadEntry {
  final String key;
  final String title;
  final String artist;
  final DownloadStatus status;
  final double progress;
  final String badge;
  final String? filePath;
  final String? error;

  const DownloadEntry({
    required this.key,
    required this.title,
    required this.artist,
    this.status = DownloadStatus.queued,
    this.progress = 0,
    this.badge = '',
    this.filePath,
    this.error,
  });

  DownloadEntry copyWith({
    DownloadStatus? status,
    double? progress,
    String? badge,
    String? filePath,
    String? error,
  }) =>
      DownloadEntry(
        key: key,
        title: title,
        artist: artist,
        status: status ?? this.status,
        progress: progress ?? this.progress,
        badge: badge ?? this.badge,
        filePath: filePath ?? this.filePath,
        error: error ?? this.error,
      );
}

/// Offline download manager.
///
/// Ports the behaviour of Android `TrackDownloadManager` for desktop:
/// lossless-first resolution (configurable quality), YouTube fallback,
/// `.lrc` sidecar lyrics, SQLite registry, files under
/// `Music/LastWave` (or app documents when Music is unavailable).
class DownloadManager extends StateNotifier<List<DownloadEntry>> {
  final Dio _dio;
  final AppDatabase _db;
  final Prefs _prefs;
  final LosslessSource _lossless;
  final InnerTubeMusicApi _tube;
  final LyricsRepository _lyrics;
  final Set<String> _active = {};

  DownloadManager(
    this._db,
    this._prefs,
    this._lossless,
    this._tube,
    this._lyrics, [
    Dio? dio,
  ])  : _dio = dio ?? DioFactory.create(),
        super(const []) {
    _loadExisting();
  }

  static String keyOf(String title, String artist) =>
      '${artist.toLowerCase().trim()}|${title.toLowerCase().trim()}';

  void _loadExisting() {
    final rows = _db.raw.select(
      'SELECT track_key, title, artist, file_path, format_badge FROM downloaded_tracks '
      'ORDER BY downloaded_at_millis DESC;',
    );
    state = rows
        .map((r) => DownloadEntry(
              key: r['track_key'] as String? ?? '',
              title: r['title'] as String? ?? '',
              artist: r['artist'] as String? ?? '',
              status: DownloadStatus.done,
              progress: 1,
              badge: r['format_badge'] as String? ?? '',
              filePath: r['file_path'] as String?,
            ))
        .toList();
  }

  bool isDownloaded(String title, String artist) {
    final key = keyOf(title, artist);
    final rows = _db.raw.select(
      'SELECT id FROM downloaded_tracks WHERE track_key = ?;',
      [key],
    );
    return rows.isNotEmpty;
  }

  String? localPathFor(String title, String artist) {
    final rows = _db.raw.select(
      'SELECT file_path FROM downloaded_tracks WHERE track_key = ?;',
      [keyOf(title, artist)],
    );
    if (rows.isEmpty) return null;
    final path = rows.first['file_path'] as String? ?? '';
    if (path.isEmpty || !File(path).existsSync()) return null;
    return path;
  }

  Future<Directory> _musicDir() async {
    try {
      final music = await getDownloadsDirectory();
      // Prefer ~/Music/LastWave when available.
      if (music != null) {
        final parent = Directory(music.path).parent;
        final candidates = [
          Directory(p.join(parent.path, 'Music', 'LastWave')),
          Directory(p.join(music.path, 'LastWave')),
        ];
        for (final c in candidates) {
          try {
            await c.create(recursive: true);
            return c;
          } catch (_) {}
        }
      }
    } catch (_) {}
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'LastWave'));
    await dir.create(recursive: true);
    return dir;
  }

  String _sanitize(String s) =>
      s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();

  void _upsert(DownloadEntry entry) {
    final others = state.where((e) => e.key != entry.key).toList();
    state = [entry, ...others];
  }

  Future<void> downloadTrack({
    required String title,
    required String artist,
    String album = '',
    String artworkUrl = '',
  }) async {
    final key = keyOf(title, artist);
    if (_active.contains(key) || isDownloaded(title, artist)) return;
    _active.add(key);
    _upsert(DownloadEntry(
      key: key,
      title: title,
      artist: artist,
      status: DownloadStatus.downloading,
    ));
    try {
      ResolvedStream? stream;
      var badge = '';
      var isLossless = false;
      var ext = 'm4a';

      if (_prefs.preferLossless &&
          _prefs.downloadQuality !=
              AudioQualityTiers.youtubeOnly &&
          _lossless.isConfigured) {
        try {
          stream = await _lossless
              .resolveStream(
                title: title,
                artist: artist,
                album: album,
                preferredQuality: _prefs.downloadQuality,
              )
              .timeout(const Duration(seconds: 30));
        } catch (_) {
          stream = null;
        }
        if (stream != null) {
          isLossless = stream.isLossless;
          badge = stream.qualityBadge;
          ext = stream.audioCodec.contains('MP3') ? 'mp3' : 'flac';
        }
      }
      if (stream == null) {
        final match = await _tube.findBestMatchOrNull(title, artist);
        if (match == null) {
          throw Exception('No playable source found');
        }
        final yt = await _tube.resolveAudioStream(match.videoId);
        if (yt == null) throw Exception('Stream unavailable');
        stream = yt;
        badge = 'OPUS';
        ext = yt.mimeType.contains('mp4') ? 'm4a' : 'webm';
      }

      final dir = await _musicDir();
      final file = File(
          p.join(dir.path, '${_sanitize('$artist - $title')}.$ext'));
      await _dio.download(
        stream.url,
        file.path,
        options: Options(headers: stream.requestHeaders),
        onReceiveProgress: (received, total) {
          if (total > 0) {
            _upsert(DownloadEntry(
              key: key,
              title: title,
              artist: artist,
              status: DownloadStatus.downloading,
              progress: received / total,
              badge: badge,
            ));
          }
        },
      );

      // Lyrics sidecar.
      var lrcPath = '';
      if (_prefs.downloadLyrics) {
        try {
          final lyrics = await _lyrics.getLyrics(
            title: title,
            artist: artist,
            album: album,
            wordByWord: false,
          );
          if (lyrics.isSynced && lyrics.lines.isNotEmpty) {
            final buf = StringBuffer();
            for (final line in lyrics.lines) {
              final m = (line.timeMs ~/ 60000).toString().padLeft(2, '0');
              final s = ((line.timeMs % 60000) ~/ 1000)
                  .toString()
                  .padLeft(2, '0');
              final ms = ((line.timeMs % 1000) ~/ 10)
                  .toString()
                  .padLeft(2, '0');
              buf.writeln('[$m:$s.$ms]${line.text}');
            }
            final lrc = File('${file.path}.lrc');
            await lrc.writeAsString(buf.toString());
            lrcPath = lrc.path;
          }
        } catch (_) {}
      }

      final stat = await file.stat();
      _db.raw.execute(
        'INSERT INTO downloaded_tracks(track_key, title, artist, album, artwork_url, file_path, '
        'file_size_bytes, format_badge, is_lossless, has_lyrics, lrc_file_path, downloaded_at_millis) '
        'VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
        'ON CONFLICT(track_key) DO UPDATE SET file_path = excluded.file_path, '
        'file_size_bytes = excluded.file_size_bytes, format_badge = excluded.format_badge, '
        'lrc_file_path = excluded.lrc_file_path, downloaded_at_millis = excluded.downloaded_at_millis;',
        [
          key,
          title,
          artist,
          album,
          artworkUrl,
          file.path,
          stat.size,
          badge,
          isLossless ? 1 : 0,
          lrcPath.isNotEmpty ? 1 : 0,
          lrcPath,
          DateTime.now().millisecondsSinceEpoch,
        ],
      );
      _upsert(DownloadEntry(
        key: key,
        title: title,
        artist: artist,
        status: DownloadStatus.done,
        progress: 1,
        badge: badge,
        filePath: file.path,
      ));
    } catch (e) {
      _upsert(DownloadEntry(
        key: key,
        title: title,
        artist: artist,
        status: DownloadStatus.error,
        error: e.toString(),
      ));
    } finally {
      _active.remove(key);
    }
  }

  Future<void> delete(String key) async {
    final entry = state.where((e) => e.key == key).firstOrNull;
    final filePath = entry?.filePath;
    if (filePath != null) {
      try {
        await File(filePath).delete();
      } catch (_) {}
      try {
        await File('$filePath.lrc').delete();
      } catch (_) {}
    }
    _db.raw.execute(
      'DELETE FROM downloaded_tracks WHERE track_key = ?;',
      [key],
    );
    state = state.where((e) => e.key != key).toList();
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

final downloadManagerProvider =
    StateNotifierProvider<DownloadManager, List<DownloadEntry>>(
        (ref) {
  return DownloadManager(
    ref.watch(databaseProvider),
    ref.watch(prefsProvider),
    ref.watch(losslessApiProvider),
    ref.watch(innerTubeProvider),
    ref.watch(lyricsRepositoryProvider),
  );
});
