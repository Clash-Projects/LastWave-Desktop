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
}
