import 'package:dio/dio.dart';

import 'animated_artwork_service.dart';

class _CommunityEntry {
  final String song;
  final String artist;
  final String album;
  final String url;

  const _CommunityEntry({
    required this.song,
    required this.artist,
    required this.album,
    required this.url,
  });
}

/// A community-curated `song + artist -> looping video` index (ViMusic manifest).
///
/// Covers back catalog and independent tracks that major streaming services
/// lack. Held in memory for [_ttlMs] to avoid re-fetching per track.
class CommunityCanvas {
  CommunityCanvas._();

  static const String _manifestUrl =
      'https://vivimusicanvas.mkmdevilmi.workers.dev/canvas.json';
  static const int _ttlMs = 30 * 60 * 1000;

  static List<_CommunityEntry> _entries = const [];
  static int _fetchedAtMs = 0;
  static Future<List<_CommunityEntry>>? _inFlight;

  /// Clears the cached manifest (used by unit tests).
  static void resetForTesting() {
    _entries = const [];
    _fetchedAtMs = 0;
    _inFlight = null;
  }

  static Future<AnimatedArtwork?> search(
    Dio dio, {
    required String title,
    required String artist,
    String? album,
  }) async {
    final index = await _manifest(dio);
    if (index.isEmpty) return null;
    return _matchFromIndex(
      index,
      title: title,
      artist: artist,
      album: album,
    );
  }

  /// Synchronous check against the already-loaded manifest (0 network calls).
  static AnimatedArtwork? peekMatch({
    required String title,
    required String artist,
    String? album,
  }) {
    if (_entries.isEmpty) return null;
    return _matchFromIndex(
      _entries,
      title: title,
      artist: artist,
      album: album,
    );
  }

  static AnimatedArtwork? _matchFromIndex(
    List<_CommunityEntry> index, {
    required String title,
    required String artist,
    String? album,
  }) {
    final wantTitle = normalizeCanvasMatch(title);
    final wantArtist = normalizeCanvasMatch(artist);
    final wantAlbum = album != null ? normalizeCanvasMatch(album) : null;
    if (wantTitle.isEmpty || wantArtist.isEmpty) return null;

    // Pass 1: match song title + artist + album (when album is provided).
    for (final entry in index) {
      final listed = normalizeCanvasMatch(entry.album);
      final titleOk = canvasTitlesMatch(title, entry.song);
      final artistOk = canvasArtistsMatch(
        artist,
        entry.artist,
        wantTitle: title,
        gotTitle: entry.song,
      );
      final albumOk = listed.isEmpty ||
          wantAlbum == null ||
          wantAlbum.isEmpty ||
          canvasTitlesMatch(album!, entry.album);
      if (titleOk && artistOk && albumOk) {
        return AnimatedArtwork(
          url: entry.url,
          title: entry.song,
          artist: entry.artist,
          album: entry.album.trim().isEmpty ? null : entry.album,
          source: CanvasSource.community,
        );
      }
    }

    // Pass 2: if noisy album metadata (e.g. single name) rejected a valid
    // song+artist match, match song title + artist directly.
    if (wantAlbum != null && wantAlbum.isNotEmpty) {
      for (final entry in index) {
        final titleOk = canvasTitlesMatch(title, entry.song);
        final artistOk = canvasArtistsMatch(
          artist,
          entry.artist,
          wantTitle: title,
          gotTitle: entry.song,
        );
        if (titleOk && artistOk) {
          return AnimatedArtwork(
            url: entry.url,
            title: entry.song,
            artist: entry.artist,
            album: entry.album.trim().isEmpty ? null : entry.album,
            source: CanvasSource.community,
          );
        }
      }
    }

    // Pass 3: album-level fallback — many albums in the community manifest
    // share the same album canvas across tracks (e.g. Starboy, Dawn FM,
    // After Hours, UTOPIA).
    if (wantAlbum != null && wantAlbum.isNotEmpty) {
      for (final entry in index) {
        if (entry.album.trim().isEmpty) continue;
        final albumOk = canvasTitlesMatch(album!, entry.album);
        final artistOk = canvasArtistsMatch(
          artist,
          entry.artist,
          wantTitle: title,
          gotTitle: entry.song,
        );
        if (albumOk && artistOk) {
          return AnimatedArtwork(
            url: entry.url,
            title: null,
            artist: entry.artist,
            album: entry.album,
            source: CanvasSource.community,
          );
        }
      }
    }

    return null;
  }

  static Future<List<_CommunityEntry>> _manifest(Dio dio) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_entries.isNotEmpty && now - _fetchedAtMs < _ttlMs) {
      return Future.value(_entries);
    }
    return _inFlight ??= _fetchManifest(dio).whenComplete(() {
      _inFlight = null;
    });
  }

  static Future<List<_CommunityEntry>> _fetchManifest(Dio dio) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_entries.isNotEmpty && now - _fetchedAtMs < _ttlMs) {
      return _entries;
    }

    final root = await canvasGetJson(
      dio,
      _manifestUrl,
      headers: const {'User-Agent': canvasUserAgent},
    );
    if (root == null) {
      _fetchedAtMs = now;
      return _entries;
    }

    final items = root['items'];
    if (items is List) {
      final parsed = <_CommunityEntry>[];
      for (final item in items) {
        if (item is! Map) continue;
        final song = item['song']?.toString().trim() ?? '';
        final artist = item['artist']?.toString().trim() ?? '';
        final album = item['album']?.toString().trim() ?? '';
        final url = item['url']?.toString().trim() ?? '';
        if (song.isEmpty || artist.isEmpty || url.isEmpty) continue;
        parsed.add(
          _CommunityEntry(
            song: song,
            artist: artist,
            album: album,
            url: url,
          ),
        );
      }
      if (parsed.isNotEmpty) {
        _entries = parsed;
      }
    }
    _fetchedAtMs = now;
    return _entries;
  }
}
