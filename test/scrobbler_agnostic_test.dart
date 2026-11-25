import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/network/lastfm_api.dart';
import 'package:lastwave_desktop/core/network/rate_guard.dart';
import 'package:lastwave_desktop/core/storage/prefs.dart';
import 'package:lastwave_desktop/features/lastfm/home_repository.dart';
import 'package:lastwave_desktop/features/scrobblers/extra_scrobblers.dart';
import 'package:lastwave_desktop/features/scrobblers/scrobbler_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.handler);
  final Future<ResponseBody> Function(RequestOptions options) handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) =>
      handler(options);

  @override
  void close({bool force = false}) {}
}

ResponseBody _jsonBody(Object data, {int status = 200}) =>
    ResponseBody.fromString(
      jsonEncode(data),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Prefs prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await Prefs.load();
  });

  group('activeScrobblerSessionProvider', () {
    test('returns none when no scrobbler is connected (guest mode)', () async {
      await prefs.setGuestMode(true);
      final container = ProviderContainer(
        overrides: [prefsProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);

      final session = container.read(activeScrobblerSessionProvider);
      expect(session.connected, isFalse);
      expect(session.kind, isNull);
      expect(session.username, isEmpty);
      expect(container.read(connectedScrobblersProvider), isEmpty);
    });

    test('activates ListenBrainz when connected without Last.fm', () async {
      await prefs.setGuestMode(true);
      await prefs.setListenBrainz(
        token: 'lb-tok',
        user: 'alice_lb',
        server: '',
      );
      final container = ProviderContainer(
        overrides: [prefsProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);

      final session = container.read(activeScrobblerSessionProvider);
      expect(session.connected, isTrue);
      expect(session.kind, ScrobblerKind.listenbrainz);
      expect(session.username, 'alice_lb');
      expect(session.displayName, 'ListenBrainz');
      expect(session.cacheScope, 'listenbrainz:alice_lb');
    });

    test('activates Libre.fm when connected without Last.fm', () async {
      await prefs.setGuestMode(true);
      await prefs.setLibreFm(
        session: 'lf-sk',
        user: 'bob_lf',
        server: '',
      );
      final container = ProviderContainer(
        overrides: [prefsProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);

      final session = container.read(activeScrobblerSessionProvider);
      expect(session.connected, isTrue);
      expect(session.kind, ScrobblerKind.librefm);
      expect(session.username, 'bob_lf');
      expect(session.displayName, 'Libre.fm');
      expect(session.cacheScope, 'librefm:bob_lf');
    });

    test('honors primaryScrobbler when multiple scrobblers are connected',
        () async {
      await prefs.saveLastFmKeys(apiKey: 'k', apiSecret: 's');
      await prefs.saveSession(sessionKey: 'sk', username: 'lfm_user');
      await prefs.setListenBrainz(token: 'lb-tok', user: 'lb_user', server: '');
      await prefs.setLibreFm(session: 'lf-sk', user: 'lf_user', server: '');
      await prefs.setPrimaryScrobbler('listenbrainz');

      final container = ProviderContainer(
        overrides: [prefsProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);

      expect(container.read(connectedScrobblersProvider), [
        ScrobblerKind.lastfm,
        ScrobblerKind.listenbrainz,
        ScrobblerKind.librefm,
      ]);
      final session = container.read(activeScrobblerSessionProvider);
      expect(session.kind, ScrobblerKind.listenbrainz);
      expect(session.username, 'lb_user');
    });
  });

  group('ListenBrainzScrobbler reads & love', () {
    test('parses listens, stats, top artists/tracks/releases, and loveTrack',
        () async {
      await prefs.setListenBrainz(token: 'tok', user: 'rob', server: '');
      final requests = <String>[];
      final dio = Dio()
        ..httpClientAdapter = _StubAdapter((opt) async {
          requests.add('${opt.method} ${opt.uri.path}');
          if (opt.uri.path == '/1/user/rob/listens') {
            return _jsonBody({
              'payload': {
                'count': 1,
                'listens': [
                  {
                    'listened_at': 1700000000,
                    'track_metadata': {
                      'artist_name': 'Radiohead',
                      'track_name': 'Nude',
                      'mbid_mapping': {
                        'caa_release_mbid': 'rel-1',
                        'caa_id': 99,
                      },
                    },
                  },
                ],
              },
            });
          }
          if (opt.uri.path == '/1/user/rob/listen-count') {
            return _jsonBody({'payload': {'count': 420}});
          }
          if (opt.uri.path == '/1/stats/user/rob/recordings') {
            return _jsonBody({
              'payload': {
                'total_recording_count': 110,
                'recordings': [
                  {
                    'track_name': 'Nude',
                    'artist_name': 'Radiohead',
                    'listen_count': 15,
                  },
                ],
              },
            });
          }
          if (opt.uri.path == '/1/stats/user/rob/artists') {
            return _jsonBody({
              'payload': {
                'total_artist_count': 35,
                'artists': [
                  {'artist_name': 'Radiohead', 'listen_count': 55},
                ],
              },
            });
          }
          if (opt.uri.path == '/1/stats/user/rob/releases') {
            return _jsonBody({
              'payload': {
                'total_release_count': 22,
                'releases': [
                  {
                    'release_name': 'In Rainbows',
                    'artist_name': 'Radiohead',
                    'listen_count': 30,
                    'caa_release_mbid': 'rel-1',
                    'caa_id': 99,
                  },
                ],
              },
            });
          }
          if (opt.uri.path == '/1/metadata/lookup/') {
            return _jsonBody({'recording_mbid': 'rec-mbid-1'});
          }
          if (opt.uri.path == '/1/feedback/recording-feedback') {
            return _jsonBody({'status': 'ok'});
          }
          return _jsonBody({}, status: 404);
        });

      final lb = ListenBrainzScrobbler(prefs, dio);
      final home = HomeRepository(
        LastFmApiService(Dio(), LastFmRateGuard()),
        prefs,
        activeKind: ScrobblerKind.listenbrainz,
        listenBrainz: lb,
      );

      final recent = await home.fetchRecentTracks();
      expect(recent, hasLength(1));
      expect(recent.first.name, 'Nude');
      expect(recent.first.artist, 'Radiohead');
      expect(recent.first.timestampMillis, 1700000000 * 1000);
      expect(
        recent.first.artworkUrl,
        'https://coverartarchive.org/release/rel-1/99-250.jpg',
      );

      final stats = await home.fetchStats();
      expect(stats.scrobbles, 420);
      expect(stats.trackCount, 110);
      expect(stats.artistCount, 35);
      expect(stats.albumCount, 22);

      final topTracks = await home.fetchTopTracks();
      expect(topTracks.single.playCount, 15);

      final topArtists = await home.fetchTopArtists();
      expect(topArtists.single.name, 'Radiohead');
      expect(topArtists.single.playCount, 55);

      final topAlbums = await home.fetchTopAlbums();
      expect(topAlbums.single.name, 'In Rainbows');
      expect(topAlbums.single.playCount, 30);

      final loved = await lb.loveTrack('Radiohead', 'Nude', true);
      expect(loved, isTrue);
      expect(requests, contains('POST /1/feedback/recording-feedback'));
    });
  });

  group('LibreFmScrobbler reads & love', () {
    test('parses Last.fm 2.0 compatible responses from Libre.fm', () async {
      await prefs.setLibreFm(session: 'sk', user: 'bob', server: '');
      final dio = Dio()
        ..httpClientAdapter = _StubAdapter((opt) async {
          final body = opt.data as Map<String, String>;
          final method = body['method'];
          if (method == 'user.getrecenttracks') {
            return _jsonBody({
              'recenttracks': {
                'track': [
                  {
                    'name': 'Paranoid Android',
                    'artist': {'#text': 'Radiohead'},
                    'date': {'uts': '1700000100'},
                  },
                ],
              },
            });
          }
          if (method == 'user.getinfo') {
            return _jsonBody({'user': {'playcount': '88'}});
          }
          if (method == 'user.gettoptracks') {
            return _jsonBody({
              'toptracks': {
                '@attr': {'total': '40'},
                'track': [
                  {
                    'name': 'Paranoid Android',
                    'artist': {'name': 'Radiohead'},
                    'playcount': '12',
                  },
                ],
              },
            });
          }
          if (method == 'user.gettopartists') {
            return _jsonBody({
              'topartists': {
                '@attr': {'total': '18'},
                'artist': [
                  {'name': 'Radiohead', 'playcount': '25'},
                ],
              },
            });
          }
          if (method == 'user.gettopalbums') {
            return _jsonBody({
              'topalbums': {
                '@attr': {'total': '9'},
                'album': [
                  {
                    'name': 'OK Computer',
                    'artist': {'name': 'Radiohead'},
                    'playcount': '20',
                  },
                ],
              },
            });
          }
          if (method == 'track.love') {
            return _jsonBody({'status': 'ok'});
          }
          return _jsonBody({}, status: 404);
        });

      final lf = LibreFmScrobbler(prefs, dio);
      final home = HomeRepository(
        LastFmApiService(Dio(), LastFmRateGuard()),
        prefs,
        activeKind: ScrobblerKind.librefm,
        libreFm: lf,
      );

      final recent = await home.fetchRecentTracks();
      expect(recent.single.name, 'Paranoid Android');

      final stats = await home.fetchStats();
      expect(stats.scrobbles, 88);
      expect(stats.trackCount, 40);
      expect(stats.artistCount, 18);
      expect(stats.albumCount, 9);

      final topAlbums = await home.fetchTopAlbums();
      expect(topAlbums.single.name, 'OK Computer');
    });
  });
}
