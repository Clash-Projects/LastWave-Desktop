import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/storage/app_database.dart';
import '../search/shared_providers.dart';
import 'local_audio_tags.dart';
import 'playlists.dart';

const localAudioExtensions = {
  'mp3',
  'flac',
  'm4a',
  'ogg',
  'opus',
  'wav',
  'aac',
};

class LocalScanState {
  final bool running;
  final String label;
  const LocalScanState({this.running = false, this.label = ''});
}

/// Indexes folders the user picks and plays the files in place.
///
/// Rows live in the built-in "Local songs" playlist (`mode: local`).
/// That playlist is never uploaded to YouTube Music.
class LocalMusicLibrary {
  final AppDatabase _db;
  final PlaylistRepository _playlists;
  final void Function(LocalScanState) _report;

  LocalMusicLibrary(this._db, this._playlists, this._report);

  List<String> get folders => _db.localFolders();

  Future<void> addFolder(String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) return;
    _db.addLocalFolder(dir.absolute.path);
    await rescan();
  }

  Future<void> forgetFolder(String path) async {
    _db.removeLocalFolder(path);
    await rescan();
  }

  Future<int> rescan() async {
    _report(const LocalScanState(running: true, label: 'Scanning folders…'));
    final tracks = <StoredTrack>[];
    final seen = <String>{};
    var found = 0;
    try {
      for (final folder in _db.localFolders()) {
        final dir = Directory(folder);
        if (!await dir.exists()) continue;
        await for (final entity in dir.list(recursive: true, followLinks: false)) {
          if (entity is! File) continue;
          final ext = p.extension(entity.path).toLowerCase().replaceFirst('.', '');
          if (!localAudioExtensions.contains(ext)) continue;
          if (!seen.add(entity.path.toLowerCase())) continue;
          final name = p.basename(entity.path);
          final tags = LocalAudioTags.read(entity.path, filename: name);
          final title = tags.title.isEmpty ? name : tags.title;
          final artist = tags.artist.isEmpty ? 'Local file' : tags.artist;
          tracks.add(StoredTrack(
            name: title,
            artist: artist,
            album: tags.album,
            playbackUrl: entity.path,
            addedAtMillis: entity.statSync().modified.millisecondsSinceEpoch,
          ));
          found++;
          if (found % 40 == 0) {
            _report(LocalScanState(
              running: true,
              label: 'Scanning folders… $found files',
            ));
            await Future<void>.delayed(Duration.zero);
          }
        }
      }
      tracks.sort((a, b) {
        final byArtist = a.artist.toLowerCase().compareTo(b.artist.toLowerCase());
        if (byArtist != 0) return byArtist;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      final playlist = await _playlists.ensureLocalSongs();
      await _playlists.replaceTracks(playlist.id, tracks);
      _report(LocalScanState(
        running: false,
        label: tracks.isEmpty ? 'No audio files found' : '${tracks.length} local songs',
      ));
      return tracks.length;
    } catch (e) {
      _report(LocalScanState(running: false, label: 'Scan failed'));
      rethrow;
    }
  }
}

final localScanProvider =
    StateProvider<LocalScanState>((ref) => const LocalScanState());

final localMusicLibraryProvider = Provider<LocalMusicLibrary>((ref) {
  return LocalMusicLibrary(
    ref.watch(databaseProvider),
    ref.watch(playlistRepositoryProvider.notifier),
    (state) => ref.read(localScanProvider.notifier).state = state,
  );
});
