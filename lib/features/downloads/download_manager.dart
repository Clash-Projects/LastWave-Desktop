import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/artwork/official_artwork_service.dart';
import '../../core/audio/stream_models.dart';
import '../../core/network/dio_factory.dart';
import '../../core/storage/app_database.dart';
import '../../core/storage/prefs.dart';
import '../innertube/innertube_api.dart';
import '../addons/addon_api.dart';
import '../lossless/lossless_source.dart';
import '../lyrics/lyrics_models.dart';
import '../lyrics/lyrics_repository.dart';
import '../search/shared_providers.dart';
import 'media_tagger.dart';

enum DownloadStatus { queued, downloading, done, error }

class DownloadEntry {
  final String key;
  final String title;
  final String artist;
  final DownloadStatus status;
  final double progress;
  final String badge;

  /// Tagging outcome: `full` (all metadata incl. cover), `text`
  /// (tags without cover), `raw:<reason>` (untagged fallback), or ''
  /// for rows written before tracking existed.
  final String tagNote;
  final String? filePath;
  final String? error;

  const DownloadEntry({
    required this.key,
    required this.title,
    required this.artist,
    this.status = DownloadStatus.queued,
    this.progress = 0,
    this.badge = '',
    this.tagNote = '',
    this.filePath,
    this.error,
  });

  DownloadEntry copyWith({
    DownloadStatus? status,
    double? progress,
    String? badge,
    String? tagNote,
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
        tagNote: tagNote ?? this.tagNote,
        filePath: filePath ?? this.filePath,
        error: error ?? this.error,
      );
}

/// Offline download manager.
///
/// Ports the behaviour of Android `TrackDownloadManager` for desktop:
/// lossless-first resolution (configurable quality), YouTube Opus
/// fallback, embedded metadata (title/artist/album/lyrics/cover —
/// `.opus` via WebM remux, FLAC/MP3/M4A tagged in place), `.lrc`
/// sidecar lyrics, SQLite registry, files under the custom download
/// folder when set, else `Music/LastWave` (or app documents when
/// Music is unavailable).
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
    late final List rows;
    try {
      rows = _db.raw.select(
        'SELECT track_key, title, artist, file_path, format_badge, tag_status FROM downloaded_tracks '
        'ORDER BY downloaded_at_millis DESC;',
      );
    } catch (_) {
      // Pre-v7 databases without the tag_status column.
      rows = _db.raw.select(
        'SELECT track_key, title, artist, file_path, format_badge FROM downloaded_tracks '
        'ORDER BY downloaded_at_millis DESC;',
      );
    }
    state = rows
        .map((r) => DownloadEntry(
              key: r['track_key'] as String? ?? '',
              title: r['title'] as String? ?? '',
              artist: r['artist'] as String? ?? '',
              status: DownloadStatus.done,
              progress: 1,
              badge: r['format_badge'] as String? ?? '',
              tagNote: r['tag_status'] as String? ?? '',
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
    // Custom folder wins (Settings → Downloads, Downloads page).
    final custom = _prefs.downloadDir.trim();
    if (custom.isNotEmpty) {
      try {
        final dir = Directory(custom);
        await dir.create(recursive: true);
        return dir;
      } catch (_) {}
    }
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

  /// Audio payload for a resolved stream: local addon files are read,
  /// http sources stream into memory with progress on the entry.
  Future<Uint8List> _fetchAudioBytes(
    ResolvedStream stream,
    String key,
    String title,
    String artist,
    String badge,
  ) async {
    if (!stream.url.startsWith('http')) {
      return Uint8List.fromList(
          await File(stream.url).readAsBytes());
    }
    final res = await _dio.get<List<int>>(
      stream.url,
      options: Options(
        responseType: ResponseType.bytes,
        headers: stream.requestHeaders,
      ),
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
    return Uint8List.fromList(res.data ?? const <int>[]);
  }

  /// Cover bytes for the container tag: the caller's artwork URL when
  /// present, else the official studio cover, else the YTM match art.
  /// Null when nothing usable is found — tagging proceeds text-only.
  Future<({Uint8List bytes, String mime})?> _fetchCoverBytes(
    String title,
    String artist,
    String artworkUrl,
  ) async {
    var url = artworkUrl.trim();
    if (url.isEmpty) {
      try {
        final art = await OfficialArtworkService.instance
            .resolveOfficialArtwork(title: title, artist: artist)
            .timeout(const Duration(seconds: 8));
        url = art?.artworkUrl ?? '';
      } catch (_) {}
    }
    if (url.isEmpty) {
      try {
        final match = await _tube
            .findBestMatchOrNull(title, artist)
            .timeout(const Duration(seconds: 8),
                onTimeout: () => null);
        url = match?.artworkUrl ?? '';
      } catch (_) {}
    }
    if (url.isEmpty) return null;
    try {
      final res = await _dio
          .get<List<int>>(
            url,
            options: Options(responseType: ResponseType.bytes),
          )
          .timeout(const Duration(seconds: 15));
      final bytes = Uint8List.fromList(res.data ?? const <int>[]);
      if (bytes.length < 512 || bytes.length > 12 * 1024 * 1024) {
        return null;
      }
      final mime = MediaTagger.sniffImageMime(bytes);
      if (mime == null) return null;
      return (bytes: bytes, mime: mime);
    } catch (_) {
      return null;
    }
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
      var fromAddon = false;
      var ytCodecHint = '';

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
          fromAddon = true;
          badge = stream.qualityBadge;
        }
      }
      if (stream == null) {
        final match = await _tube.findBestMatchOrNull(title, artist);
        if (match == null) {
          throw Exception('No playable source found');
        }
        // Opus-first: YouTube's best lossy codec, probed before use.
        final opus =
            await _tube.resolveOpusDownloadStream(match.videoId);
        final yt = opus ?? await _tube.resolveAudioStream(match.videoId);
        if (yt == null) throw Exception('Stream unavailable');
        stream = yt;
        ytCodecHint = yt.audioCodec.toUpperCase();
      }

      // Audio bytes (progress surfaced on the entry for http sources).
      final audioBytes =
          await _fetchAudioBytes(stream, key, title, artist, badge);
      if (audioBytes.isEmpty) throw Exception('Empty audio payload');

      // Lyrics + cover in parallel: sidecar text, embeddable plain
      // text, and cover bytes for the container tag.
      final fetched = await Future.wait([
        _lyrics
            .getLyrics(
              title: title,
              artist: artist,
              album: album,
              wordByWord: false,
            )
            .timeout(const Duration(seconds: 20),
                onTimeout: () => const LyricsResult.empty()),
        _fetchCoverBytes(title, artist, artworkUrl),
      ]);
      final lyrics = fetched[0] as LyricsResult;
      final cover =
          fetched[1] as ({Uint8List bytes, String mime})?;

      // Lyrics sidecar content (synced lines only, as before).
      String? lrcContent;
      if (_prefs.downloadLyrics &&
          lyrics.isSynced &&
          lyrics.lines.isNotEmpty) {
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
        lrcContent = buf.toString();
      }
      final lyricsText = lyrics.lines.isNotEmpty
          ? lyrics.lines.map((l) => l.text).join('\n').trim()
          : lyrics.plainLyrics.trim();

      // Embed metadata, routed by the ACTUAL container magic — MIME
      // strings and extensions can disagree with the bytes (that
      // mismatch used to nuke the remux). Any tagging failure keeps
      // the raw bytes and records why: the download itself must never
      // be lost, and "just a song" must never be silent again.
      if (cover == null && kDebugMode) {
        debugPrint('LastWaveDownload no cover ($title — $artist)');
      }
      final tags = DownloadTags(
        title: title,
        artist: artist,
        album: album,
        lyrics: lyricsText,
        coverBytes: cover?.bytes,
        coverMime: cover?.mime ?? '',
      );
      final container = MediaTagger.detectContainer(audioBytes);
      var finalExt = 'webm';
      var outBytes = audioBytes;
      var tagStatus = 'raw:unknown-container';
      try {
        if (container == 'webm') {
          outBytes =
              MediaTagger.remuxWebmOpusToOgg(audioBytes, tags);
          finalExt = 'opus';
        } else if (container == 'mp4') {
          outBytes = MediaTagger.tagM4a(audioBytes, tags);
          finalExt = 'm4a';
        } else if (container == 'flac') {
          outBytes = MediaTagger.tagFlac(audioBytes, tags);
          finalExt = 'flac';
        } else if (container == 'mp3') {
          outBytes = MediaTagger.tagMp3(audioBytes, tags);
          finalExt = 'mp3';
        } else {
          throw const TaggerSkip('unknown container');
        }
        tagStatus = tags.hasCover ? 'full' : 'text';
        if (kDebugMode) {
          debugPrint('LastWaveDownload tagged $finalExt '
              '($tagStatus): $title — $artist');
        }
      } catch (e) {
        outBytes = audioBytes;
        finalExt = container == 'mp4'
            ? 'm4a'
            : container == 'flac'
                ? 'flac'
                : container == 'mp3'
                    ? 'mp3'
                    : 'webm';
        tagStatus =
            'raw:${e is TaggerSkip ? e.reason : 'tag-failed'}';
        if (kDebugMode) {
          debugPrint(
              'LastWaveDownload tag skipped ($title — $artist): $e');
        }
      }
      if (!fromAddon) {
        badge = container == 'webm'
            ? 'OPUS'
            : (ytCodecHint.isNotEmpty ? ytCodecHint : 'AUDIO');
      }

      final dir = await _musicDir();
      final file = File(p.join(
          dir.path, '${_sanitize('$artist - $title')}.$finalExt'));
      await file.writeAsBytes(outBytes, flush: true);

      var lrcPath = '';
      if (lrcContent != null) {
        try {
          final lrc = File('${file.path}.lrc');
          await lrc.writeAsString(lrcContent);
          lrcPath = lrc.path;
        } catch (_) {}
      }

      final stat = await file.stat();
      try {
        _db.raw.execute(
          'INSERT INTO downloaded_tracks(track_key, title, artist, album, artwork_url, file_path, '
          'file_size_bytes, format_badge, tag_status, is_lossless, has_lyrics, lrc_file_path, downloaded_at_millis) '
          'VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
          'ON CONFLICT(track_key) DO UPDATE SET file_path = excluded.file_path, '
          'file_size_bytes = excluded.file_size_bytes, format_badge = excluded.format_badge, '
          'tag_status = excluded.tag_status, '
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
            tagStatus,
            isLossless ? 1 : 0,
            lrcPath.isNotEmpty ? 1 : 0,
            lrcPath,
            DateTime.now().millisecondsSinceEpoch,
          ],
        );
      } catch (_) {
        // Pre-v7 databases without the tag_status column.
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
      }
      _upsert(DownloadEntry(
        key: key,
        title: title,
        artist: artist,
        status: DownloadStatus.done,
        progress: 1,
        badge: badge,
        tagNote: tagStatus,
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
