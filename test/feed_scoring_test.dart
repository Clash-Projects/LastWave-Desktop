import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/network/lastfm_api.dart';
import 'package:lastwave_desktop/core/network/rate_guard.dart';
import 'package:lastwave_desktop/core/storage/app_database.dart';
import 'package:lastwave_desktop/core/storage/prefs.dart';
import 'package:lastwave_desktop/core/storage/secure_store.dart';
import 'package:lastwave_desktop/features/feed/feed_repository.dart';
import 'package:lastwave_desktop/features/feed/local_taste.dart';
import 'package:lastwave_desktop/features/innertube/innertube_api.dart';
import 'package:lastwave_desktop/features/lastfm/home_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

GeneratedTrack _t(String name, String artist) =>
    GeneratedTrack(name: name, artist: artist);

List<({GeneratedTrack track, double score})> _scored(
        List<(String, String, double)> rows) =>
    [
      for (final (name, artist, score) in rows)
        (
          track: GeneratedTrack(name: name, artist: artist),
          score: score
        ),
    ];

// Offline feed-integration fakes: every network leg is closure-
// injected, so no test touches Last.fm, YouTube, or the artwork
// services. Fake tracks always carry artwork + videoIds so the
// hydration ladder short-circuits before any singleton network call.
HomeTrack ht(String name, String artist) => HomeTrack(
      name: name,
      artist: artist,
      artworkUrl: 'https://art.example/$name.jpg',
    );

YouTubeMusicTrack yt(String title, String artist) =>
    YouTubeMusicTrack(
      videoId: 'v-$title-$artist',
      title: title,
      artist: artist,
      artworkUrl: 'https://art.example/$title.jpg',
    );

GeneratedTrack gt(String name, String artist) => GeneratedTrack(
      name: name,
      artist: artist,
      artworkUrl: 'https://art.example/$name.jpg',
      videoId: 'v-$name-$artist',
    );

Future<FeedRepository> buildRepo({
  String apiKey = '',
  Future<List<HomeTrack>> Function(int limit)? lfmRecent,
  Future<List<HomeTrack>> Function(String period, int limit)? lfmTop,
  Future<List<YouTubeMusicTrack>> Function(int limit)? charts,
  Future<List<YouTubeMusicTrack>> Function()? ytLiked,
  Future<List<YouTubeMusicTrack>> Function()? ytHistory,
  Future<List<GeneratedTrack>> Function(
      String name, String artist, int limit)? similar,
  LocalTaste local = const LocalTaste(),
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = Prefs(await SharedPreferences.getInstance());
  final dio = Dio();
  final api = LastFmApiService(dio, LastFmRateGuard());
  final tube = InnerTubeMusicApi(dio, SecureStore());
  final home = HomeRepository(api, prefs);
  return FeedRepository(
    api,
    tube,
    home,
    () => apiKey,
    db: AppDatabase.inMemory(),
    fetchLfmRecent: lfmRecent,
    fetchLfmTop: lfmTop,
    fetchCharts: charts,
    fetchYtLiked: ytLiked,
    fetchYtHistory: ytHistory,
    fetchLocalTaste: () async => local,
    fetchSimilar: similar,
  );
}

List<YouTubeMusicTrack> chartTracks() =>
    [yt('Chart One', 'Chart Star'), yt('Chart Two', 'Hit Maker')];

List<YouTubeMusicTrack> likedTracks() =>
    [yt('Liked One', 'Beloved'), yt('Liked Two', 'Adored')];

List<YouTubeMusicTrack> historyTracks() =>
    [yt('Watched One', 'Regular'), yt('Watched Two', 'Frequent')];

List<HomeTrack> topTracks() =>
    [ht('Top One', 'Superstar'), ht('Top Two', 'Idol')];

void main() {
  group('normalizeArtistKey', () {
    test('strips featured credits and case', () {
      expect(normalizeArtistKey('Anirudh Ravichander'),
          'anirudh ravichander');
      expect(normalizeArtistKey('Arijit Singh feat. Shreya'),
          'arijit singh');
      expect(
          normalizeArtistKey('Drake (feat. Future)'), 'drake');
      expect(normalizeArtistKey('X ft. Y'), 'x');
      expect(
          normalizeArtistKey('A FEATURING B'), 'a');
      expect(normalizeArtistKey('A with B'), 'a');
      expect(normalizeArtistKey('Skrillex x Fred again..'), 'skrillex');
      expect(normalizeArtistKey('Calvin Harris & Dua Lipa'), 'calvin harris');
      expect(normalizeArtistKey('David Guetta vs Morten'), 'david guetta');
      expect(normalizeArtistKey('Metro Boomin prod. Future'), 'metro boomin');
      expect(normalizeArtistKey('The Weeknd - Topic'), 'the weeknd');
    });

    test('maps junk to empty', () {
      expect(normalizeArtistKey(''), '');
      expect(normalizeArtistKey('Unknown Artist'), '');
      expect(normalizeArtistKey('VARIOUS ARTISTS'), '');
      expect(normalizeArtistKey('various'), '');
      expect(normalizeArtistKey('null'), '');
      expect(normalizeArtistKey('n/a'), '');
      expect(normalizeArtistKey('  '), '');
    });
  });

  group('applyExclusions', () {
    test('drops exact key matches only', () {
      final tracks = [
        GeneratedTrack(name: 'Raga', artist: 'Anirudh'),
        GeneratedTrack(name: 'Paro', artist: 'Aditya'),
      ];
      final out = applyExclusions(tracks, {'raga|anirudh'});
      expect(out.map((t) => t.name).toList(), ['Paro']);
      expect(
          applyExclusions(tracks, const {}).length, 2);
    });
  });

  grougroup('normalizeArtistKey'p('rankNewReleases', () {
    YouTubeMusicEntity album(String name, String artist) =>
        YouTubeMusicEntity(
            kind: YouTubeEntityKind.album,
            name: name,
            artist: artist);

    test('known artists first, shelf order kept otherwise', () {
      final ranked = rankNewReleases(
        [
          album('Global Smash', 'Unknown Popstar'),
          album('Deep Cut', 'Anirudh Ravichander'),
          album('Other Global', 'Someone Else'),
          album('Single', 'Arijit Singh feat. Shreya'),
        ],
        {'anirudh ravichander': 2.0, 'arijit singh': 1.0},
      );
      expect(
          ranked.map((a) => a.name).toList(),
          [
            'Deep Cut',
            'Single',
            'Global Smash',
            'Other Global',
          ]);
    });

    test('empty affinities preserve shelf order, never drops', () {
      final input = [
        album('A', 'X'),
        album('B', 'Y'),
      ];
      final ranked = rankNewReleases(input, const {});
      expect(ranked.map((a) => a.name).toList(), ['A', 'B']);
      expect(ranked.length, input.length);
    });
  });

  group('feedDaySeed', () {
    test('stable within a day, fresh across days', () {
      final morning = DateTime(2026, 9, 26, 8);
      final evening = DateTime(2026, 9, 26, 23, 59);
      final nextDay = DateTime(2026, 9, 27, 0, 1);
      expect(feedDaySeed(morning), feedDaySeed(evening));
      expect(feedDaySeed(morning),
          isNot(feedDaySeed(nextDay)));
    });

    test('seeded Random reproduces the same jitter order', () {
      List<double> draws(int seed) {
        final r = Random(seed);
        return List.generate(5, (_) => r.nextDouble());
      }

      final a = draws(feedDaySeed(DateTime(2026, 9, 26, 12)));
      final b = draws(feedDaySeed(DateTime(2026, 9, 26, 18)));
      expect(a, b);
    });
  });

  group('diversifyFeedTracks', () {
    test('sorts by score descending', () {
      final out = diversifyFeedTracks(_scored([
        ('b', 'A1', 1.0),
        ('a', 'A2', 9.0),
        ('c', 'A3', 5.0),
      ]));
      expect(out.map((t) => t.name).toList(),
          ['a', 'c', 'b']);
    });

    test('caps per-artist and dedupes identical keys', () {
      final out = diversifyFeedTracks(
        _scored([
          ('s1', 'Anirudh', 9.0),
          ('s2', 'Anirudh', 8.0),
          ('s3', 'Anirudh', 7.0),
          ('other', 'Rahman', 6.0),
          ('S1', 'anirudh', 5.0), // same key, different case
        ]),
        limit: 10,
        maxPerArtist: 2,
      );
      expect(out.map((t) => t.name).toList(),
          ['s1', 's2', 'other']);
    });

    test('shared counts cap artists page-wide across sections', () {
      final shared = <String, int>{};
      final heavy = diversifyFeedTracks(
        _scored([
          ('h1', 'Anirudh', 9.0),
          ('h2', 'Anirudh', 8.0),
        ]),
        limit: 5,
        maxPerArtist: 2,
        sharedCounts: shared,
      );
      final quick = diversifyFeedTracks(
        _scored([
          ('q1', 'Anirudh', 9.5),
          ('q2', 'Rahman', 8.5),
        ]),
        limit: 5,
        maxPerArtist: 2,
        sharedCounts: shared,
      );
      // heavy took both Anirudh slots; quick must skip q1 even though
      // it outscores q2.
      expect(heavy.map((t) => t.name).toList(),
          ['h1', 'h2']);
      expect(quick.map((t) => t.name).toList(), ['q2']);
    });
  });

  group('dedupeFeedHeads', () {
    test('drops headlined keys and registers new heads', () {
      final headlined = <String>{};
      final heavy = dedupeFeedHeads(
        [_t('Raga', 'Anirudh'), _t('X', 'Y')],
        headlined,
      );
      expect(heavy.map((t) => t.name).toList(),
          ['Raga', 'X']);
      // quick echoing the hero gets filtered; its own heads register.
      final quick = dedupeFeedHeads(
        [_t('Raga', 'Anirudh'), _t('Paro', 'Aditya')],
        headlined,
      );
      expect(
          quick.map((t) => t.name).toList(), ['Paro']);
      expect(headlined, contains('paro|aditya'));
    });

    test('hero can never echo into companions', () {
      final headlined = <String>{};
      final heavy = dedupeFeedHeads(
          [_t('Same Song', 'Same Artist')], headlined);
      final quick = dedupeFeedHeads(
          [_t('Same Song', 'Same Artist'), _t('Next', 'B')],
          headlined);
      expect(heavy.first.key, isNot(quick.first.key));
    });
  });

  group('FeedData.isEmpty', () {
    test('all sections empty is empty', () {
      expect(const FeedData().isEmpty, isTrue);
    });

    test('charts-only is not empty', () {
      expect(
        FeedData(charts: [gt('C', 'A')]).isEmpty,
        isFalse,
      );
    });

    test('fresh-finds-only is not empty (was ignored)', () {
      expect(
        FeedData(freshFinds: [gt('F', 'A')]).isEmpty,
        isFalse,
      );
    });

    test('jump-back-only is not empty (was ignored)', () {
      expect(
        FeedData(jumpBackIn: [gt('J', 'A')]).isEmpty,
        isFalse,
      );
    });

    test('because-only is not empty (was ignored)', () {
      expect(
        FeedData(becauseYouListened: [gt('B', 'A')])
            .isEmpty,
        isFalse,
      );
    });
  });

  group('resolveEmptyReason', () {
    test('non-empty feed is never an error', () {
      expect(
        resolveEmptyReason(
          online: true,
          data: FeedData(charts: [gt('C', 'A')]),
        ),
        FeedEmptyReason.none,
      );
    });

    test('offline wins over any recorded reason', () {
      expect(
        resolveEmptyReason(
          online: false,
          data: const FeedData(
              emptyReason: FeedEmptyReason.lastfmError),
        ),
        FeedEmptyReason.offline,
      );
    });

    test('recorded reasons survive when online', () {
      for (final reason in [
        FeedEmptyReason.noTaste,
        FeedEmptyReason.lastfmError,
        FeedEmptyReason.chartsError,
        FeedEmptyReason.allFailed,
      ]) {
        expect(
          resolveEmptyReason(
            online: true,
            data: FeedData(emptyReason: reason),
          ),
          reason,
        );
      }
    });
  });

  group('loadFeed degradation', () {
    test('throwing Last.fm legs do not discard loaded charts',
        () async {
      final repo = await buildRepo(
        apiKey: 'bad-key',
        lfmRecent: (_) async => throw Exception('bad key'),
        lfmTop: (period, limit) async =>
            throw Exception('bad key'),
        charts: (_) async => chartTracks(),
        similar: (name, artist, limit) async => const [],
      );
      final data = await repo.loadFeed();
      expect(data.charts, isNotEmpty);
      expect(data.isEmpty, isFalse);
      expect(data.lastFmFailed, isTrue);
      expect(data.chartsFailed, isFalse);
      expect(data.emptyReason, FeedEmptyReason.none);
    });

    test('keyless feed builds from YT liked/history', () async {
      final repo = await buildRepo(
        charts: (_) async => chartTracks(),
        ytLiked: () async => likedTracks(),
        ytHistory: () async => historyTracks(),
        similar: (name, artist, _) async =>
            [gt('Similar to $name', artist)],
      );
      final data = await repo.loadFeed();
      expect(data.isEmpty, isFalse);
      expect(data.lastFmFailed, isFalse);
      // YT liked anchors Heavy Rotation when Last.fm is absent.
      expect(
        data.heavyRotation
            .any((t) => t.artist == 'Beloved'),
        isTrue,
      );
      expect(data.emptyReason, FeedEmptyReason.none);
    });

    test('present Last.fm keeps its flavor (no YT slots)',
        () async {
      final repo = await buildRepo(
        apiKey: 'good-key',
        lfmRecent: (_) async => [ht('Recent One', 'Idol')],
        lfmTop: (period, _) async =>
            period == '7day' ? topTracks() : const [],
        charts: (_) async => chartTracks(),
        ytLiked: () async => likedTracks(),
        ytHistory: () async => historyTracks(),
        similar: (name, artist, limit) async => const [],
      );
      final data = await repo.loadFeed();
      expect(data.isEmpty, isFalse);
      // Heavy Rotation draws from Last.fm top only — YT liked
      // artists must not leak in while Last.fm is active.
      expect(data.heavyRotation, isNotEmpty);
      expect(
        data.heavyRotation
            .every((t) => t.artist != 'Beloved'),
        isTrue,
      );
    });

    test('everything failing reports allFailed', () async {
      final repo = await buildRepo(
        apiKey: 'bad-key',
        lfmRecent: (_) async => throw Exception('down'),
        lfmTop: (period, limit) async =>
            throw Exception('down'),
        charts: (_) async => throw Exception('down'),
        similar: (name, artist, limit) async => const [],
      );
      final data = await repo.loadFeed();
      expect(data.isEmpty, isTrue);
      expect(data.lastFmFailed, isTrue);
      expect(data.chartsFailed, isTrue);
      expect(data.emptyReason, FeedEmptyReason.allFailed);
    });

    test('keyless charts failure is chartsError, never lastfmError',
        () async {
      final repo = await buildRepo(
        charts: (_) async => throw Exception('down'),
        similar: (name, artist, limit) async => const [],
      );
      final data = await repo.loadFeed();
      expect(data.isEmpty, isTrue);
      expect(data.lastFmFailed, isFalse);
      expect(data.chartsFailed, isTrue);
      expect(
          data.emptyReason, FeedEmptyReason.chartsError);
    });

    test('answered-but-tasteless is noTaste', () async {
      final repo = await buildRepo(
        charts: (_) async => const [],
        similar: (name, artist, limit) async => const [],
      );
      final data = await repo.loadFeed();
      expect(data.isEmpty, isTrue);
      expect(data.lastFmFailed, isFalse);
      expect(data.chartsFailed, isFalse);
      expect(data.emptyReason, FeedEmptyReason.noTaste);
    });
  });
}
