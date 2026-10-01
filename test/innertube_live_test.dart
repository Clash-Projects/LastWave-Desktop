import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/network/dio_factory.dart';
import 'package:lastwave_desktop/core/storage/secure_store.dart';
import 'package:lastwave_desktop/features/innertube/innertube_api.dart';

/// LIVE backend verification (hits real YouTube Music servers).
///
/// Run explicitly:
///   flutter test test/innertube_live_test.dart --timeout 300s
///
/// NOT part of the default suite: requires network and real,
/// rotating InnerTube responses. Prints fingerprints only
/// (itag/mime/bitrate/expiry) — never URLs or credentials.
void main() {
  late InnerTubeMusicApi tube;

  setUpAll(() async {
    tube = InnerTubeMusicApi(
        DioFactory.create(), SecureStore());
    await tube.loadPersistedConnection();
  });

  test('search returns songs', () async {
    final results = await tube.searchSongs(
        'Bohemian Rhapsody Queen',
        limit: 10);
    expect(results, isNotEmpty);
    expect(results.first.videoId, isNotEmpty);
    expect(results.first.title, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('search artists/albums/playlists', () async {
    final artists =
        await tube.searchArtists('Queen', limit: 5);
    expect(artists, isNotEmpty);
    expect(
        artists.first.browseId.startsWith('UC'), isTrue);
    final albums =
        await tube.searchAlbums('A Night At The Opera Queen',
            limit: 5);
    expect(albums, isNotEmpty);
    final playlists =
        await tube.searchPlaylists('lofi hip hop', limit: 5);
    expect(playlists, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('match + resolve + probe: Bohemian Rhapsody', () async {
    final match = await tube.findBestMatchOrNull(
        'Bohemian Rhapsody', 'Queen');
    expect(match, isNotNull);
    final stream =
        await tube.resolveAudioStream(match!.videoId);
    expect(stream, isNotNull);
    expect(stream!.url.startsWith('https://'), isTrue);
    expect(stream.mimeType.startsWith('audio/'), isTrue);
    expect(stream.bitrateKbps, greaterThan(0));
    // ignore: avoid_print
    print('RESOLVED bohemian itag-mime=${stream.audioCodec} '
        'kbps=${stream.bitrateKbps} badge=${stream.qualityBadge}');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('match + resolve + probe: Hey Jude', () async {
    final match = await tube.findBestMatchOrNull(
        'Hey Jude', 'The Beatles');
    expect(match, isNotNull);
    final stream =
        await tube.resolveAudioStream(match!.videoId);
    expect(stream, isNotNull);
    expect(stream!.mimeType.startsWith('audio/'), isTrue);
    // ignore: avoid_print
    print('RESOLVED heyjude kbps=${stream.bitrateKbps} '
        'mime=${stream.mimeType}');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('match + resolve + probe: Hello (Adele)', () async {
    final match = await tube.findBestMatchOrNull(
        'Hello', 'Adele');
    expect(match, isNotNull);
    final stream =
        await tube.resolveAudioStream(match!.videoId);
    expect(stream, isNotNull);
    expect(stream!.mimeType.startsWith('audio/'), isTrue);
    // ignore: avoid_print
    print('RESOLVED hello kbps=${stream.bitrateKbps} '
        'mime=${stream.mimeType}');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('related songs for a seed', () async {
    final match = await tube.findBestMatchOrNull(
        'Bohemian Rhapsody', 'Queen');
    expect(match, isNotNull);
    final related = await tube.fetchRelatedSongs(
        match!.videoId,
        limit: 10);
    expect(related, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));

  // `loadPersistedConnection` in setUpAll restores the cookie jar from
  // secure storage, so this exercises the personalized path when a jar
  // is present and the anonymous shelves when it is not. Either way the
  // parser has to produce titled, renderable shelves - the point of the
  // test is the response shape, not whether a jar happens to be stored.
  test('home browse returns titled shelves', () async {
    final shelves = await tube.fetchHomeShelves();
    expect(shelves, isNotEmpty);
    for (final shelf in shelves) {
      expect(shelf.title, isNotEmpty);
      expect(shelf.isRenderable, isTrue);
      if (shelf.isCardShelf) {
        for (final e in shelf.entities) {
          expect(e.name, isNotEmpty);
          expect(e.browseId.isNotEmpty || e.playlistId.isNotEmpty, isTrue);
        }
      }
    }
    // Fingerprints only - no titles, urls or credentials.
    // ignore: avoid_print
    print('HOME shelves=${shelves.length} '
        'cards=${shelves.where((s) => s.isCardShelf).length} '
        'songs=${shelves.where((s) => s.isTrackShelf).length} '
        'kinds=${shelves.expand((s) => s.entities).map((e) => e.kind).toSet()}');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
