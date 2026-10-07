import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/library/playlist_link.dart';

String _fixture(String name) =>
    File('test/fixtures/$name').readAsStringSync();

void main() {
  test('Spotify embed parses title and deduped rows', () {
    final page =
        parseSpotifyEmbed(_fixture('spotify_embed_sample.html'));
    expect(page.source, PlaylistLinkSource.spotify);
    expect(page.title, 'Sample & Mix');
    expect(page.rows.length, 2);
    expect(page.rows[0].title, 'First Song');
    expect(page.rows[0].artist, 'First Artist');
    expect(page.rows[1].title, 'Second Song');
  });

  test('Spotify collapses non-breaking spaces, never throws', () {
    final nbsp = String.fromCharCode(0x00A0);
    final html =
        '<script id="__NEXT_DATA__" type="application/json">{"uri":"spotify:track:T1","title":"A${nbsp}Title","subtitle":"An${nbsp}Artist"}</script>';
    final page = parseSpotifyEmbed(html);
    expect(page.rows.single.title, 'A Title');
    expect(page.rows.single.artist, 'An Artist');
    expect(parseSpotifyEmbed('<html>nope</html>').rows, isEmpty);
    expect(parseSpotifyEmbed('{{{broken').rows, isEmpty);
  });

  test('Apple tier 1 parses title-artist rows', () {
    final page = parseApplePage(_fixture('apple_playlist_sample.html'));
    expect(page.source, PlaylistLinkSource.appleMusic);
    expect(page.title, 'Sample Hits');
    expect(page.rows.length, 2);
    expect(page.rows[0].title, 'Alpha Song');
    expect(page.rows[0].artist, 'Alpha Artist');
  });

  test('Apple tier 2 fallback yields artist-less rows', () {
    const html = '<script id=schema:music-playlist type="application/ld+json">'
        '{"@type":"MusicPlaylist","name":"Fallback Mix","track":['
        '{"@type":"MusicRecording","name":"Gamma Song"},'
        '{"@type":"MusicRecording","name":"Gamma Song"}]}</script>'
        '<title>Fallback Mix - Playlist - Apple Music</title>';
    final page = parseApplePage(html);
    expect(page.title, 'Fallback Mix');
    expect(page.rows.length, 1);
    expect(page.rows.single.title, 'Gamma Song');
    expect(page.rows.single.artist, isEmpty);
  });

  test('Apple strips branding suffix and never throws', () {
    expect(parseApplePage('<html>nope</html>').rows, isEmpty);
    expect(parseApplePage('<html>nope</html>').title.isNotEmpty, isTrue);
  });
}
