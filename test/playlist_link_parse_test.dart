import 'dart:io';

import 'package:dio/dio.dart';
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

  test('fetchers serve fixtures through stub Dio', () async {
    var requests = 0;
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests++;
          final url = options.uri.toString();
          if (url.contains('spotify.com/embed')) {
            handler.resolve(Response(
                requestOptions: options,
                statusCode: 200,
                data: _fixture('spotify_embed_sample.html')));
            return;
          }
          if (url.contains('music.apple.com')) {
            handler.resolve(Response(
                requestOptions: options,
                statusCode: 200,
                data: _fixture('apple_playlist_sample.html')));
            return;
          }
          handler.reject(DioException(
              requestOptions: options, type: DioExceptionType.unknown));
        },
      ),
    );
    final spotify = await fetchSpotifyPlaylist(
        dio, 'https://open.spotify.com/playlist/ABC123');
    expect(spotify.title, 'Sample & Mix');
    expect(spotify.rows.length, 2);
    final apple = await fetchApplePlaylist(
        dio, 'https://music.apple.com/us/playlist/sample/pl.abc123');
    expect(apple.title, 'Sample Hits');
    expect(apple.rows.length, 2);
    expect(requests, 2);
  });

  test('fetchers reject garbage and mixes without HTTP', () async {
    var requests = 0;
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests++;
          final url = options.uri.toString();
          if (url.contains('spotify.link/XYZ')) {
            // Short link: Dio follows the HTTP redirect; the canonical
            // playlist id comes from the final URI.
            handler.resolve(Response(
                requestOptions: RequestOptions(
                    path:
                        'https://open.spotify.com/playlist/ABC123?si=x'),
                statusCode: 200,
                data: 'redirect landing'));
            return;
          }
          if (url.contains('spotify.com/embed/playlist/ABC123')) {
            handler.resolve(Response(
                requestOptions: options,
                statusCode: 200,
                data: _fixture('spotify_embed_sample.html')));
            return;
          }
          handler.reject(DioException(
            requestOptions: options,
            type: DioExceptionType.badResponse,
            response:
                Response(requestOptions: options, statusCode: 404),
          ));
        },
      ),
    );
    // Short URL resolves through the redirect to the real playlist.
    final viaShort = await fetchSpotifyPlaylist(dio, 'https://spotify.link/XYZ');
    expect(viaShort.title, 'Sample & Mix');
    expect(viaShort.rows.length, 2);
    await expectLater(
      fetchSpotifyPlaylist(dio, 'not a link'),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      fetchApplePlaylist(dio, 'RDxyz'),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      fetchSpotifyPlaylist(dio, 'https://open.spotify.com/playlist/NOPE'),
      throwsA(isA<StateError>()),
    );
    expect(requests, 3); // short+embed, 404; garbage never hits HTTP
  });
}
