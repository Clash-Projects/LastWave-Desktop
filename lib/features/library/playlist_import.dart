/// Playlist link import flow: preview a pasted link (YouTube direct,
/// Spotify/Apple matched to YouTube) and create the local playlist.
///
/// Narrow seams ([PlaylistTrackSource], [PlaylistWriter]) keep the core
/// testable without a database or network; the public functions below
/// wire the production implementations.
library;

import 'package:dio/dio.dart';

import '../innertube/innertube_api.dart';
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
  String rawLink,
) async {
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
    final fetched = await source.fetchPlaylist(rawLink);
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
  final matched = <StoredTrack>[];
  for (var i = 0; i < page.rows.length; i += 5) {
    final chunk = page.rows.skip(i).take(5);
    final results = await Future.wait(
      chunk.map(
        (row) => source
            .findMatch(row.title, row.artist)
            .timeout(
              const Duration(seconds: 10),
              onTimeout: () => null,
            )
            .then<YouTubeMusicTrack?>(
              (match) => match,
              onError: (_) => null,
            ),
      ),
    );
    for (var j = 0; j < chunk.length; j++) {
      final match = results[j];
      if (match == null) continue;
      final row = chunk.elementAt(j);
      matched.add(StoredTrack(
        name: row.title,
        artist: row.artist,
        artworkUrl: match.artworkUrl,
        videoId: match.videoId,
      ));
    }
  }
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

/// Testable create core: one playlist, exactly the matched tracks.
Future<SavedPlaylist> importPreviewWith(
  PlaylistWriter writer,
  PlaylistImportPreview preview,
) async {
  final created = await writer.createCustom(preview.title);
  for (final track in preview.matchedTracks) {
    await writer.addTrack(created.id, track);
  }
  return created;
}

