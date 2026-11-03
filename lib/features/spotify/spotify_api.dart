import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/artwork/animated_artwork_service.dart'
    show normalizeCanvasMatch;
import '../../core/diagnostics/diagnostics_log.dart';
import '../../core/storage/prefs.dart';
import 'spotify_auth.dart';
import 'spotify_web_player.dart';

/// A playlist of the signed-in Spotify account.
class SpotifyPlaylistSummary {
  /// Spotify playlist id, or [likedId] for the account's Liked Songs.
  final String id;
  final String name;
  final String description;
  final String artworkUrl;
  final int trackCount;
  final String owner;

  const SpotifyPlaylistSummary({
    required this.id,
    required this.name,
    this.description = '',
    this.artworkUrl = '',
    this.trackCount = 0,
    this.owner = '',
  });

  /// Pseudo playlist id for the account's Liked Songs. Shown inside the
  /// Spotify playlists section only — never merged into the app's own
  /// Liked Songs.
  static const likedId = 'liked';

  bool get isLiked => id == likedId;
}

class SpotifyTrackRow {
  final String name;
  final String artist;
  final String album;
  final String artworkUrl;
  final int durationSeconds;
  const SpotifyTrackRow({
    required this.name,
    required this.artist,
    this.album = '',
    this.artworkUrl = '',
    this.durationSeconds = 0,
  });
}

class SpotifyPlaylistContent {
  final String title;
  final String owner;
  final String artworkUrl;
  final List<SpotifyTrackRow> tracks;
  const SpotifyPlaylistContent({
    required this.title,
    required this.tracks,
    this.owner = '',
    this.artworkUrl = '',
  });
}

/// A Spotify Canvas: the short vertical (9:16) looping clip of a track.
class SpotifyCanvasClip {
  final String url;
  final String trackId;
  const SpotifyCanvasClip({required this.url, required this.trackId});
}

/// Result of a Canvas lookup: the clip, or the reason there is none
/// (also written to the diagnostics log; never contains tokens).
class SpotifyCanvasResult {
  final SpotifyCanvasClip? clip;
  final String reason;
  const SpotifyCanvasResult.found(SpotifyCanvasClip this.clip) : reason = '';
  const SpotifyCanvasResult.none(this.reason) : clip = null;
}

/// Spotify web-player GraphQL ("Pathfinder") client: account playlists,
/// Liked Songs, track search and Canvas. Port of the LastWave-Native
/// Spotify importer / canvas code.
class SpotifyApi {
  SpotifyApi(this._auth);
  final SpotifyAuth _auth;

  Dio get _dio => _auth.dio;

  static const _v1 = 'https://api-partner.spotify.com/pathfinder/v1/query';
  static const _v2 = 'https://api-partner.spotify.com/pathfinder/v2/query';
  static const _canvazEndpoint =
      'https://spclient.wg.spotify.com/canvaz-cache/v0/canvases';

  // Last known hashes; the live ones are read from the web player.
  static const _knownCanvasHash =
      '575138ab27cd5c1b3e54da54d0a7cc8d85485402de26340c2145f0f6bb5e7a9f';
  static const _knownLibraryHash =
      '390c78e5b951029bad359785e69b07b536a509c581cbcd0aded5e5067f187455';
  static const _knownPlaylistHash =
      '21ea11a6ac75a5f3e01fd365d29c18e0a4a8b7dc09f89bbb5d73910190c6acaf';
  static const _knownLikedHash =
      '087278b20b743578a6262c2b0b4bcd20d879c503cc359a2285baf083ef944240';

  /// Native's primary search: `searchTracks` with this fixed hash (proven in
  /// LastWave-Native; not read from the player, which no longer declares it).
  static const _searchTracksHash =
      'bc1ca2fcd0ba1013a0fc88e6cc4f190af501851e3dafd3e1ef85840297694428';
  static const _knownSearchHash =
      'f78953bf9207d73493c27284103f5aeb6e728876d5793851bf79bc706127ff70';

  Future<String> _hash(
    String operation,
    String known, {
    bool force = false,
  }) async {
    final script = await SpotifyWebPlayer.script(_dio, force: force);
    final live = script == null
        ? null
        : SpotifyWebPlayer.queryHash(script, operation);
    return live ?? known;
  }

  Future<Map<String, String>?> _authHeaders({bool appPlatform = false}) async {
    final personal = await _auth.personalToken();
    if (personal == null) return null;
    final client = await _auth.clientToken();
    return {
      'Authorization': 'Bearer $personal',
      'Client-Token': ?client,
      'User-Agent': SpotifyWebPlayer.userAgent,
      if (appPlatform) 'App-platform': 'WebPlayer',
      'Accept': 'application/json',
    };
  }

  Future<Map<String, dynamic>?> _query(
    String operation,
    Map<String, Object?> variables,
    String hash, {
    String endpoint = _v1,
  }) async {
    final headers = await _authHeaders();
    if (headers == null) return null;
    try {
      final res = await _dio.get<String>(
        endpoint,
        queryParameters: {
          'operationName': operation,
          'variables': jsonEncode(variables),
          'extensions': jsonEncode({
            'persistedQuery': {'version': 1, 'sha256Hash': hash},
          }),
        },
        options: Options(
          responseType: ResponseType.plain,
          headers: headers,
          validateStatus: (_) => true,
        ),
      );
      if ((res.statusCode ?? 0) ~/ 100 != 2) {
        DiagnosticsLog.info(
          'spotify query op=$operation http=${res.statusCode}',
        );
        return null;
      }
      final body = jsonDecode(res.data ?? '{}');
      return body is Map ? Map<String, dynamic>.from(body) : null;
    } catch (e) {
      DiagnosticsLog.info('spotify query op=$operation error=${e.runtimeType}');
      return null;
    }
  }

  // -- library ------------------------------------------------------------

  /// The account's playlists (Liked Songs first when it has any).
  Future<List<SpotifyPlaylistSummary>> userPlaylists() async {
    final hash = await _hash(
      SpotifyWebPlayer.libraryOperation,
      _knownLibraryHash,
    );
    final out = <SpotifyPlaylistSummary>[];
    var offset = 0;
    for (var page = 0; page < 6; page++) {
      final root = await _query('libraryV3', {
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
      }, hash);
      final lib = _at(root, ['data', 'me', 'libraryV3']);
      if (lib is! Map) break;
      final items = lib['items'];
      if (items is! List || items.isEmpty) break;
      for (final it in items) {
        final wrapper = it is Map ? it['item'] : null;
        if (wrapper is! Map) continue;
        if (wrapper['__typename'] != 'PlaylistResponseWrapper') continue;
        final data = wrapper['data'];
        if (data is! Map) continue;
        final uri = data['uri']?.toString() ?? '';
        final id = uri.replaceFirst('spotify:playlist:', '');
        if (id.isEmpty || !uri.startsWith('spotify:playlist:')) continue;
        out.add(
          SpotifyPlaylistSummary(
            id: id,
            name: data['name']?.toString() ?? 'Spotify playlist',
            description: data['description']?.toString() ?? '',
            artworkUrl: _firstImage(data['images']),
            trackCount:
                _int(_at(data, ['content', 'totalCount'])) ??
                _int(_at(data, ['tracks', 'total'])) ??
                0,
            owner: _text(_at(data, ['ownerV2', 'data', 'name'])),
          ),
        );
      }
      final total = _int(lib['totalCount']) ?? 0;
      offset += items.length;
      if (offset >= total) break;
    }
    return out;
  }

  /// Tracks of one playlist, or the Liked Songs when [id] is
  /// [SpotifyPlaylistSummary.likedId].
  Future<SpotifyPlaylistContent?> playlist(String id) =>
      id == SpotifyPlaylistSummary.likedId ? _liked() : _playlist(id);

  Future<SpotifyPlaylistContent?> _playlist(String id) async {
    final hash = await _hash(
      SpotifyWebPlayer.fetchPlaylistOperation,
      _knownPlaylistHash,
    );
    final rows = <SpotifyTrackRow>[];
    var title = 'Spotify playlist';
    var owner = '';
    var art = '';
    var offset = 0;
    var total = 1 << 30;
    for (var page = 0; offset < total && page < 30; page++) {
      final root = await _query('fetchPlaylist', {
        'uri': 'spotify:playlist:$id',
        'offset': offset,
        'limit': 100,
        'enableWatchFeedEntrypoint': false,
      }, hash);
      final pl = _at(root, ['data', 'playlistV2']);
      if (pl is! Map) {
        if (page == 0) return null;
        break;
      }
      if (page == 0) {
        title = pl['name']?.toString() ?? title;
        owner = _text(_at(pl, ['ownerV2', 'data', 'name']));
        art = _firstImage(pl['images']);
      }
      final content = pl['content'];
      total = _int(content is Map ? content['totalCount'] : null) ?? 0;
      final items = content is Map ? content['items'] : null;
      if (items is! List || items.isEmpty) break;
      for (final it in items) {
        final data = _at(it, ['itemV2', 'data']) ?? _at(it, ['track']);
        final row = _row(data);
        if (row != null) rows.add(row);
      }
      offset += items.length;
    }
    return SpotifyPlaylistContent(
      title: title,
      owner: owner,
      artworkUrl: art,
      tracks: rows,
    );
  }

  Future<SpotifyPlaylistContent?> _liked() async {
    final hash = await _hash('fetchLibraryTracks', _knownLikedHash);
    final rows = <SpotifyTrackRow>[];
    var offset = 0;
    var total = 1 << 30;
    for (var page = 0; offset < total && page < 40; page++) {
      final root = await _query('fetchLibraryTracks', {
        'offset': offset,
        'limit': 50,
      }, hash);
      final tracks = _at(root, ['data', 'me', 'library', 'tracks']);
      if (tracks is! Map) {
        if (page == 0) return null;
        break;
      }
      total = _int(tracks['totalCount']) ?? 0;
      final items = tracks['items'];
      if (items is! List || items.isEmpty) break;
      for (final it in items) {
        final t = it is Map ? it['track'] : null;
        final data = t is Map ? (t['data'] ?? t) : null;
        final row = _row(data);
        if (row != null) rows.add(row);
      }
      offset += items.length;
    }
    return SpotifyPlaylistContent(
      title: 'Liked Songs',
      owner: 'Spotify',
      tracks: rows,
    );
  }

  SpotifyTrackRow? _row(Object? data) {
    if (data is! Map) return null;
    final name = _clean(data['name']?.toString() ?? '');
    if (name.isEmpty) return null;
    final artists = _at(data, ['artists', 'items']);
    final names = <String>[
      if (artists is List)
        for (final a in artists)
          _clean(
            _text(_at(a, ['profile', 'name'])).isNotEmpty
                ? _text(_at(a, ['profile', 'name']))
                : _text(a is Map ? a['name'] : null),
          ),
    ].where((s) => s.isNotEmpty).toList();
    final album = data['albumOfTrack'] ?? data['album'];
    final ms =
        _int(_at(data, ['trackDuration', 'totalMilliseconds'])) ??
        _int(_at(data, ['duration', 'totalMilliseconds'])) ??
        _int(data['duration_ms']) ??
        0;
    return SpotifyTrackRow(
      name: name,
      artist: names.join(', '),
      album: album is Map ? _clean(_text(album['name'])) : '',
      artworkUrl: album is Map
          ? (_firstSource(_at(album, ['coverArt', 'sources'])).isNotEmpty
                ? _firstSource(_at(album, ['coverArt', 'sources']))
                : _firstImage(album['images']))
          : '',
      durationSeconds: ms ~/ 1000,
    );
  }

  // -- canvas -------------------------------------------------------------

  /// The Spotify Canvas of a track, or the reason there is none.
  Future<SpotifyCanvasResult> canvas({
    required String title,
    required String artist,
    int durationMs = 0,
  }) async {
    final tag = 'spotify-canvas "$title" - "$artist"';
    final personal = await _auth.personalToken();
    if (personal == null) {
      DiagnosticsLog.info('$tag stage=session ok=false');
      return const SpotifyCanvasResult.none(
        'Spotify session is not signed in (sign in again in Settings)',
      );
    }
    final match = await _searchTrack(title, artist, durationMs);
    if (match == null) {
      DiagnosticsLog.info('$tag stage=search ok=false');
      return const SpotifyCanvasResult.none(
        'Could not find this track on Spotify',
      );
    }
    final uri = 'spotify:track:${match.id}';
    // Native order: the protobuf route first, the web-player query second.
    var url = await _canvasViaProtobuf(uri);
    final viaQuery = url == null;
    url ??= await _canvasViaQuery(uri);
    DiagnosticsLog.info(
      '$tag stage=canvas track=${match.id} found=${url != null} '
      'route=${url == null ? '-' : (viaQuery ? 'query' : 'protobuf')}',
    );
    if (url == null) {
      return const SpotifyCanvasResult.none('This track has no Spotify Canvas');
    }
    return SpotifyCanvasResult.found(
      SpotifyCanvasClip(url: url, trackId: match.id),
    );
  }

  Future<_SpotifyTrackHit?> _searchTrack(
    String title,
    String artist,
    int durationMs,
  ) async {
    // Native: CLEAN_TITLE_REGEX title + primary artist, then the raw pair.
    final cleanTitle = title.replaceAll(_cleanTitle, '').trim();
    final primary = artist.split(RegExp(r'\s*(?:,|&|feat\.?|ft\.?)\s*')).first;
    final first = '$cleanTitle $primary'.trim();
    final queries = <String>[
      if (first.isNotEmpty) first,
      if ('$title $artist' != first) '$title $artist',
    ];

    final script = await SpotifyWebPlayer.script(_dio);
    // Every search operation the player currently declares, newest name
    // first; the player renames them whenever it is rebuilt.
    final ops = <(String, String)>[
      ('searchTracks', _searchTracksHash),
      for (final name in const [
        'searchDesktop',
        'searchTracks',
        SpotifyWebPlayer.searchOperation,
      ])
        if (name != 'searchTracks' &&
            script != null &&
            SpotifyWebPlayer.queryHash(script, name) != null)
          (name, SpotifyWebPlayer.queryHash(script, name)!),
      (SpotifyWebPlayer.searchOperation, _knownSearchHash),
    ];
    DiagnosticsLog.info(
      'spotify search ops=${ops.map((o) => o.$1).join(",")} '
      'scriptRead=${script != null}',
    );

    for (final (op, hash) in ops) {
      for (final q in queries) {
        final vars = op == 'searchTracks'
            // Exactly what LastWave-Native sends.
            ? <String, Object?>{
                'searchTerm': q,
                'offset': 0,
                'limit': 5,
                'numberOfTopResults': 5,
                'includeAudiobooks': false,
                'includePreReleases': false,
              }
            : <String, Object?>{
                'searchTerm': q,
                'term': q,
                'offset': 0,
                'limit': 10,
                'numberOfTopResults': 5,
                'includeAudiobooks': false,
                'includePreReleases': false,
                'includeAuthors': false,
                'includeArtistHasConcertsField': false,
              };
        for (final endpoint
            in op == 'searchTracks' ? const [_v1] : const [_v1, _v2]) {
          final root = endpoint == _v1
              ? await _query(op, vars, hash)
              : await _post(op, vars, hash);
          if (root == null) continue;
          final hits = _collectTracks(root);
          DiagnosticsLog.info(
            'spotify search op=$op ${endpoint == _v1 ? 'v1' : 'v2'} '
            'tracks=${hits.length}${hits.isEmpty ? _errorsOf(root) : ''}',
          );
          final best = _pick(hits, title, artist, durationMs);
          if (best != null) return best;
        }
      }
    }

    // Web API search as the fallback.
    final headers = await _authHeaders();
    if (headers == null) return null;
    for (final q in ['$title $artist']) {
      try {
        final res = await _dio.get<String>(
          'https://api.spotify.com/v1/search',
          queryParameters: {'type': 'track', 'q': q, 'limit': 5},
          options: Options(
            responseType: ResponseType.plain,
            headers: headers,
            validateStatus: (_) => true,
          ),
        );
        if ((res.statusCode ?? 0) ~/ 100 != 2) {
          DiagnosticsLog.info('spotify search webapi http=${res.statusCode}');
          continue;
        }
        final body = jsonDecode(res.data ?? '{}');
        final items = _at(body, ['tracks', 'items']);
        final hits = <_SpotifyTrackHit>[
          if (items is List)
            for (final it in items)
              if (it is Map && it['id'] is String)
                _SpotifyTrackHit(
                  id: it['id'] as String,
                  name: it['name']?.toString() ?? '',
                  artists: [
                    if (it['artists'] is List)
                      for (final a in it['artists'] as List)
                        if (a is Map) a['name']?.toString() ?? '',
                  ].where((s) => s.isNotEmpty).join(', '),
                  durationMs: _int(it['duration_ms']) ?? 0,
                ),
        ];
        DiagnosticsLog.info('spotify search webapi tracks=${hits.length}');
        final best = _pick(hits, title, artist, durationMs);
        if (best != null) return best;
      } catch (e) {
        DiagnosticsLog.info('spotify search webapi error=${e.runtimeType}');
      }
    }
    return null;
  }

  /// POST form of a persisted query (Pathfinder v2).
  Future<Map<String, dynamic>?> _post(
    String operation,
    Map<String, Object?> variables,
    String hash,
  ) async {
    final headers = await _authHeaders();
    if (headers == null) return null;
    try {
      final res = await _dio.post<String>(
        _v2,
        data: jsonEncode({
          'operationName': operation,
          'variables': variables,
          'extensions': {
            'persistedQuery': {'version': 1, 'sha256Hash': hash},
          },
        }),
        options: Options(
          responseType: ResponseType.plain,
          headers: {...headers, 'Content-Type': 'application/json'},
          validateStatus: (_) => true,
        ),
      );
      if ((res.statusCode ?? 0) ~/ 100 != 2) {
        DiagnosticsLog.info(
          'spotify post op=$operation http=${res.statusCode}',
        );
        return null;
      }
      final body = jsonDecode(res.data ?? '{}');
      return body is Map ? Map<String, dynamic>.from(body) : null;
    } catch (e) {
      DiagnosticsLog.info('spotify post op=$operation error=${e.runtimeType}');
      return null;
    }
  }

  /// First GraphQL error message, for the log (no tokens in these).
  String _errorsOf(Map<String, dynamic> root) {
    final errors = root['errors'];
    if (errors is List && errors.isNotEmpty) {
      final first = errors.first;
      final msg = first is Map ? first['message']?.toString() : '$first';
      return ' error="${(msg ?? '').replaceAll('\n', ' ')}"';
    }
    return '';
  }

  /// Every track object anywhere in an answer, whatever the operation
  /// wraps them in: `{uri: spotify:track:…, name, artists, duration}`.
  List<_SpotifyTrackHit> _collectTracks(Object? root) {
    final out = <_SpotifyTrackHit>[];
    final seen = <String>{};
    void walk(Object? n, int depth) {
      if (depth > 14) return;
      if (n is Map) {
        final uri = n['uri'];
        if (uri is String &&
            uri.startsWith('spotify:track:') &&
            n['name'] is String) {
          final id = uri.substring('spotify:track:'.length);
          final hit = _hit(n);
          if (hit != null && seen.add(id)) out.add(hit);
        }
        for (final v in n.values) {
          walk(v, depth + 1);
        }
      } else if (n is List) {
        for (final v in n) {
          walk(v, depth + 1);
        }
      }
    }

    walk(root, 0);
    return out;
  }

  _SpotifyTrackHit? _hit(Object? data) {
    if (data is! Map) return null;
    final id = data['id']?.toString().isNotEmpty == true
        ? data['id'].toString()
        : (data['uri']?.toString() ?? '').replaceFirst('spotify:track:', '');
    if (id.isEmpty) return null;
    final artists = _at(data, ['artists', 'items']) ?? data['artists'];
    final names = <String>[
      if (artists is List)
        for (final a in artists)
          if (_text(_at(a, ['profile', 'name'])).isNotEmpty)
            _text(_at(a, ['profile', 'name']))
          else if (a is Map && a['name'] is String)
            a['name'] as String,
    ];
    if (names.isEmpty) {
      final first = _at(data, ['firstArtist', 'items']);
      final other = _at(data, ['otherArtists', 'items']);
      for (final l in [first, other]) {
        if (l is List) {
          for (final a in l) {
            final n = _text(_at(a, ['profile', 'name']));
            if (n.isNotEmpty) names.add(n);
          }
        }
      }
    }
    return _SpotifyTrackHit(
      id: id,
      name: data['name']?.toString() ?? '',
      artists: names.join(', '),
      durationMs:
          _int(_at(data, ['duration', 'totalMilliseconds'])) ??
          _int(_at(data, ['trackDuration', 'totalMilliseconds'])) ??
          _int(data['duration_ms']) ??
          0,
    );
  }

  /// Native `pickBestTrack`: the closest running time when it is known,
  /// otherwise the first title match, otherwise the first result.
  _SpotifyTrackHit? _pick(
    List<_SpotifyTrackHit> hits,
    String title,
    String artist,
    int durationMs,
  ) {
    if (hits.isEmpty) return null;
    if (durationMs > 0) {
      var best = hits.first;
      var bestD = 1 << 30;
      for (final h in hits) {
        final d = h.durationMs > 0
            ? (h.durationMs - durationMs).abs()
            : 1 << 30;
        if (d < bestD) {
          bestD = d;
          best = h;
        }
      }
      return best;
    }
    final want = normalizeCanvasMatch(title);
    for (final h in hits) {
      if (h.name.toLowerCase() == title.toLowerCase() ||
          normalizeCanvasMatch(h.name) == want) {
        return h;
      }
    }
    return hits.first;
  }

  static final _cleanTitle = RegExp(
    r'\s*[\(\[](?:feat\.?|ft\.?|official|video|audio|remastered|lyric|lyrics|hd|4k)[^\)\]]*[\)\]]',
    caseSensitive: false,
  );

  Future<String?> _canvasViaQuery(String trackUri, {bool retry = false}) async {
    final headers = await _authHeaders(appPlatform: true);
    if (headers == null) return null;
    final hash = await _hash(
      SpotifyWebPlayer.canvasOperation,
      _knownCanvasHash,
      force: retry,
    );
    try {
      final res = await _dio.post<String>(
        _v2,
        data: jsonEncode({
          'operationName': 'canvas',
          'variables': {'trackUri': trackUri},
          'extensions': {
            'persistedQuery': {'version': 1, 'sha256Hash': hash},
          },
        }),
        options: Options(
          responseType: ResponseType.plain,
          headers: {...headers, 'Content-Type': 'application/json'},
          validateStatus: (_) => true,
        ),
      );
      if ((res.statusCode ?? 0) ~/ 100 != 2) {
        DiagnosticsLog.info('spotify canvas-query http=${res.statusCode}');
        return null;
      }
      final body = jsonDecode(res.data ?? '{}');
      if (body is! Map) return null;
      final data = body['data'];
      if (data is! Map) {
        final errors = body['errors'];
        final stale =
            errors is List &&
            errors.any(
              (e) =>
                  e.toString().toLowerCase().contains('persistedquerynotfound'),
            );
        if (stale && !retry)
          return await _canvasViaQuery(trackUri, retry: true);
        return null;
      }
      final url = _text(_at(data, ['trackUnion', 'canvas', 'url']));
      if (url.startsWith('https://') &&
          RegExp(r'\.mp4(?:[?#]|$)', caseSensitive: false).hasMatch(url)) {
        return url;
      }
      return null;
    } catch (e) {
      DiagnosticsLog.info('spotify canvas-query error=${e.runtimeType}');
      return null;
    }
  }

  /// The older protobuf endpoint, kept as a fallback. The request is
  /// `{1: [{1: trackUri}]}`; the answer is scanned for the clip URL.
  Future<String?> _canvasViaProtobuf(String trackUri) async {
    final headers = await _authHeaders();
    if (headers == null) return null;
    final uri = utf8.encode(trackUri);
    final inner = <int>[0x0a, ..._varint(uri.length), ...uri];
    final body = Uint8List.fromList(<int>[
      0x0a,
      ..._varint(inner.length),
      ...inner,
    ]);
    try {
      final res = await _dio.post<List<int>>(
        _canvazEndpoint,
        data: body,
        options: Options(
          responseType: ResponseType.bytes,
          headers: {
            ...headers,
            'Accept': 'application/protobuf',
            'Content-Type': 'application/protobuf',
            'User-Agent': 'Spotify/9.0.34.593 iOS/18.4 (iPhone15,3)',
          },
          validateStatus: (_) => true,
        ),
      );
      if ((res.statusCode ?? 0) ~/ 100 != 2) {
        DiagnosticsLog.info('spotify canvas-protobuf http=${res.statusCode}');
        return null;
      }
      final text = latin1.decode(res.data ?? const []);
      return RegExp(r'''https://[^\x00-\x20"']+\.mp4[^\x00-\x20"']*''')
          .firstMatch(text)
          ?.group(0);
    } catch (_) {
      return null;
    }
  }

  static List<int> _varint(int value) {
    final out = <int>[];
    var v = value;
    while (v > 0x7f) {
      out.add((v & 0x7f) | 0x80);
      v >>= 7;
    }
    out.add(v);
    return out;
  }

  // -- tiny JSON helpers ---------------------------------------------------

  static Object? _at(Object? node, List<String> path) {
    var cur = node;
    for (final key in path) {
      if (cur is Map) {
        cur = cur[key];
      } else {
        return null;
      }
    }
    return cur;
  }

  static String _text(Object? v) => v is String ? v : '';
  static int? _int(Object? v) => v is num ? v.toInt() : null;
  static String _clean(String s) => s.replaceAll(' ', ' ').trim();

  static String _firstSource(Object? sources) {
    if (sources is List && sources.isNotEmpty) {
      final first = sources.first;
      if (first is Map && first['url'] is String) return first['url'] as String;
    }
    return '';
  }

  static String _firstImage(Object? images) {
    if (images is Map) {
      final first = _firstOf(images['items']);
      return first is Map ? _firstSource(first['sources']) : '';
    }
    if (images is List) return _firstSource(images);
    return '';
  }

  static Object? _firstOf(Object? list) =>
      list is List && list.isNotEmpty ? list.first : null;
}

class _SpotifyTrackHit {
  final String id;
  final String name;
  final String artists;
  final int durationMs;
  const _SpotifyTrackHit({
    required this.id,
    required this.name,
    required this.artists,
    required this.durationMs,
  });
}

final spotifyApiProvider = Provider<SpotifyApi>(
  (ref) => SpotifyApi(ref.watch(spotifyAuthProvider)),
);

/// Account playlists (Liked Songs first). Empty when not connected.
final spotifyPlaylistsProvider = FutureProvider<List<SpotifyPlaylistSummary>>((
  ref,
) async {
  final auth = ref.watch(spotifyAuthProvider);
  if (!auth.connected) return const [];
  final api = ref.watch(spotifyApiProvider);
  final lists = await api.userPlaylists();
  if (lists.isEmpty) return lists;
  return [
    const SpotifyPlaylistSummary(
      id: SpotifyPlaylistSummary.likedId,
      name: 'Liked Songs',
      description: 'Your Spotify likes',
      owner: 'Spotify',
    ),
    ...lists,
  ];
});

final spotifyPlaylistContentProvider =
    FutureProvider.family<SpotifyPlaylistContent?, String>((ref, id) async {
      if (!ref.watch(spotifyAuthProvider).connected) return null;
      return ref.watch(spotifyApiProvider).playlist(id);
    });

/// Whether Spotify canvases are used (Settings → Integrations).
final spotifyCanvasEnabledProvider = Provider<bool>(
  (ref) => ref.watch(prefsProvider).spotifyCanvasEnabled,
);
