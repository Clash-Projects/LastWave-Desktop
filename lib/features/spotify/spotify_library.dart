import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../innertube/innertube_api.dart';
import '../library/playlist_import.dart';
import '../library/playlists.dart';
import 'spotify_session.dart';

enum SpotifyImportPhase { loading, matching, saving }

class SpotifyImportProgress {
  final String name;
  final int index;
  final int playlistCount;
  final SpotifyImportPhase phase;
  final int trackDone;
  final int trackTotal;

  const SpotifyImportProgress(
    this.name,
    this.index,
    this.playlistCount, {
    this.phase = SpotifyImportPhase.loading,
    this.trackDone = 0,
    this.trackTotal = 0,
  });

  /// How far the whole import has moved, including the current playlist.
  double get fraction {
    if (playlistCount <= 0) return 0;
    final within = trackTotal <= 0 ? 0.0 : trackDone / trackTotal;
    final value = (index + within) / playlistCount;
    if (value < 0) return 0;
    if (value > 1) return 1;
    return value;
  }

  String get headline => playlistCount > 1
      ? 'Playlist ${index + 1} of $playlistCount'
      : name;

  String get detail {
    final step = switch (phase) {
      SpotifyImportPhase.loading => 'Loading tracks',
      SpotifyImportPhase.matching => trackTotal > 0
          ? 'Matching $trackDone of $trackTotal tracks'
          : 'Matching tracks',
      SpotifyImportPhase.saving => 'Saving',
    };
    return playlistCount > 1 ? '$name · $step' : step;
  }
}

/// Account playlists and Liked Songs, matched through the existing
/// YouTube matcher and saved as local playlists.
class SpotifyLibraryImporter {
  SpotifyLibraryImporter(this._session, this._dio);

  final SpotifySession _session;
  final Dio _dio;

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
  static const _pathfinder =
      'https://api-partner.spotify.com/pathfinder/v1/query';
  static const _hashLibrary =
      '390c78e5b951029bad359785e69b07b536a509c581cbcd0aded5e5067f187455';
  static const _hashPlaylist =
      '21ea11a6ac75a5f3e01fd365d29c18e0a4a8b7dc09f89bbb5d73910190c6acaf';
  static const _hashLiked =
      '087278b20b743578a6262c2b0b4bcd20d879c503cc359a2285baf083ef944240';

  Future<int> importPlaylists({
    required InnerTubeMusicApi api,
    required PlaylistRepository playlists,
    void Function(SpotifyImportProgress progress)? onProgress,
  }) async {
    final token = await _session.personalToken();
    if (token == null || token.isEmpty) {
      throw StateError(
        _session.lastFailure ?? 'Spotify is not connected.',
      );
    }
    final client = await _session.clientToken();
    final lists = await _userPlaylists(token, client);
    if (lists.isEmpty) return 0;
    var saved = 0;
    for (var i = 0; i < lists.length; i++) {
      final list = lists[i];
      onProgress?.call(SpotifyImportProgress(list.name, i, lists.length));
      final rows = await _playlistTracks(list.id, token, client);
      if (rows.isEmpty) continue;
      final matched = await matchExternalRows(
        api: api,
        rows: rows,
        onProgress: (done, total) {
          onProgress?.call(SpotifyImportProgress(
            list.name,
            i,
            lists.length,
            phase: SpotifyImportPhase.matching,
            trackDone: done,
            trackTotal: total,
          ));
        },
      );
      if (matched.isEmpty) continue;
      onProgress?.call(SpotifyImportProgress(
        list.name,
        i,
        lists.length,
        phase: SpotifyImportPhase.saving,
        trackDone: rows.length,
        trackTotal: rows.length,
      ));
      await importPreview(
        repo: playlists,
        preview: PlaylistImportPreview(
          title: list.name,
          totalRows: rows.length,
          matchedTracks: matched,
        ),
      );
      saved++;
    }
    return saved;
  }

  Future<int> importLiked({
    required InnerTubeMusicApi api,
    required PlaylistRepository playlists,
    void Function(SpotifyImportProgress progress)? onProgress,
  }) async {
    final token = await _session.personalToken();
    if (token == null || token.isEmpty) {
      throw StateError(
        _session.lastFailure ?? 'Spotify is not connected.',
      );
    }
    final client = await _session.clientToken();
    onProgress?.call(const SpotifyImportProgress('Liked Songs', 0, 1));
    final rows = await _likedTracks(token, client);
    if (rows.isEmpty) return 0;
    final matched = await matchExternalRows(
      api: api,
      rows: rows,
      onProgress: (done, total) {
        onProgress?.call(SpotifyImportProgress(
          'Liked Songs',
          0,
          1,
          phase: SpotifyImportPhase.matching,
          trackDone: done,
          trackTotal: total,
        ));
      },
    );
    if (matched.isEmpty) return 0;
    onProgress?.call(SpotifyImportProgress(
      'Liked Songs',
      0,
      1,
      phase: SpotifyImportPhase.saving,
      trackDone: rows.length,
      trackTotal: rows.length,
    ));
    await importPreview(
      repo: playlists,
      preview: PlaylistImportPreview(
        title: 'Spotify Liked Songs',
        totalRows: rows.length,
        matchedTracks: matched,
      ),
    );
    return matched.length;
  }

  Future<List<({String id, String name})>> _userPlaylists(
    String token,
    String? client,
  ) async {
    final out = <({String id, String name})>[];
    var offset = 0;
    for (var page = 0; page < 6; page++) {
      final variables = jsonEncode({
        'filters': ['Playlists'],
        'order': null,
        'textFilter': null,
        'features': <String>[],
        'limit': 50,
        'offset': offset,
        'flatten': false,
        'expandedFolders': <String>[],
        'folderUri': null,
        'includeFoldersWhenFlattening': true,
      });
      final body = await _query(
        token,
        client,
        'libraryV3',
        variables,
        _hashLibrary,
      );
      if (body == null) break;
      final items = body['data']?['me']?['libraryV3']?['items'];
      if (items is! List || items.isEmpty) break;
      for (final item in items) {
        if (item is! Map) continue;
        final wrapper = item['item'];
        if (wrapper is! Map) continue;
        if (wrapper['__typename']?.toString() != 'PlaylistResponseWrapper') {
          continue;
        }
        final data = wrapper['data'];
        if (data is! Map) continue;
        final uri = data['uri']?.toString() ?? '';
        final id = uri.startsWith('spotify:playlist:')
            ? uri.substring('spotify:playlist:'.length)
            : '';
        if (id.isEmpty) continue;
        final name = (data['name']?.toString() ?? '').trim();
        out.add((id: id, name: name.isEmpty ? 'Spotify Playlist' : name));
      }
      if (items.length < 50) break;
      offset += items.length;
    }
    return out;
  }

  Future<List<({String title, String artist, String album})>> _playlistTracks(
    String id,
    String token,
    String? client,
  ) async {
    final rows = <({String title, String artist, String album})>[];
    var offset = 0;
    var total = 1 << 30;
    for (var page = 0; page < 10 && offset < total; page++) {
      final variables = jsonEncode({
        'uri': 'spotify:playlist:$id',
        'offset': offset,
        'limit': 100,
        'enableWatchFeedEntrypoint': false,
      });
      final body = await _query(
        token,
        client,
        'fetchPlaylist',
        variables,
        _hashPlaylist,
      );
      if (body == null) break;
      final playlist = body['data']?['playlistV2'];
      if (playlist is! Map) break;
      final content = playlist['content'];
      if (content is! Map) break;
      total = content['totalCount'] is num
          ? (content['totalCount'] as num).toInt()
          : 0;
      final items = content['items'];
      if (items is! List || items.isEmpty) break;
      for (final item in items) {
        if (item is! Map) continue;
        final track = item['itemV2']?['data'] ?? item['track'];
        final row = _trackRow(track);
        if (row != null) rows.add(row);
      }
      offset += items.length;
    }
    return rows;
  }

  Future<List<({String title, String artist, String album})>> _likedTracks(
    String token,
    String? client,
  ) async {
    final rows = <({String title, String artist, String album})>[];
    var offset = 0;
    var total = 1 << 30;
    for (var page = 0; page < 20 && offset < total; page++) {
      final variables = jsonEncode({'offset': offset, 'limit': 50});
      final body = await _query(
        token,
        client,
        'fetchLibraryTracks',
        variables,
        _hashLiked,
      );
      if (body == null) break;
      final tracks = body['data']?['me']?['library']?['tracks'];
      if (tracks is! Map) break;
      total = tracks['totalCount'] is num
          ? (tracks['totalCount'] as num).toInt()
          : 0;
      final items = tracks['items'];
      if (items is! List || items.isEmpty) break;
      for (final item in items) {
        if (item is! Map) continue;
        final track = item['track'] is Map
            ? ((item['track'] as Map)['data'] ?? item['track'])
            : null;
        final row = _trackRow(track);
        if (row != null) rows.add(row);
      }
      offset += items.length;
    }
    return rows;
  }

  ({String title, String artist, String album})? _trackRow(Object? track) {
    if (track is! Map) return null;
    final name = (track['name']?.toString() ?? '').replaceAll('\u00a0', ' ').trim();
    if (name.isEmpty) return null;
    final artists = <String>[];
    final items = track['artists']?['items'];
    if (items is List) {
      for (final art in items) {
        if (art is! Map) continue;
        final profile = art['profile'];
        final artistName = profile is Map
            ? profile['name']?.toString()
            : art['name']?.toString();
        if (artistName != null && artistName.trim().isNotEmpty) {
          artists.add(artistName.replaceAll('\u00a0', ' ').trim());
        }
      }
    }
    final albumMap = track['albumOfTrack'] ?? track['album'];
    final album = albumMap is Map
        ? (albumMap['name']?.toString() ?? '').replaceAll('\u00a0', ' ').trim()
        : '';
    return (title: name, artist: artists.join(', '), album: album);
  }

  Future<Map<String, dynamic>?> _query(
    String token,
    String? client,
    String operation,
    String variables,
    String hash,
  ) async {
    final extensions = jsonEncode({
      'persistedQuery': {'version': 1, 'sha256Hash': hash},
    });
    final url = '$_pathfinder?operationName=$operation'
        '&variables=${Uri.encodeQueryComponent(variables)}'
        '&extensions=${Uri.encodeQueryComponent(extensions)}';
    try {
      final headers = <String, String>{
        'Authorization': 'Bearer $token',
        'User-Agent': _ua,
        'Accept': 'application/json',
      };
      if (client != null && client.isNotEmpty) {
        headers['Client-Token'] = client;
      }
      final res = await _dio.get<dynamic>(
        url,
        options: Options(headers: headers),
      );
      final data = res.data;
      if (data is Map) {
        return data.map((k, v) => MapEntry(k.toString(), v));
      }
    } catch (_) {}
    return null;
  }
}

final spotifyLibraryProvider = Provider<SpotifyLibraryImporter>((ref) {
  return SpotifyLibraryImporter(
    ref.watch(spotifySessionProvider),
    Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 20),
    )),
  );
});

/// Keeps the inner-tube import off a widget that only has a Ref.
Future<int> importSpotifyPlaylists(
  WidgetRef ref, {
  void Function(SpotifyImportProgress progress)? onProgress,
}) {
  return ref.read(spotifyLibraryProvider).importPlaylists(
        api: ref.read(innerTubeProvider),
        playlists: ref.read(playlistRepositoryProvider.notifier),
        onProgress: onProgress,
      );
}
