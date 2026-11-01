import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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

  Future<String> _coverFile(String sourcePath, Uint8List? bytes) async {
    if (bytes == null || bytes.length < 32) return '';
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory(p.join(support.path, 'local_art'));
      if (!await dir.exists()) await dir.create(recursive: true);
      final hash = md5.convert(utf8.encode(sourcePath)).toString();
      final png = bytes.length > 3 &&
          bytes[0] == 0x89 &&
          bytes[1] == 0x50 &&
          bytes[2] == 0x4E;
      final file = File(p.join(dir.path, '$hash.${png ? 'png' : 'jpg'}'));
      if (!await file.exists() || await file.length() != bytes.length) {
        await file.writeAsBytes(bytes, flush: true);
      }
      return file.path;
    } catch (_) {
      return '';
    }
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
          final art = await _coverFile(entity.path, tags.coverBytes);
          final album = tags.album.isEmpty
              ? ''
              : (tags.year.isEmpty
                  ? tags.album
                  : '${tags.album} (${tags.year})');
          tracks.add(StoredTrack(
            name: title,
            artist: artist,
            album: album,
            artworkUrl: art,
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
