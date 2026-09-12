import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/env/app_env.dart';
import '../../core/network/lastfm_api.dart';
import '../../core/storage/prefs.dart';
import 'auth_repository.dart';

/// Track/artist/album/user models for Last.fm data.
/// Mirrors `data/model/*` in LastWave-native (subset used by desktop).
class HomeTrack {
  final String name;
  final String artist;
  final String artworkUrl;
  final int? timestampMillis;
  final int playCount;
  const HomeTrack({
    required this.name,
    required this.artist,
    this.artworkUrl = '',
    this.timestampMillis,
    this.playCount = 0,
  });

  String get key => '${name.toLowerCase()}|${artist.toLowerCase()}';
}

class HomeStats {
  final int scrobbles;
  final int artistCount;
  final int albumCount;
  final int trackCount;
  final String avatarUrl;
  const HomeStats({
    this.scrobbles = 0,
    this.artistCount = 0,
    this.albumCount = 0,
    this.trackCount = 0,
    this.avatarUrl = '',
  });
}

class FriendEntry {
  final String name;
  final String realName;
  final String avatarUrl;
  const FriendEntry({
    required this.name,
    this.realName = '',
    this.avatarUrl = '',
  });
}

/// Browsing profile state (own vs. friend), mirrors
/// `ViewingProfileState` in LastWave-native.
class ViewingProfile extends StateNotifier<String?> {
  ViewingProfile() : super(null);
  void view(String? username) => state = username;
  void clear() => state = null;
}

final viewingProfileProvider =
    StateNotifierProvider<ViewingProfile, String?>(
        (_) => ViewingProfile());

/// Profile/stats/home repository.
///
/// Ported from LastWave-native `data/repository/HomeRepository.kt`.
class HomeRepository {
  final LastFmApiService _api;
  final Prefs _prefs;

  HomeRepository(this._api, this._prefs);

  String get _apiKey => AppEnv.lastfmApiKey;

  String? _effectiveUser(String? viewingAs) =>
      viewingAs ?? (_prefs.username.isEmpty ? null : _prefs.username);

  Map<String, dynamic> _asMap(Object? v) =>
      v is Map<String, dynamic> ? v : const {};

  List<Map<String, dynamic>> _asList(Object? v) {
    if (v is List) {
      return v.whereType<Map<String, dynamic>>().toList();
    }
    if (v is Map<String, dynamic>) return [v];
    return const [];
  }

  String _bestImage(Object? images) {
    var fallback = '';
    for (final img in _asList(images)) {
      final url = img['#text']?.toString() ?? '';
      if (url.isEmpty || url.contains('2a96cbd8b46e442fc41c2b86b821b4e')) {
        continue;
      }
      fallback = url;
      final size = img['size']?.toString() ?? '';
      if (size == 'extralarge' || size == 'large') return url;
    }
    return fallback;
  }

  Future<List<HomeTrack>> fetchRecentTracks({
    String? viewingAs,
    int limit = 30,
    int page = 1,
  }) async {
    final user = _effectiveUser(viewingAs);
    if (user == null) return const [];
    final json = await _api.get({
      'method': 'user.getrecenttracks',
      'user': user,
      'api_key': _apiKey,
      'limit': '$limit',
      'page': '$page',
      'extended': '0',
    });
    final tracks = _asList(_asMap(json['recenttracks'])['track']);
    final out = <HomeTrack>[];
    for (final t in tracks) {
      final attr = _asMap(t['@attr']);
      if (attr['nowplaying'] == 'true') continue;
      final artist = t['artist'] is Map
          ? (t['artist'] as Map)['#text']?.toString() ?? ''
          : t['artist']?.toString() ?? '';
      final date = _asMap(t['date'])['uts']?.toString() ?? '';
      out.add(HomeTrack(
        name: t['name']?.toString() ?? '',
        artist: artist,
        artworkUrl: _bestImage(t['image']),
        timestampMillis:
            int.tryParse(date)?.let((s) => s * 1000),
      ));
    }
    return out.where((t) => t.name.isNotEmpty).toList();
  }

  Future<HomeStats> fetchStats({String? viewingAs}) async {
    final user = _effectiveUser(viewingAs);
    if (user == null) return const HomeStats();
    final results = await Future.wait([
      _api.get({
        'method': 'user.getinfo',
        'user': user,
        'api_key': _apiKey,
      }),
      _api.get({
        'method': 'user.gettoptracks',
        'user': user,
        'api_key': _apiKey,
        'limit': '1',
        'period': 'overall',
      }),
      _api.get({
        'method': 'user.gettopartists',
        'user': user,
        'api_key': _apiKey,
        'limit': '1',
        'period': 'overall',
      }),
      _api.get({
        'method': 'user.gettopalbums',
        'user': user,
        'api_key': _apiKey,
        'limit': '1',
        'period': 'overall',
      }),
    ]);
    int totalAttr(Map<String, dynamic> root, String key) {
      final attr = _asMap(_asMap(root[key])['@attr']);
      return int.tryParse(attr['total']?.toString() ?? '') ?? 0;
    }

    final info = _asMap(results[0]['user']);
    return HomeStats(
      scrobbles: int.tryParse(info['playcount']?.toString() ?? '') ?? 0,
      trackCount: totalAttr(results[1], 'toptracks'),
      artistCount: totalAttr(results[2], 'topartists'),
      albumCount: totalAttr(results[3], 'topalbums'),
      avatarUrl: _bestImage(info['image']),
    );
  }

  Future<List<HomeTrack>> fetchTopTracks({
    String? viewingAs,
    String period = '7day',
    int limit = 20,
  }) async {
    final user = _effectiveUser(viewingAs);
    if (user == null) return const [];
    final json = await _api.get({
      'method': 'user.gettoptracks',
      'user': user,
      'api_key': _apiKey,
      'period': period,
      'limit': '$limit',
    });
    return _asList(_asMap(json['toptracks'])['track'])
        .map((t) => HomeTrack(
              name: t['name']?.toString() ?? '',
              artist: _asMap(t['artist'])['name']?.toString() ??
                  t['artist']?.toString() ??
                  '',
              artworkUrl: _bestImage(t['image']),
              playCount:
                  int.tryParse(t['playcount']?.toString() ?? '') ?? 0,
            ))
        .where((t) => t.name.isNotEmpty)
        .toList();
  }

  Future<List<FriendEntry>> fetchFriends() async {
    if (_prefs.username.isEmpty || _prefs.sessionKey.isEmpty) {
      return const [];
    }
    final json = await _api.get({
      'method': 'user.getfriends',
      'user': _prefs.username,
      'api_key': _apiKey,
      'sk': _prefs.sessionKey,
      'limit': '50',
    });
    return _asList(_asMap(json['friends'])['user'])
        .map((u) => FriendEntry(
              name: u['name']?.toString() ?? '',
              realName: u['realname']?.toString() ?? '',
              avatarUrl: _bestImage(u['image']),
            ))
        .where((f) => f.name.isNotEmpty)
        .toList();
  }
}

extension _Let<T> on T {
  R let<R>(R Function(T) fn) => fn(this);
}

final homeRepositoryProvider = Provider<HomeRepository>((ref) {
  return HomeRepository(
    ref.watch(lastFmApiProvider),
    ref.watch(prefsProvider),
  );
});
