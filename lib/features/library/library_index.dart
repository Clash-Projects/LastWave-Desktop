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
  return [for (final t in out) _wellFormed(t)];
}

/// Tag text with broken UTF-16 (lone surrogates from badly encoded tags)
/// throws when painted, which blanked whole Library tabs.
String wellFormedUtf16(String s) {
  final units = s.codeUnits;
  var ok = true;
  for (var i = 0; i < units.length && ok; i++) {
    final u = units[i];
    if (u >= 0xD800 && u <= 0xDBFF) {
      if (i + 1 < units.length &&
          units[i + 1] >= 0xDC00 &&
          units[i + 1] <= 0xDFFF) {
        i++;
      } else {
        ok = false;
      }
    } else if (u >= 0xDC00 && u <= 0xDFFF) {
      ok = false;
    }
  }
  if (ok) return s;
  final out = <int>[];
  for (var i = 0; i < units.length; i++) {
    final u = units[i];
    if (u >= 0xD800 && u <= 0xDBFF &&
        i + 1 < units.length &&
        units[i + 1] >= 0xDC00 &&
        units[i + 1] <= 0xDFFF) {
      out..add(u)..add(units[++i]);
    } else if (u < 0xD800 || u > 0xDFFF) {
      out.add(u);
    }
  }
  return String.fromCharCodes(out);
}

StoredTrack _wellFormed(StoredTrack t) {
  final name = wellFormedUtf16(t.name);
  final artist = wellFormedUtf16(t.artist);
  final album = wellFormedUtf16(t.album);
  if (identical(name, t.name) &&
      identical(artist, t.artist) &&
      identical(album, t.album)) {
    return t;
  }
  return StoredTrack(
    name: name,
    artist: artist,
    album: album,
    artworkUrl: t.artworkUrl,
    videoId: t.videoId,
    durationSeconds: t.durationSeconds,
    playbackUrl: t.playbackUrl,
    addedAtMillis: t.addedAtMillis,
  );
}

/// Individual artists in a credit: "A, B & C feat. D" -> [A, B, C, D].
List<String> splitArtistCredit(String credit) {
  final parts = credit
      .split(RegExp(r'\s*(?:,|;|/|&|\bx\b|\band\b|\bfeat\.?|\bft\.?|\bfeaturing\b|\bwith\b)\s*',
          caseSensitive: false))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  return parts.isEmpty ? [credit.trim()] : parts;
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

/// Artists A–Z, one per person: a song credited to "A, B & C" is listed
/// under each of A, B and C instead of under a merged "A, B & C".
List<LibraryArtist> groupLibraryArtists(List<StoredTrack> tracks) {
  final groups = <String, (String, List<StoredTrack>)>{};
  for (final t in tracks) {
    final names = t.artist.trim().isEmpty
        ? const ['Unknown artist']
        : splitArtistCredit(t.artist);
    for (final name in names) {
      groups.putIfAbsent(name.toLowerCase(), () => (name, [])).$2.add(t);
    }
  }
  final artists = [
    for (final (name, g) in groups.values)
      LibraryArtist(
        name: name,
        artworkUrl: g
            .firstWhere((t) => t.artworkUrl.isNotEmpty, orElse: () => g.first)
            .artworkUrl,
        tracks: g,
      ),
  ];
  artists.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return artists;
}
