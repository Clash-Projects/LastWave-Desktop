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

  test('quick picks are YouTube\'s own, in YouTube\'s order', () {
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
      ['Song 1', 'Song 2', 'Song 3', 'Song 4'],
    );
  });

  test('Last.fm fills quick picks only when YouTube sent none', () {
    final blend = blendHomeFeed(
      shelves: [_shelf('Mixed for you', ['A', 'B', 'C'])],
      feed: FeedData(
        heavyRotation: [_gen('Taste', 'Fav')],
        quickPicks: [_gen('Chart hit', 'Stranger')],
        tasteAffinities: const {'fav': 2},
      ),
    );
    // Charts with no taste match stay out; real taste picks fill in.
    expect(blend.quickPicks.map((t) => t.name), ['Taste']);
  });

  test('a shelf keeps YouTube\'s order — nothing is re-ranked by taste', () {
    final blend = blendHomeFeed(
      shelves: [
        _shelf('Mixed for you', [
          for (var i = 0; i < 12; i++) 'Other$i',
        ]..[3] = 'Fav'..[11] = 'Fav2'),
      ],
      feed: const FeedData(tasteAffinities: {'fav': 2, 'fav2': 2}),
    );
    final artists =
        blend.personal.single.trackCards.map((t) => t.artist).toList();
    expect(artists.indexOf('Fav'), 3);
    expect(artists.indexOf('Fav2'), 11);
  });

  test('shelves keep YouTube\'s order', () {
    final blend = blendHomeFeed(
      shelves: [
        _shelf('Mixed for you', ['X', 'Y', 'Z']),
        _shelf('Your favorites', ['Fav', 'Fav', 'Fav']),
        _shelf('Sunday picks', ['A', 'B', 'C']),
      ],
      feed: const FeedData(tasteAffinities: {'fav': 2}),
    );
    expect(blend.personal.map((s) => s.title),
        ['Mixed for you', 'Your favorites', 'Sunday picks']);
  });

  test('only podcasts and too-thin rows are dropped, not off-taste shelves',
      () {
    final blend = blendHomeFeed(
      shelves: [
        _shelf('Podcasts for you', ['A', 'B', 'C']),
        _shelf('Just one', ['A']),
        _shelf('Random stuff', ['A', 'B', 'C']),
        _shelf('Music videos', ['A', 'B', 'C']),
      ],
      feed: const FeedData(tasteAffinities: {'fav': 2}),
    );
    expect(blend.personal.map((s) => s.title), ['Random stuff', 'Music videos']);
    expect(blend.general, isEmpty);
  });

  test('every YouTube shelf is kept, with no cap', () {
    final blend = blendHomeFeed(
      shelves: [
        for (final t in ['Charts', 'New releases', 'Trending', 'Top albums'])
          _shelf(t, ['A', 'B', 'C']),
      ],
      feed: const FeedData(),
    );
    expect(blend.personal.length, 4);
    expect(blend.general, isEmpty);
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
