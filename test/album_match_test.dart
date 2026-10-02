import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/innertube/album_match.dart';
import 'package:lastwave_desktop/features/innertube/innertube_api.dart';

YouTubeMusicEntity album(
  String name,
  String artist, {
  String subtitle = '',
  String browseId = 'MPREb_test',
}) =>
    YouTubeMusicEntity(
      kind: YouTubeEntityKind.album,
      name: name,
      artist: artist,
      subtitle: subtitle,
      browseId: browseId,
    );

void main() {
  group('pickBestAlbumMatch minScore', () {
    test('exact title and artist passes every bar', () {
      final results = [
        album('After Hours', 'The Weeknd', browseId: 'MPREb_right'),
      ];
      expect(
        pickBestAlbumMatch(results,
            title: 'After Hours', artist: 'The Weeknd'),
        isNotNull,
      );
      expect(
        pickBestAlbumMatch(results,
            title: 'After Hours',
            artist: 'The Weeknd',
            minScore: 150),
        isNotNull,
      );
    });

    test('substring title without artist fails the backfill bar', () {
      // Score 60: substring title, no artist confirmation. Good
      // enough for explicit album text, rejected for backfilled
      // guesses that would otherwise open a wrong album page.
      final results = [
        album('After Hours Deluxe Edition', '',
            browseId: 'MPREb_weak'),
      ];
      expect(
        pickBestAlbumMatch(results,
            title: 'After Hours', artist: 'The Weeknd'),
        isNotNull,
      );
      expect(
        pickBestAlbumMatch(results,
            title: 'After Hours',
            artist: 'The Weeknd',
            minScore: 150),
        isNull,
      );
    });

    test('commentary noise fails the backfill bar', () {
      final results = [
        album('After Hours', 'The Weeknd',
            subtitle: 'Track by Track Commentary',
            browseId: 'MPREb_commentary'),
      ];
      expect(
        pickBestAlbumMatch(results,
            title: 'After Hours', artist: 'The Weeknd'),
        isNotNull,
      );
      expect(
        pickBestAlbumMatch(results,
            title: 'After Hours',
            artist: 'The Weeknd',
            minScore: 150),
        isNull,
      );
    });

    test('unrelated titles fail every bar', () {
      final results = [
        album('Dawn FM', 'The Weeknd', browseId: 'MPREb_other'),
      ];
      expect(
        pickBestAlbumMatch(results,
            title: 'After Hours', artist: 'The Weeknd'),
        isNull,
      );
      expect(
        pickBestAlbumMatch(results,
            title: 'After Hours',
            artist: 'The Weeknd',
            minScore: 150),
        isNull,
      );
    });
  });
}
