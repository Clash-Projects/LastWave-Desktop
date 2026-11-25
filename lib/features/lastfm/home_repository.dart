import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/lastfm_api.dart';
import '../../core/storage/prefs.dart';
import '../scrobblers/extra_scrobblers.dart';
import '../scrobblers/scrobbler_session.dart';
import 'auth_repository.dart';
import 'home_models.dart';

export 'home_models.dart';

/// Profile/stats/home repository.
///
/// Dispatches reads to whichever scrobbler backend is currently active
/// (`Last.fm`, `ListenBrainz`, or `Libre.fm`), or returns empty when running
/// in Guest / Local-only mode.
class HomeRepository {
  final LastFmApiService _api;
  final Prefs _prefs;
  final ScrobblerKind? _activeKind;
  final ListenBrainzScrobbler? _listenBrainz;
  final LibreFmScrobbler? _libreFm;

  HomeRepository(
    this._api,
    this._prefs, {
    ScrobblerKind? activeKind,
    ListenBrainzScrobbler? listenBrainz,
    LibreFmScrobbler? libreFm,
  })  : _activeKind = activeKind,
        _listenBrainz = listenBrainz,
        _libreFm = libreFm;

  String get _apiKey => _prefs.lastFmApiKey;

  ScrobblerReadBackend? get _activeExtraBackend => switch (_activeKind) {
        ScrobblerKind.listenbrainz => _listenBrainz,
        ScrobblerKind.librefm => _libreFm,
        _ => null,
      };

  String? _effectiveLastFmUser(String? viewingAs) {
    final user = viewingAs ?? (_prefs.username.isEmpty ? null : _prefs.username);
    if (user == null || _apiKey.isEmpty) return null;
    return user;
  }

  Future<List<HomeTrack>> fetchRecentTracks({
    String? viewingAs,
    int limit = 30,
    int page = 1,
  }) async {
    final extra = _activeExtraBackend;
    if (extra != null) {
      return extra.fetchRecentTracks(
        viewingAs: viewingAs,
        limit: limit,
        page: page,
      );
    }
    if (_activeKind == null && viewingAs == null) return const [];
    final user = _effectiveLastFmUser(viewingAs);
    if (user == null) return const [];
    final json = await _api.get({
      'method': 'user.getrecenttracks',
      'user': user,
      'api_key': _apiKey,
      'limit': '$limit',
      'page': '$page',
      'extended': '0',
    });
    return LastFmResponseParser.parseRecentTracks(json);
  }

  Future<HomeStats> fetchStats({String? viewingAs}) async {
    final extra = _activeExtraBackend;
    if (extra != null) {
      return extra.fetchStats(viewingAs: viewingAs);
    }
    if (_activeKind == null && viewingAs == null) return const HomeStats();
    final user = _effectiveLastFmUser(viewingAs);
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
    return LastFmResponseParser.parseStats(
      userInfoJson: results[0],
      topTracksJson: results[1],
      topArtistsJson: results[2],
      topAlbumsJson: results[3],
    );
  }

  Future<int> fetchPeriodPlayCount({
    String? viewingAs,
    required int fromMillis,
    required int toMillis,
  }) async {
    final extra = _activeExtraBackend;
    if (extra != null) {
      return extra.fetchPeriodPlayCount(
        viewingAs: viewingAs,
        fromMillis: fromMillis,
        toMillis: toMillis,
      );
    }
    if (_activeKind == null && viewingAs == null) return 0;
    final user = _effectiveLastFmUser(viewingAs);
    if (user == null) return 0;
    final json = await _api.get({
      'method': 'user.getrecenttracks',
      'user': user,
      'api_key': _apiKey,
      'from': '${fromMillis ~/ 1000}',
      'to': '${toMillis ~/ 1000}',
      'limit': '1',
      'page': '1',
    });
    return LastFmResponseParser.parsePeriodPlayCount(json);
  }

  Future<List<HomeTrack>> fetchTopTracks({
    String? viewingAs,
    String period = '7day',
    int limit = 20,
  }) async {
    final extra = _activeExtraBackend;
    if (extra != null) {
      return extra.fetchTopTracks(
        viewingAs: viewingAs,
        period: period,
        limit: limit,
      );
    }
    if (_activeKind == null && viewingAs == null) return const [];
    final user = _effectiveLastFmUser(viewingAs);
    if (user == null) return const [];
    final json = await _api.get({
      'method': 'user.gettoptracks',
      'user': user,
      'api_key': _apiKey,
      'period': period,
      'limit': '$limit',
    });
    return LastFmResponseParser.parseTopTracks(json);
  }

  Future<List<({String name, int playCount, String artworkUrl})>> fetchTopArtists({
    String? viewingAs,
    String period = '7day',
    int limit = 20,
  }) async {
    final extra = _activeExtraBackend;
    if (extra != null) {
      return extra.fetchTopArtists(
        viewingAs: viewingAs,
        period: period,
        limit: limit,
      );
    }
    if (_activeKind == null && viewingAs == null) return const [];
    final user = _effectiveLastFmUser(viewingAs);
    if (user == null) return const [];
    try {
      final json = await _api.get({
        'method': 'user.gettopartists',
        'user': user,
        'api_key': _apiKey,
        'period': period,
        'limit': '$limit',
      });
      return LastFmResponseParser.parseTopArtists(json);
    } catch (_) {
      return const [];
    }
  }

  Future<List<({String name, String artist, int playCount, String artworkUrl})>>
      fetchTopAlbums({
    String? viewingAs,
    String period = '7day',
    int limit = 20,
  }) async {
    final extra = _activeExtraBackend;
    if (extra != null) {
      return extra.fetchTopAlbums(
        viewingAs: viewingAs,
        period: period,
        limit: limit,
      );
    }
    if (_activeKind == null && viewingAs == null) return const [];
    final user = _effectiveLastFmUser(viewingAs);
    if (user == null) return const [];
    try {
      final json = await _api.get({
        'method': 'user.gettopalbums',
        'user': user,
        'api_key': _apiKey,
        'period': period,
        'limit': '$limit',
      });
      return LastFmResponseParser.parseTopAlbums(json);
    } catch (_) {
      return const [];
    }
  }
}

final homeRepositoryProvider = Provider<HomeRepository>((ref) {
  final session = ref.watch(activeScrobblerSessionProvider);
  return HomeRepository(
    ref.watch(lastFmApiProvider),
    ref.watch(prefsProvider),
    activeKind: session.kind,
    listenBrainz: ref.watch(listenBrainzProvider),
    libreFm: ref.watch(libreFmProvider),
  );
});
