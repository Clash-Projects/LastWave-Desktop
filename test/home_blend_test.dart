import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/storage/app_database.dart';
import 'package:lastwave_desktop/features/feed/feed_repository.dart';
import 'package:lastwave_desktop/features/feed/home_blend.dart';
import 'package:lastwave_desktop/features/innertube/innertube_api.dart';

YouTubeMusicTrack _yt(String id, String artist, {String art = 'http://a'}) =>
    YouTubeMusicTrack(
      videoId: id,
      title: 'Song $id',
      artist: artist,
      artworkUrl: art,
    );

GeneratedTrack _gen(String name, String artist) => GeneratedTrack(
      name: name,
      artist: artist,
      artworkUrl: 'http://a',
    );

YtHomeShelf _shelf(String title, List<String> artists) => YtHomeShelf(
      title: title,
      trackCards: [
        for (var i = 0; i < artists.length; i++)
          _yt('$title$i', artists[i]),
      ],
    );

void main() {
  test('classifies shelves, with junk beating every other word', () {
    expect(classifyYtShelf('Quick picks'), YtShelfTier.quickPicks);
    expect(classifyYtShelf('Listen again'), YtShelfTier.listenAgain);
    expect(classifyYtShelf('Mixed for you'), YtShelfTier.personal);
    expect(classifyYtShelf('New releases'), YtShelfTier.general);
    expect(classifyYtShelf('Recommended music videos'), YtShelfTier.junk);
    expect(classifyYtShelf('Live performances'), YtShelfTier.junk);
    expect(classifyYtShelf('Something else'), YtShelfTier.unknown);
  });

  test('quick picks blend YouTube and Last.fm, two to one, without repeats',
      () {
    final blend = blendHomeFeed(
      shelves: [
        YtHomeShelf(title: 'Quick picks', tracks: [
          _yt('1', 'A'),
          _yt('2', 'B'),
          _yt('3', 'C'),
          _yt('4', 'D'),
        ]),
      ],
      feed: FeedData(
        heavyRotation: [_gen('Taste', 'Fav'), _gen('Song 1', 'A')],
        tasteAffinities: const {'fav': 2},
      ),
    );
    expect(
      blend.quickPicks.map((t) => t.name),
      ['Song 1', 'Song 2', 'Taste', 'Song 3', 'Song 4'],
    );
  });

  test('picks with no taste match, like charts, stay out of the blend', () {
    final blend = blendHomeFeed(
      shelves: [
        YtHomeShelf(title: 'Quick picks', tracks: [_yt('1', 'A')]),
      ],
      feed: FeedData(
        quickPicks: [_gen('Chart hit', 'Stranger')],
        tasteAffinities: const {'fav': 2},
      ),
    );
    expect(blend.quickPicks.map((t) => t.name), ['Song 1']);
  });

  test('a favourite artist rises inside a shelf but cannot jump far', () {
    final blend = blendHomeFeed(
      shelves: [
        _shelf('Mixed for you', [
          for (var i = 0; i < 12; i++) 'Other$i',
        ]..[3] = 'Fav'..[11] = 'Fav2'),
      ],
      feed: const FeedData(tasteAffinities: {'fav': 2, 'fav2': 2}),
    );
    final artists = blend.personal.single.trackCards.map((t) => t.artist).toList();
    expect(artists.first, 'Fav');
    expect(artists.indexOf('Fav2'), greaterThan(0));
  });

  test('shelves closest to your taste come first', () {
    final blend = blendHomeFeed(
      shelves: [
        _shelf('Mixed for you', ['X', 'Y', 'Z']),
        _shelf('Your favorites', ['Fav', 'Fav', 'Fav']),
      ],
      feed: const FeedData(tasteAffinities: {'fav': 2}),
    );
    expect(blend.personal.map((s) => s.title),
        ['Your favorites', 'Mixed for you']);
  });

  test('drops junk, thin rows, blank artwork and off-taste unknown shelves',
      () {
    final blend = blendHomeFeed(
      shelves: [
        _shelf('Music videos for you', ['A', 'B', 'C']),
        _shelf('Mixed for you', ['A', 'B']),
        YtHomeShelf(title: 'More from you', trackCards: [
          _yt('1', 'A', art: ''),
          _yt('2', 'B', art: ''),
          _yt('3', 'C'),
        ]),
        _shelf('Random stuff', ['A', 'B', 'C']),
        _shelf('Sunday picks', ['Fav', 'B', 'C']),
      ],
      feed: const FeedData(tasteAffinities: {'fav': 2}),
    );
    expect(blend.personal.map((s) => s.title), ['Sunday picks']);
    expect(blend.general, isEmpty);
  });

  test('general shelves are capped and kept apart from personal ones', () {
    final blend = blendHomeFeed(
      shelves: [
        for (final t in ['Charts', 'New releases', 'Trending', 'Top albums'])
          _shelf(t, ['A', 'B', 'C']),
      ],
      feed: const FeedData(),
    );
    expect(blend.general.length, 3);
    expect(blend.personal, isEmpty);
  });

  test('hidden tracks stay hidden in YouTube shelves too', () {
    final blend = blendHomeFeed(
      shelves: [
        YtHomeShelf(title: 'Quick picks', tracks: [
          _yt('1', 'A'),
          _yt('2', 'B'),
        ]),
      ],
      feed: const FeedData(),
      excluded: {AppDatabase.exclusionKey('Song 1', 'A')},
    );
    expect(blend.quickPicks.map((t) => t.name), ['Song 2']);
  });

  test('artists come only from real taste, split out of collabs', () {
    final blend = blendHomeFeed(
      shelves: const [],
      feed: FeedData(
        heavyRotation: [_gen('S', 'Fav & Stranger')],
        tasteAffinities: const {'fav': 2},
      ),
    );
    expect(blend.artists.map((a) => a.name), ['Fav']);
    expect(blend.hasYouTube, isFalse);
  });
}
