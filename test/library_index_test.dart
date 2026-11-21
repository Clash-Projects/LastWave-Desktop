import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/downloads/download_manager.dart';
import 'package:lastwave_desktop/features/library/library_index.dart';
import 'package:lastwave_desktop/features/library/playlists.dart';

void main() {
  const a1 = StoredTrack(
      name: 'One', artist: 'A', album: 'First', playbackUrl: r'C:\m\1.flac');
  const a2 = StoredTrack(
      name: 'Two', artist: 'B', album: 'first', playbackUrl: r'C:\m\2.flac');
  const loose = StoredTrack(name: 'Loose', artist: '', playbackUrl: r'C:\m\3.mp3');

  test('albums group case-insensitively; mixed credits read Various', () {
    final albums = groupLibraryAlbums([a1, a2, loose]);
    expect(albums, hasLength(1));
    expect(albums.single.tracks, hasLength(2));
    expect(albums.single.artist, 'Various artists');
  });

  test('artists fall back to Unknown artist', () {
    final names = groupLibraryArtists([a1, a2, loose]).map((a) => a.name);
    expect(names, ['A', 'B', 'Unknown artist']);
  });

  test('a multi-artist credit lists each artist separately', () {
    const duet = StoredTrack(
        name: 'Duet',
        artist: 'Mithoon & Arijit Singh, Raftaar feat. KR\$NA',
        playbackUrl: r'C:\m\4.mp3');
    final names = groupLibraryArtists([duet, a1]).map((a) => a.name);
    expect(names, ['A', 'Arijit Singh', 'KR\$NA', 'Mithoon', 'Raftaar']);
  });

  test('broken UTF-16 in tags is dropped instead of crashing the view', () {
    final broken = 'Ok${String.fromCharCode(0xD800)}Song';
    expect(wellFormedUtf16(broken), 'OkSong');
    expect(wellFormedUtf16('fine 🎵'), 'fine 🎵');
  });

  test('a download already indexed from a music folder is not listed twice',
      () {
    final merged = mergeLibraryTracks([a1], [
      const DownloadEntry(
          key: 'k',
          title: 'One',
          artist: 'A',
          status: DownloadStatus.done,
          filePath: r'c:\m\1.flac'),
      const DownloadEntry(
          key: 'q', title: 'Queued', artist: 'A'), // not finished
    ]);
    expect(merged, hasLength(1));
  });
}
