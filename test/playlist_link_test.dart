import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/library/playlist_link.dart';

void main() {
  test('detects Spotify shapes', () {
    expect(
      detectPlaylistLink('https://open.spotify.com/playlist/ABC123?si=x'),
      PlaylistLinkSource.spotify,
    );
    expect(
      detectPlaylistLink('https://open.spotify.com/intl-de/playlist/ABC123'),
      PlaylistLinkSource.spotify,
    );
    expect(
      detectPlaylistLink('spotify:playlist:ABC123'),
      PlaylistLinkSource.spotify,
    );
    expect(
      detectPlaylistLink('https://spotify.link/ABC123'),
      PlaylistLinkSource.spotify,
    );
  });

  test('detects Apple and YouTube shapes, rejects garbage', () {
    expect(
      detectPlaylistLink(
          'https://music.apple.com/us/playlist/slug/pl.abc123'),
      PlaylistLinkSource.appleMusic,
    );
    expect(
      detectPlaylistLink('music.apple.com/us/playlist/pl.abc123'),
      PlaylistLinkSource.appleMusic,
    );
    expect(
      detectPlaylistLink('https://music.youtube.com/playlist?list=PLxyz'),
      PlaylistLinkSource.youtube,
    );
    expect(
      detectPlaylistLink('https://www.youtube.com/watch?v=a&list=PLxyz'),
      PlaylistLinkSource.youtube,
    );
    expect(detectPlaylistLink('just some words'), isNull);
    expect(detectPlaylistLink('   '), isNull);
  });

  test('extracts provider ids', () {
    expect(
      extractPlaylistId('https://open.spotify.com/playlist/ABC123?si=x',
          PlaylistLinkSource.spotify),
      'ABC123',
    );
    expect(
      extractPlaylistId(
          'https://open.spotify.com/intl-de/playlist/ABC123',
          PlaylistLinkSource.spotify),
      'ABC123',
    );
    expect(
      extractPlaylistId(
          'spotify:playlist:ABC123', PlaylistLinkSource.spotify),
      'ABC123',
    );
    expect(
      extractPlaylistId(
          'https://music.apple.com/us/playlist/slug/pl.abc123',
          PlaylistLinkSource.appleMusic),
      'pl.abc123',
    );
    expect(
      extractPlaylistId('https://music.youtube.com/playlist?list=PLxyz',
          PlaylistLinkSource.youtube),
      'PLxyz',
    );
    expect(
      extractPlaylistId('not a playlist', PlaylistLinkSource.spotify),
      isNull,
    );
  });
}
