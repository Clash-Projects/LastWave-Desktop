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

  const SearchResultItem({
    required this.name,
    this.artist = '',
    this.artworkUrl = '',
    this.subtitle = '',
    this.videoId = '',
    this.entityId = '',
    required this.tab,
  });
}

/// Unified search: YouTube Music for content tabs, Last.fm for users.
/// Mirrors LastWave-native `SearchRepository` + `SearchHistoryRepository`.
class SearchRepository {
  final LastFmApiService _api;
  final InnerTubeMusicApi _tube;
  final AppDatabase _db;
  final String Function() _apiKey;

  SearchRepository(this._api, this._tube, this._db, this._apiKey);

  Future<List<String>> getSuggestions(String query) =>
      _tube.getSuggestions(query);

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

  List<String> history() => _db.loadSearchHistory();
  void pushHistory(String q) {
    if (q.trim().isNotEmpty) _db.pushSearchHistory(q.trim());
  }

  void clearHistory() => _db.clearSearchHistory();
}

final searchRepositoryProvider = Provider<SearchRepository>((ref) {
  return SearchRepository(
    ref.watch(lastFmApiProvider),
    ref.watch(innerTubeProvider),
    ref.watch(databaseProvider),
    () => ref.watch(prefsApiKeyProvider),
  );
});
