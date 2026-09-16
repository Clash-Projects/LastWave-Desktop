import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/lastfm_api.dart';
import '../../core/storage/app_database.dart';
import '../innertube/innertube_api.dart';
import '../lastfm/auth_repository.dart';
import 'shared_providers.dart';

enum SearchTab { tracks, artists, albums, playlists, users }

class SearchResultItem {
  final String name;
  final String artist;
  final String artworkUrl;
  final String subtitle;
  final String videoId;
  final String entityId;
  final SearchTab tab;
  final int durationSeconds;

  const SearchResultItem({
    required this.name,
    this.artist = '',
    this.artworkUrl = '',
    this.subtitle = '',
    this.videoId = '',
    this.entityId = '',
    required this.tab,
    this.durationSeconds = 0,
  });
}

class SearchSuggestion {
  final String text;
  final SearchTab tab;
  final String subtitle;
  final String artworkUrl;
  final String artist;

  const SearchSuggestion({
    required this.text,
    required this.tab,
    this.subtitle = '',
    this.artworkUrl = '',
    this.artist = '',
  });
}

final _suggestionJunk = RegExp(
  r'\b(edit|slowed|reverb|nightcore|tiktok|gameplay|walkthrough|trailer|metroid|minecraft|fortnite|tv live)\b',
  caseSensitive: false,
);

/// True when [name] is an artist/song/album title for the typed [query]
/// ("metro" → Metro Boomin) rather than a loose YouTube complete hit.
bool suggestionNameMatchesQuery(String name, String query) {
  final n = name.toLowerCase().trim();
  final q = query.toLowerCase().trim();
  if (q.length < 2 || n.isEmpty) return false;
  if (n == q || n.startsWith(q)) return true;
  for (final word in n.split(RegExp(r'[\s\-_/&,+.]+'))) {
    if (word.startsWith(q)) return true;
  }
  return false;
}

bool suggestionLooksLikeJunk(String title) =>
    _suggestionJunk.hasMatch(title);

/// Unified search: YouTube Music for content tabs, Last.fm for users.
/// Mirrors LastWave-native `SearchRepository` + `SearchHistoryRepository`.
class SearchRepository {
  final LastFmApiService _api;
  final InnerTubeMusicApi _tube;
  final AppDatabase _db;
  final String Function() _apiKey;

  SearchRepository(this._api, this._tube, this._db, this._apiKey);

  Future<List<SearchSuggestion>> getSuggestions(String query) async {
    final q = query.trim();
    if (q.length < 2) return const [];
    final pair = await Future.wait([
      _tube.searchArtists(q, limit: 5),
      _tube.searchSongs(q, limit: 8),
    ]);
    final artists = pair[0] as List<YouTubeMusicEntity>;
    final songs = pair[1] as List<YouTubeMusicTrack>;
    final out = <SearchSuggestion>[];
    final seen = <String>{};

    void add({
      required String text,
      required SearchTab tab,
      String subtitle = '',
      String artworkUrl = '',
      String artist = '',
    }) {
      final key = '${tab.name}:${text.toLowerCase()}';
      if (!seen.add(key)) return;
      out.add(SearchSuggestion(
        text: text,
        tab: tab,
        subtitle: subtitle,
        artworkUrl: artworkUrl,
        artist: artist,
      ));
    }

    var artistCount = 0;
    for (final a in artists) {
      if (!suggestionNameMatchesQuery(a.name, q)) continue;
      if (suggestionLooksLikeJunk(a.name)) continue;
      add(
        text: a.name,
        tab: SearchTab.artists,
        subtitle: 'Artist',
        artworkUrl: a.artworkUrl,
        artist: a.name,
      );
      artistCount++;
      if (artistCount >= 3) break;
    }

    final artistKeys = out
        .where((s) => s.tab == SearchTab.artists)
        .map((s) => s.text.toLowerCase())
        .toList();
    final requireKnownArtist =
        !q.contains(' ') && artistKeys.isNotEmpty;

    var songCount = 0;
    for (final s in songs) {
      if (!suggestionNameMatchesQuery(s.title, q)) continue;
      if (suggestionLooksLikeJunk(s.title)) continue;
      if (requireKnownArtist) {
        final a = s.artist.toLowerCase();
        final known = artistKeys.any((n) =>
            a == n || a.startsWith(n) || n.startsWith(a) || a.contains(n));
        if (!known) continue;
      }
      add(
        text: s.title,
        tab: SearchTab.tracks,
        subtitle: s.artist.isEmpty ? 'Song' : s.artist,
        artworkUrl: s.artworkUrl,
        artist: s.artist,
      );
      songCount++;
      if (songCount >= 4) break;
    }
    return out;
  }

  Future<List<SearchResultItem>> search(
      SearchTab tab, String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    switch (tab) {
      case SearchTab.tracks:
        final tracks = await _tube.searchSongs(q, limit: 30);
        return tracks
            .map((t) => SearchResultItem(
                  name: t.title,
                  artist: t.artist,
                  artworkUrl: t.artworkUrl,
                  subtitle: t.album,
                  videoId: t.videoId,
                  entityId: t.videoId,
                  tab: tab,
                  durationSeconds: t.durationSeconds,
                ))
            .toList();
      case SearchTab.artists:
        final artists = await _tube.searchArtists(q);
        return artists
            .map((e) => SearchResultItem(
                  name: e.name,
                  subtitle: e.subtitle,
                  artworkUrl: e.artworkUrl,
                  entityId: e.browseId,
                  tab: tab,
                ))
            .toList();
      case SearchTab.albums:
        final albums = await _tube.searchAlbums(q);
        return albums
            .map((e) => SearchResultItem(
                  name: e.name,
                  artist: e.artist,
                  subtitle: e.subtitle,
                  artworkUrl: e.artworkUrl,
                  entityId: e.browseId,
                  tab: tab,
                ))
            .toList();
      case SearchTab.playlists:
        final playlists =
            await _tube.searchPlaylists(q, limit: 30);
        return playlists
            .map((e) => SearchResultItem(
                  name: e.title,
                  artist: e.author,
                  subtitle: [
                    if (e.author.isNotEmpty) e.author,
                    if (e.trackCountText.isNotEmpty)
                      e.trackCountText,
                  ].join(' • '),
                  artworkUrl: e.artworkUrl,
                  entityId: e.id,
                  tab: tab,
                ))
            .toList();
      case SearchTab.users:
        return [?await _lookupUser(q)];
    }
  }

  Future<SearchResultItem?> _lookupUser(String username) async {
    try {
      final json = await _api.get({
        'method': 'user.getinfo',
        'user': username,
        'api_key': _apiKey(),
      });
      final user = json['user'];
      if (user is! Map<String, dynamic>) return null;
      return SearchResultItem(
        name: user['name']?.toString() ?? username,
        subtitle:
            '${user['playcount']?.toString() ?? '0'} scrobbles',
        tab: SearchTab.users,
        entityId: user['name']?.toString() ?? username,
      );
    } catch (_) {
      return null;
    }
  }

  Future<List<YouTubeMusicTrack>> songsFor(
      SearchResultItem item) async {
    if (item.entityId.isEmpty) return const [];
    if (item.tab == SearchTab.tracks && item.videoId.isNotEmpty) {
      final details = await _tube.fetchSongDetails(item.videoId);
      return [?details];
    }
    return _tube.browseSongs(item.entityId, limit: 50);
  }

  /// Best catalog hit for a recent query — artist if the name matches,
  /// otherwise the top song. Used by the empty Search page cards.
  Future<SearchResultItem?> previewForQuery(String query) async {
    final q = query.trim();
    if (q.isEmpty) return null;
    final pair = await Future.wait([
      _tube.searchArtists(q, limit: 3),
      _tube.searchSongs(q, limit: 3),
    ]);
    final artists = pair[0] as List<YouTubeMusicEntity>;
    final songs = pair[1] as List<YouTubeMusicTrack>;
    YouTubeMusicEntity? artistHit;
    for (final a in artists) {
      if (suggestionNameMatchesQuery(a.name, q)) {
        artistHit = a;
        break;
      }
    }
    artistHit ??= artists.isEmpty ? null : artists.first;

    YouTubeMusicTrack? songHit;
    for (final s in songs) {
      if (suggestionNameMatchesQuery(s.title, q)) {
        songHit = s;
        break;
      }
    }
    songHit ??= songs.isEmpty ? null : songs.first;

    if (artistHit != null &&
        suggestionNameMatchesQuery(artistHit.name, q)) {
      return SearchResultItem(
        name: artistHit.name,
        artist: artistHit.name,
        artworkUrl: artistHit.artworkUrl,
        subtitle: artistHit.subtitle,
        entityId: artistHit.browseId,
        tab: SearchTab.artists,
      );
    }
    if (songHit != null) {
      return SearchResultItem(
        name: songHit.title,
        artist: songHit.artist,
        artworkUrl: songHit.artworkUrl,
        subtitle: songHit.album,
        videoId: songHit.videoId,
        entityId: songHit.videoId,
        tab: SearchTab.tracks,
        durationSeconds: songHit.durationSeconds,
      );
    }
    if (artistHit != null) {
      return SearchResultItem(
        name: artistHit.name,
        artist: artistHit.name,
        artworkUrl: artistHit.artworkUrl,
        subtitle: artistHit.subtitle,
        entityId: artistHit.browseId,
        tab: SearchTab.artists,
      );
    }
    return null;
  }

  List<String> history() => _db.loadSearchHistory();
  void pushHistory(String q) {
    if (q.trim().isNotEmpty) _db.pushSearchHistory(q.trim());
  }

  void clearHistory() => _db.clearSearchHistory();
  void removeHistory(String q) => _db.removeSearchHistory(q);
}

final searchRepositoryProvider = Provider<SearchRepository>((ref) {
  return SearchRepository(
    ref.watch(lastFmApiProvider),
    ref.watch(innerTubeProvider),
    ref.watch(databaseProvider),
    () => ref.watch(prefsApiKeyProvider),
  );
});
