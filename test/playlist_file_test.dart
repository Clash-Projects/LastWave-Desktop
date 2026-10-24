import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/innertube/innertube_api.dart';
import 'package:lastwave_desktop/features/library/playlist_file.dart';
import 'package:lastwave_desktop/features/library/playlist_import.dart';

class _Source implements PlaylistTrackSource {
  final Map<String, YouTubeMusicTrack> matches;
  final Map<String, YouTubeMusicTrack> songs;
  _Source({this.matches = const {}, this.songs = const {}});

  @override
  Future<YouTubePlaylistResult?> fetchPlaylist(String idOrUrl) async => null;

  @override
  Future<YouTubeMusicTrack?> findMatch(String title, String artist) async =>
      matches['$title|$artist'];

  @override
  Future<YouTubeMusicTrack?> fetchSong(String videoId) async => songs[videoId];
}

YouTubeMusicTrack _t(String id, String title, String artist) =>
    YouTubeMusicTrack(videoId: id, title: title, artist: artist);

void main() {
  test('Exportify CSV: header columns, quoted commas, album', () {
    const csv =
        'Track URI,Track Name,Artist Name(s),Album Name\n'
        'spotify:track:1,"Hello, World",Adele,25\n'
        'spotify:track:2,Skyfall,Adele,Skyfall\n';
    final rows = parsePlaylistFile(csv, 'Liked.csv');
    expect(rows.map((r) => r.title), ['Hello, World', 'Skyfall']);
    expect(rows.first.artist, 'Adele');
    expect(rows.first.album, '25');
    expect(rows.first.videoId, isNull);
  });

  test('semicolon CSV with sep= line and index column', () {
    const csv =
        'sep=;\nNo;Titre;Artiste\n1;Alors on danse;Stromae\n'
        '2;Papaoutai;Stromae\n';
    final rows = parsePlaylistFile(csv, 'export.csv');
    expect(rows.map((r) => r.title), ['Alors on danse', 'Papaoutai']);
    expect(rows.map((r) => r.artist).toSet(), {'Stromae'});
  });

  test('YouTube link column becomes a video id', () {
    const csv =
        'title,artist,url\n'
        'Song,Band,https://music.youtube.com/watch?v=dQw4w9WgXcQ&si=x\n';
    expect(parsePlaylistFile(csv, 'a.csv').single.videoId, 'dQw4w9WgXcQ');
  });

  test('M3U: EXTINF artist - title, and bare links', () {
    const m3u =
        '#EXTM3U\n#EXTINF:215,Daft Punk - One More Time\n'
        'C:\\Music\\one more time.mp3\nhttps://youtu.be/dQw4w9WgXcQ\n';
    final rows = parsePlaylistFile(m3u, 'mix.m3u8');
    expect(rows.first.title, 'One More Time');
    expect(rows.first.artist, 'Daft Punk');
    expect(rows.last.videoId, 'dQw4w9WgXcQ');
  });

  test('text list: numbering, "by" and dash separators', () {
    const txt = '01. Muse - Uprising\nHey Jude by The Beatles\n';
    final rows = parsePlaylistFile(txt, 'list.txt');
    expect(rows[0].title, 'Uprising');
    expect(rows[0].artist, 'Muse');
    expect(rows[1].title, 'Hey Jude');
    expect(rows[1].artist, 'The Beatles');
  });

  test('UTF-16 LE with BOM and Latin-1 decode', () {
    final utf16 = [0xff, 0xfe];
    for (final c in 'title,artist\nCafé,Zaz\n'.codeUnits) {
      utf16
        ..add(c & 0xff)
        ..add(c >> 8);
    }
    expect(decodePlaylistBytes(utf16), 'title,artist\nCafé,Zaz\n');
    expect(decodePlaylistBytes(latin1.encode('Café')), 'Café');
  });

  test('suggested title from filename', () {
    expect(suggestedPlaylistTitle('My_Road-Trip.csv'), 'My Road Trip');
    expect(suggestedPlaylistTitle('.csv'), 'Imported Playlist');
  });

  test('file preview: id rows resolve by id, repeats count once', () async {
    const csv =
        'title,artist,url\n'
        'Skyfall,Adele,\nSkyfall,Adele,\n'
        ',,https://youtu.be/dQw4w9WgXcQ\nMissing,Nobody,\n';
    final preview = await previewPlaylistFileWith(
      _Source(
        matches: {'Skyfall|Adele': _t('aaaaaaaaaaa', 'Skyfall', 'Adele')},
        songs: {
          'dQw4w9WgXcQ': _t('dQw4w9WgXcQ', 'Never Gonna Give You Up', 'Rick'),
        },
      ),
      utf8.encode(csv),
      'road_trip.csv',
    );
    expect(preview.title, 'road trip');
    expect(preview.totalRows, 3);
    expect(preview.matchedTracks.map((t) => t.videoId), [
      'aaaaaaaaaaa',
      'dQw4w9WgXcQ',
    ]);
    expect(preview.matchedTracks.last.name, 'Never Gonna Give You Up');
  });

  test('empty file is refused', () async {
    await expectLater(
      previewPlaylistFileWith(_Source(), utf8.encode('\n\n'), 'x.csv'),
      throwsA(isA<FormatException>()),
    );
  });
}
