import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../downloads/download_manager.dart';
import 'local_audio_tags.dart';
import 'playlists.dart';

/// Every song on this PC the Library shows: files from the user's music
/// folders (the built-in "Local songs" playlist) plus finished downloads,
/// one row per file.
final libraryTracksProvider = Provider<List<StoredTrack>>((ref) {
  final local = ref.watch(playlistRepositoryProvider
      .select((all) => all.where((p) => p.isLocal).firstOrNull?.tracks));
  final downloads = ref.watch(downloadManagerProvider);
  return mergeLibraryTracks(local ?? const [], downloads);
});

/// Local rows first; a download whose file is already indexed from a music
/// folder (the download folder can live inside one) is not listed twice.
List<StoredTrack> mergeLibraryTracks(
  List<StoredTrack> local,
  List<DownloadEntry> downloads,
) {
  final seen = {for (final t in local) _norm(t.playbackUrl)};
  final out = [...local];
  for (final d in downloads) {
    final path = d.filePath;
    if (d.status != DownloadStatus.done || path == null || path.isEmpty) {
      continue;
    }
    if (!seen.add(_norm(path))) continue;
    out.add(StoredTrack(
      name: d.title,
      artist: d.artist,
      album: _albumOf(path),
      artworkUrl: d.artworkUrl,
      playbackUrl: path,
    ));
  }
  return out;
}

String _norm(String path) => p.normalize(path).toLowerCase();

// shortcut: tags are read synchronously once per file and cached for the
// session; move to an isolate if libraries of thousands of downloads lag.
final Map<String, String> _albumCache = {};

/// Album tag of a downloaded file (downloads are tagged on save).
String _albumOf(String path) => _albumCache.putIfAbsent(path, () {
      try {
        if (!File(path).existsSync()) return '';
        return LocalAudioTags.read(path, filename: p.basename(path)).album;
      } catch (_) {
        return '';
      }
    });

/// Songs sharing an album title, grouped case-insensitively.
class LibraryAlbum {
  final String title;
  final String artist;
  final String artworkUrl;
  final List<StoredTrack> tracks;
  const LibraryAlbum({
    required this.title,
    required this.artist,
    required this.artworkUrl,
    required this.tracks,
  });
}

/// Songs credited to one artist string.
class LibraryArtist {
  final String name;
  final String artworkUrl;
  final List<StoredTrack> tracks;
  const LibraryArtist({
    required this.name,
    required this.artworkUrl,
    required this.tracks,
  });
}

/// Albums A–Z. Songs without an album tag are left out (they still show
/// under Songs and Artists). Mixed credits read "Various artists".
List<LibraryAlbum> groupLibraryAlbums(List<StoredTrack> tracks) {
  final groups = <String, List<StoredTrack>>{};
  for (final t in tracks) {
    final album = t.album.trim();
    if (album.isEmpty) continue;
    groups.putIfAbsent(album.toLowerCase(), () => []).add(t);
  }
  final albums = [
    for (final g in groups.values)
      LibraryAlbum(
        title: g.first.album.trim(),
        artist: g.map((t) => t.artist.toLowerCase()).toSet().length == 1
            ? g.first.artist
            : 'Various artists',
        artworkUrl: g
            .firstWhere((t) => t.artworkUrl.isNotEmpty, orElse: () => g.first)
            .artworkUrl,
        tracks: g,
      ),
  ];
  albums.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  return albums;
}

/// Artists A–Z by their credit string.
List<LibraryArtist> groupLibraryArtists(List<StoredTrack> tracks) {
  final groups = <String, List<StoredTrack>>{};
  for (final t in tracks) {
    final name = t.artist.trim().isEmpty ? 'Unknown artist' : t.artist.trim();
    groups.putIfAbsent(name.toLowerCase(), () => []).add(t);
  }
  final artists = [
    for (final g in groups.values)
      LibraryArtist(
        name: g.first.artist.trim().isEmpty ? 'Unknown artist' : g.first.artist.trim(),
        artworkUrl: g
            .firstWhere((t) => t.artworkUrl.isNotEmpty, orElse: () => g.first)
            .artworkUrl,
        tracks: g,
      ),
  ];
  artists.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return artists;
}
