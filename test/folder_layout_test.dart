import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/downloads/folder_layout.dart';

void main() {
  String sub(
    DownloadFolderLayout layout, {
    String artist = 'Arijit Singh',
    String album = 'Aashiqui 2',
    String year = '2013',
  }) =>
      downloadSubpath(
        structure: layout,
        artist: artist,
        album: album,
        year: year,
      );

  test('flat keeps files in the root', () {
    expect(sub(DownloadFolderLayout.flat), '');
  });

  test('each layout builds its folders', () {
    expect(sub(DownloadFolderLayout.artistAlbum), 'Arijit Singh/Aashiqui 2');
    expect(sub(DownloadFolderLayout.artistYearAlbum),
        'Arijit Singh/[2013] Aashiqui 2');
    expect(sub(DownloadFolderLayout.albumOnly), 'Aashiqui 2');
    expect(sub(DownloadFolderLayout.yearAlbum), '[2013] Aashiqui 2');
  });

  test('no album goes to Singles, and a missing year is left out', () {
    expect(sub(DownloadFolderLayout.artistAlbum, album: ''),
        'Arijit Singh/Singles');
    expect(sub(DownloadFolderLayout.yearAlbum, album: 'Singles'), 'Singles');
    expect(sub(DownloadFolderLayout.artistYearAlbum, year: ''),
        'Arijit Singh/Aashiqui 2');
  });

  test('the first artist names the folder', () {
    expect(
      sub(DownloadFolderLayout.artistAlbum, artist: 'A feat. B'),
      'A/Aashiqui 2',
    );
    expect(primaryDownloadArtist('Pritam, Arijit Singh'), 'Pritam');
    expect(primaryDownloadArtist('Mika Singh x Neha'), 'Mika Singh');
  });

  test('path characters cannot escape the download folder', () {
    expect(sanitizeDownloadSegment('..'), '');
    expect(sanitizeDownloadSegment('AC/DC'), 'DC');
    expect(sanitizeDownloadSegment('a:b*c'), 'a_b_c');
    expect(
      sub(DownloadFolderLayout.artistAlbum, artist: '..', album: '..'),
      'Unknown Artist/Singles',
    );
  });

  test('unknown ids fall back to flat', () {
    expect(DownloadFolderLayout.fromId('nope'), DownloadFolderLayout.flat);
    expect(DownloadFolderLayout.fromId('year_album'),
        DownloadFolderLayout.yearAlbum);
  });
}
