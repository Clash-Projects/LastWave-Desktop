import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'spotify_session.dart';
import 'spotify_web_player.dart';

/// Spotify canvas MP4 for the track that is playing.
///
/// Failure returns null so Now Playing keeps the current artwork.
class SpotifyCanvas {
  SpotifyCanvas(this._session);

  final SpotifySession _session;
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
      headers: {
        'User-Agent': _ua,
        'Accept': 'application/json',
      },
    ),
  );

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
  static const _canvasUa = 'Spotify/9.0.34.593 iOS/18.4 (iPhone15,3)';
  static const _pathfinder =
      'https://api-partner.spotify.com/pathfinder/v1/query';
  static const _canvasQuery =
      'https://api-partner.spotify.com/pathfinder/v2/query';
  static const _canvasEndpoint =
      'https://spclient.wg.spotify.com/canvaz-cache/v0/canvases';
  static const _knownCanvasHash =
      '575138ab27cd5c1b3e54da54d0a7cc8d85485402de26340c2145f0f6bb5e7a9f';
  static const _searchHash =
      'bc1ca2fcd0ba1013a0fc88e6cc4f190af501851e3dafd3e1ef85840297694428';

  Future<String?> search({
    required String title,
    required String artist,
    String album = '',
    int durationMs = 0,
  }) async {
    if (title.trim().isEmpty && artist.trim().isEmpty) return null;
    if (!await _session.hasSession()) return null;
    try {
      final personal = await _session.personalToken();
      final client = await _session.clientToken();
      if (personal == null || personal.isEmpty) return null;
      if (client == null || client.isEmpty) return null;
      final trackId = await _searchTrack(
            personal,
            client,
            title,
            artist,
            durationMs,
          ) ??
          await _searchFallback(personal, title, artist, durationMs);
      if (trackId == null || trackId.isEmpty) return null;
      return await _canvasUrl(personal, client, trackId);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _searchTrack(
    String personal,
    String client,
    String title,
    String artist,
    int durationMs,
  ) async {
    final clean = title
        .replaceAll(
          RegExp(
            r'\s*[(\[](?:feat\.?|ft\.?|official|video|audio|remastered|lyric|lyrics|hd|4k)[^)\]]*[)\]]',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
    final primary = artist.split(RegExp(r'[,;&]')).first.trim();
    final queries = <String>{
      '$clean $primary'.trim(),
      '$title $artist'.trim(),
    }.where((q) => q.isNotEmpty);
    for (final query in queries) {
      final variables = jsonEncode({
        'searchTerm': query,
        'offset': 0,
        'limit': 5,
        'numberOfTopResults': 5,
        'includeAudiobooks': false,
        'includePreReleases': false,
      });
      final extensions = jsonEncode({
        'persistedQuery': {'version': 1, 'sha256Hash': _searchHash},
      });
      final url = '$_pathfinder?operationName=searchTracks'
          '&variables=${Uri.encodeQueryComponent(variables)}'
          '&extensions=${Uri.encodeQueryComponent(extensions)}';
      final items = await _pathfinderTracks(url, personal, client);
      final id = _pickId(items, title, durationMs);
      if (id != null) return id;
    }
    return null;
  }

  Future<List<({String id, String name, int duration})>> _pathfinderTracks(
    String url,
    String personal,
    String client,
  ) async {
    try {
      final res = await _dio.get<dynamic>(
        url,
        options: Options(headers: {
          'Authorization': 'Bearer $personal',
          'Client-Token': client,
          'User-Agent': _ua,
          'Accept': 'application/json',
        }),
      );
      final data = res.data;
      if (data is! Map) return const [];
      final items = data['data']?['searchV2']?['tracksV2']?['items'];
      if (items is! List) return const [];
      final out = <({String id, String name, int duration})>[];
      for (final item in items) {
        if (item is! Map) continue;
        final track = item['item']?['data'];
        if (track is! Map) continue;
        final uri = track['uri']?.toString() ?? '';
        final id = track['id']?.toString() ??
            (uri.startsWith('spotify:track:')
                ? uri.substring('spotify:track:'.length)
                : '');
        if (id.isEmpty) continue;
        final duration = track['duration']?['totalMilliseconds'];
        out.add((
          id: id,
          name: track['name']?.toString() ?? '',
          duration: duration is num ? duration.toInt() : 0,
        ));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  Future<String?> _searchFallback(
    String personal,
    String title,
    String artist,
    int durationMs,
  ) async {
    try {
      final res = await _dio.get<dynamic>(
        'https://api.spotify.com/v1/search',
        queryParameters: {
          'type': 'track',
          'q': '$title $artist',
          'limit': 5,
        },
        options: Options(headers: {
          'Authorization': 'Bearer $personal',
          'User-Agent': _ua,
          'Accept': 'application/json',
        }),
      );
      final data = res.data;
      if (data is! Map) return null;
      final tracks = data['tracks'];
      if (tracks is! Map) return null;
      final items = tracks['items'];
      if (items is! List || items.isEmpty) return null;
      final parsed = <({String id, String name, int duration})>[];
      for (final item in items) {
        if (item is! Map) continue;
        final id = item['id']?.toString() ?? '';
        if (id.isEmpty) continue;
        final duration = item['duration_ms'];
        parsed.add((
          id: id,
          name: item['name']?.toString() ?? '',
          duration: duration is num ? duration.toInt() : 0,
        ));
      }
      return _pickId(parsed, title, durationMs);
    } catch (_) {
      return null;
    }
  }

  String? _pickId(
    List<({String id, String name, int duration})> items,
    String title,
    int durationMs,
  ) {
    if (items.isEmpty) return null;
    if (durationMs > 0) {
      var best = items.first;
      var bestDelta = 1 << 62;
      for (final item in items) {
        final delta = item.duration > 0
            ? (item.duration - durationMs).abs()
            : 1 << 62;
        if (delta < bestDelta) {
          bestDelta = delta;
          best = item;
        }
      }
      return best.id;
    }
    final want = title.toLowerCase();
    for (final item in items) {
      if (item.name.toLowerCase() == want) return item.id;
    }
    return items.first.id;
  }

  Future<String?> _canvasUrl(
    String personal,
    String client,
    String trackId,
  ) async {
    final uri = 'spotify:track:$trackId';
    final proto = await _protobuf(personal, client, uri);
    if (proto != null) return proto;
    return _query(personal, client, uri);
  }

  Future<String?> _protobuf(
    String personal,
    String client,
    String trackUri,
  ) async {
    try {
      final body = _canvasRequest(trackUri);
      final res = await _dio.post<List<int>>(
        _canvasEndpoint,
        data: body,
        options: Options(
          responseType: ResponseType.bytes,
          headers: {
            'Authorization': 'Bearer $personal',
            'Client-Token': client,
            'Accept': 'application/protobuf',
            'Content-Type': 'application/protobuf',
            'User-Agent': _canvasUa,
          },
        ),
      );
      final bytes = res.data;
      if (bytes == null || bytes.isEmpty) return null;
      final text = latin1.decode(bytes, allowInvalid: true);
      final match = RegExp(
        r'''https://[^\x00-\x20"']+\.mp4[^\x00-\x20"']*''',
      ).firstMatch(text);
      return match?.group(0);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _query(
    String personal,
    String client,
    String trackUri, {
    bool retry = false,
  }) async {
    final live = await SpotifyWebPlayer.queryHash(
      _dio,
      SpotifyWebPlayer.canvasOperation,
      force: retry,
    );
    final hash = live ?? _knownCanvasHash;
    try {
      final res = await _dio.post<dynamic>(
        _canvasQuery,
        data: {
          'operationName': 'canvas',
          'variables': {'trackUri': trackUri},
          'extensions': {
            'persistedQuery': {'version': 1, 'sha256Hash': hash},
          },
        },
        options: Options(headers: {
          'Authorization': 'Bearer $personal',
          'Client-Token': client,
          'App-platform': 'WebPlayer',
          'Accept': 'application/json',
          'Content-Type': 'application/json',
          'User-Agent': _ua,
        }),
      );
      final root = res.data;
      if (root is! Map) return null;
      final errors = root['errors'];
      final data = root['data'];
      if (data is! Map) {
        final stale = errors is List &&
            errors.any((e) =>
                e is Map &&
                (e['message']?.toString() ?? '')
                    .toLowerCase()
                    .contains('persistedquerynotfound'));
        if (stale && !retry) {
          return await _query(personal, client, trackUri, retry: true);
        }
        return null;
      }
      final canvas = data['trackUnion']?['canvas'];
      if (canvas is! Map) return null;
      final url = canvas['url']?.toString() ?? '';
      if (!url.startsWith('https://')) return null;
      if (!RegExp(r'\.mp4(?:[?#]|$)', caseSensitive: false).hasMatch(url)) {
        return null;
      }
      return url;
    } catch (_) {
      return null;
    }
  }

  /// Protobuf `CanvasRequest { tracks: [ { track_uri } ] }`.
  List<int> _canvasRequest(String trackUri) {
    final uri = utf8.encode(trackUri);
    final inner = <int>[0x0a, ..._varint(uri.length), ...uri];
    return <int>[0x0a, ..._varint(inner.length), ...inner];
  }

  List<int> _varint(int value) {
    final out = <int>[];
    var rest = value;
    while (rest > 0x7f) {
      out.add((rest & 0x7f) | 0x80);
      rest >>= 7;
    }
    out.add(rest);
    return out;
  }
}

final spotifyCanvasProvider = Provider<SpotifyCanvas>((ref) {
  return SpotifyCanvas(ref.watch(spotifySessionProvider));
});
