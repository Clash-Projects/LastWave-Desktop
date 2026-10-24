/// Playlist link import flow: preview a pasted link (YouTube direct,
/// Spotify/Apple matched to YouTube) and create the local playlist.
///
/// Narrow seams ([PlaylistTrackSource], [PlaylistWriter]) keep the core
/// testable without a database or network; the public functions below
/// wire the production implementations.
library;

import 'dart:async';

import 'package:dio/dio.dart';

import '../innertube/innertube_api.dart';
import 'playlist_file.dart';
import 'playlist_link.dart';
import 'playlists.dart';

/// Preview of a link import: what would be created.
class PlaylistImportPreview {
  final String title;
  final int totalRows;
  final List<StoredTrack> matchedTracks;
  const PlaylistImportPreview({
    required this.title,
    required this.totalRows,
    this.matchedTracks = const [],
  });
}

/// YouTube access needed by the import (fetch + match).
abstract class PlaylistTrackSource {
  Future<YouTubePlaylistResult?> fetchPlaylist(String idOrUrl);
  Future<YouTubeMusicTrack?> findMatch(String title, String artist);
  Future<YouTubeMusicTrack?> fetchSong(String videoId);
}

/// Local-playlist writes needed by the import.
abstract class PlaylistWriter {
  Future<SavedPlaylist> createCustom(String title);
  Future<bool> addTrack(int id, StoredTrack track);
}

class _InnertubeTrackSource implements PlaylistTrackSource {
  final InnerTubeMusicApi api;
  _InnertubeTrackSource(this.api);

  @override
  Future<YouTubePlaylistResult?> fetchPlaylist(String idOrUrl) =>
      api.fetchPlaylist(idOrUrl);

  @override
  Future<YouTubeMusicTrack?> findMatch(String title, String artist) =>
      api.findBestMatchOrNull(title, artist);

  @override
  Future<YouTubeMusicTrack?> fetchSong(String videoId) =>
      api.fetchSongDetails(videoId);
}

class _PlaylistWriterOf implements PlaylistWriter {
  final PlaylistRepository repo;
  _PlaylistWriterOf(this.repo);

  @override
  Future<SavedPlaylist> createCustom(String title) =>
      repo.createCustom(title);

  @override
  Future<bool> addTrack(int id, StoredTrack track) =>
      repo.addTrack(id, track);
}

/// Production entry point: preview what [rawLink] would import.
Future<PlaylistImportPreview> previewPlaylistLink({
  required InnerTubeMusicApi api,
  required Dio dio,
  required String rawLink,
}) =>
    previewPlaylistLinkWith(
        _InnertubeTrackSource(api), dio, rawLink);

/// Production entry point: create the local playlist for [preview].
Future<SavedPlaylist> importPreview({
  required PlaylistRepository repo,
  required PlaylistImportPreview preview,
}) =>
    importPreviewWith(_PlaylistWriterOf(repo), preview);

/// Testable preview core: YouTube imports direct tracks; Spotify/Apple
/// rows are matched to YouTube (bounded fan-out, misses dropped).
Future<PlaylistImportPreview> previewPlaylistLinkWith(
  PlaylistTrackSource source,
  Dio dio,
  String rawLink, {
  Duration fetchTimeout = const Duration(seconds: 20),
}) async {
  final detected = detectPlaylistLink(rawLink);
  if (detected == null) {
    throw FormatException(
        'That does not look like a playlist link.');
  }
  if (detected == PlaylistLinkSource.youtube) {
    final id = extractPlaylistId(
        rawLink, PlaylistLinkSource.youtube);
    if (id == null || id.isEmpty) {
      throw FormatException(
          'That does not look like a playlist link.');
    }
    if (id.startsWith('RD')) {
      throw FormatException(
          'Mixes and radio cannot be imported. Paste a playlist link instead.');
    }
    YouTubePlaylistResult? fetched;
    try {
      fetched = await source
          .fetchPlaylist(rawLink)
          .timeout(fetchTimeout);
    } on TimeoutException {
      throw StateError(
          'Could not load that YouTube playlist. Check the link is public and try again.');
    }
    final tracks = fetched?.tracks ?? const [];
    if (tracks.isEmpty) {
      throw StateError('No playable tracks found in that playlist.');
    }
    return PlaylistImportPreview(
      title: fetched!.title.isNotEmpty
          ? fetched.title
          : 'YouTube Playlist',
      totalRows: tracks.length,
      matchedTracks: [
        for (final t in tracks)
          StoredTrack(
            name: t.title,
            artist: t.artist,
            artworkUrl: t.artworkUrl,
            videoId: t.videoId,
            album: t.album,
            durationSeconds: t.durationSeconds,
          ),
      ],
    );
  }
  final page = detected == PlaylistLinkSource.spotify
      ? await fetchSpotifyPlaylist(dio, rawLink)
      : await fetchApplePlaylist(dio, rawLink);
  if (page.rows.isEmpty) {
    throw StateError('No playable tracks found in that playlist.');
  }
  final matched = await _matchRows(source, [
    for (final row in page.rows)
      PlaylistFileRow(title: row.title, artist: row.artist),
  ]);
  if (matched.isEmpty) {
    throw StateError(
        'No playable tracks found in that playlist.');
  }
  return PlaylistImportPreview(
    title: page.title,
    totalRows: page.rows.length,
    matchedTracks: matched,
  );
}

/// Production entry point: preview a playlist file (CSV, M3U, text).
Future<PlaylistImportPreview> previewPlaylistFile({
  required InnerTubeMusicApi api,
  required List<int> bytes,
  required String filename,
}) =>
    previewPlaylistFileWith(_InnertubeTrackSource(api), bytes, filename);

/// Testable file core: rows with a YouTube id resolve by id, the rest are
/// matched like Spotify/Apple rows; repeated rows count once.
Future<PlaylistImportPreview> previewPlaylistFileWith(
  PlaylistTrackSource source,
  List<int> bytes,
  String filename,
) async {
  final seen = <String>{};
  final rows = parsePlaylistFile(decodePlaylistBytes(bytes), filename)
      .where((r) => seen.add(r.identity))
      .toList();
  if (rows.isEmpty) {
    throw const FormatException('No tracks found in that file.');
  }
  final ids = <String>{};
  final matched = (await _matchRows(source, rows))
      .where((t) => ids.add(t.videoId))
      .toList();
  if (matched.isEmpty) {
    throw StateError('No playable tracks found in that file.');
  }
  return PlaylistImportPreview(
    title: suggestedPlaylistTitle(filename),
    totalRows: rows.length,
    matchedTracks: matched,
  );
}

/// Bounded fan-out (5 at a time); misses and errors are dropped.
Future<List<StoredTrack>> _matchRows(
  PlaylistTrackSource source,
  List<PlaylistFileRow> rows,
) async {
  final matched = <StoredTrack>[];
  for (var i = 0; i < rows.length; i += 5) {
    final chunk = rows.skip(i).take(5).toList();
    final results = await Future.wait(chunk.map((row) async {
      try {
        final id = row.videoId;
        if (id != null) {
          final byId = await source
              .fetchSong(id)
              .timeout(const Duration(seconds: 10), onTimeout: () => null);
          if (byId != null && byId.videoId == id) return byId;
        }
        if (row.title.isEmpty) return null;
        return await source
            .findMatch(row.title, row.artist)
            .timeout(const Duration(seconds: 10), onTimeout: () => null);
      } catch (_) {
        return null;
      }
    }));
    for (var j = 0; j < chunk.length; j++) {
      final match = results[j];
      if (match == null) continue;
      final row = chunk[j];
      matched.add(StoredTrack(
        name: row.title.isNotEmpty ? row.title : match.title,
        artist: row.artist.isNotEmpty ? row.artist : match.artist,
        artworkUrl: match.artworkUrl,
        videoId: match.videoId,
        album: row.album ?? match.album,
        durationSeconds: match.durationSeconds,
      ));
    }
  }
  return matched;
}

/// Testable create core: one playlist, exactly the matched tracks.
/// An empty preview is refused — imports never create trackless playlists.
Future<SavedPlaylist> importPreviewWith(
  PlaylistWriter writer,
  PlaylistImportPreview preview,
) async {
  if (preview.matchedTracks.isEmpty) {
    throw StateError('No playable tracks found in that playlist.');
  }
  final created = await writer.createCustom(preview.title);
  for (final track in preview.matchedTracks) {
    await writer.addTrack(created.id, track);
  }
  return created;
}

