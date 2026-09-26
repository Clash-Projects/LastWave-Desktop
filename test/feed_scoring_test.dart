import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/feed/feed_repository.dart';
import 'package:lastwave_desktop/features/innertube/innertube_api.dart';

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
    });

    test('maps junk to empty', () {
      expect(normalizeArtistKey(''), '');
      expect(normalizeArtistKey('Unknown Artist'), '');
      expect(normalizeArtistKey('VARIOUS ARTISTS'), '');
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

  group('rankNewReleases', () {
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
}
