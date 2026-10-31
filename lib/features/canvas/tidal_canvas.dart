import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// Anonymous Tidal square looping video cover.
///
/// Same lookup as Android `TidalCanvas`: public search, no account.
/// A miss returns null so the next canvas source can run.
class TidalCanvas {
  TidalCanvas([Dio? dio]) : _dio = dio ?? Dio();

  final Dio _dio;

  static const _search = 'https://api.tidal.com/v1/search';
  static const _token = 'vNVdglQOjFJJGG2U';
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  Future<String?> search({
    required String title,
    required String artist,
    String album = '',
  }) async {
    if (title.trim().isEmpty && artist.trim().isEmpty) return null;
    final fromTrack = await _tracks(title, artist, album);
    if (fromTrack != null) return fromTrack;
    if (album.trim().isEmpty) return null;
    return _albums(album, artist);
  }

  Future<String?> _tracks(String title, String artist, String album) async {
    final query = album.trim().isEmpty
        ? '$artist $title'
        : '$album $artist $title';
    final root = await _get(query, 'TRACKS');
    final items = root?['tracks']?['items'];
    if (items is! List) return null;
    for (final item in items) {
      if (item is! Map) continue;
      final trackTitle = item['title']?.toString() ?? '';
      final artists = _names(item['artists']);
      if (!_match(trackTitle, artists, title, artist)) continue;
      final albumObj = item['album'];
      if (albumObj is! Map) continue;
      final cover = albumObj['videoCover']?.toString() ?? '';
      final url = coverUrl(cover);
      if (url != null) return url;
    }
    return null;
  }

  Future<String?> _albums(String album, String artist) async {
    final root = await _get('$album $artist', 'ALBUMS');
    final items = root?['albums']?['items'];
    if (items is! List) return null;
    for (final item in items) {
      if (item is! Map) continue;
      final recordTitle = item['title']?.toString() ?? '';
      final artists = _names(item['artists']);
      if (!_match(recordTitle, artists, album, artist)) continue;
      final url = coverUrl(item['videoCover']?.toString() ?? '');
      if (url != null) return url;
    }
    return null;
  }

  Future<Map<String, dynamic>?> _get(String query, String types) async {
    try {
      final country = _country();
      final res = await _dio.get<dynamic>(
        _search,
        queryParameters: {
          'query': query,
          'limit': 10,
          'types': types,
          'countryCode': country,
        },
        options: Options(headers: {
          'X-Tidal-Token': _token,
          'User-Agent': _ua,
        }),
      );
      final data = res.data;
      if (data is Map) {
        return data.map((k, v) => MapEntry(k.toString(), v));
      }
    } catch (_) {}
    return null;
  }

  String _country() {
    final raw = Platform.localeName.split(RegExp(r'[_-]'));
    if (raw.length >= 2 && raw[1].length == 2) {
      return raw[1].toUpperCase();
    }
    return 'US';
  }

  List<String> _names(Object? artists) {
    if (artists is! List) return const [];
    final out = <String>[];
    for (final artist in artists) {
      if (artist is! Map) continue;
      final name = artist['name']?.toString();
      if (name != null && name.isNotEmpty) out.add(name);
    }
    return out;
  }

  bool _match(
    String gotName,
    List<String> gotArtists,
    String wantName,
    String wantArtist,
  ) {
    if (_norm(gotName) != _norm(wantName)) return false;
    final wanted = _split(wantArtist);
    final credited = gotArtists.map(_norm).where((s) => s.isNotEmpty).toList();
    if (wanted.isEmpty || credited.isEmpty) return false;
    return wanted.every(
      (want) => credited.any(
        (got) => got == want || got.contains(want) || want.contains(got),
      ),
    );
  }

  List<String> _split(String raw) {
    return raw
        .split(RegExp(
          r'(?:\s*,\s*|\s*&\s*|\s+×\s+|\s+x\s+|\bfeat\.?\b|\bft\.?\b|\bfeaturing\b|\bwith\b)',
          caseSensitive: false,
        ))
        .map(_norm)
        .where((s) => s.isNotEmpty)
        .toList();
  }

  String _norm(String value) {
    final decomposed = unorm.nfd(value);
    return decomposed
        .replaceAll(RegExp(r'[\u0300-\u036f]'), '')
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// `uuid` → `https://resources.tidal.com/videos/a/b/c/d/e/1280x1280.mp4`.
  static String? coverUrl(String id) {
    final parts = id.split('-');
    if (parts.length != 5) return null;
    if (parts.any((p) => p.isEmpty)) return null;
    return 'https://resources.tidal.com/videos/${parts.join('/')}/1280x1280.mp4';
  }
}

final tidalCanvasProvider = Provider<TidalCanvas>((ref) => TidalCanvas());
