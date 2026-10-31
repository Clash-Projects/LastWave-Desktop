import 'dart:io';

import 'package:dio/dio.dart';

import 'animated_artwork_service.dart';

/// Tidal's video cover — square 1280x1280 looping clips.
///
/// Read through the public search endpoint Tidal's embeddable player uses
/// (no account needed). The track search resolves the album object, which
/// carries a `videoCover` UUID expandable into a fixed URL on Tidal's CDN.
class TidalCanvas {
  TidalCanvas._();

  static const String _searchUrl = 'https://api.tidal.com/v1/search';
  static const String _embedToken = 'vNVdglQOjFJJGG2U';

  static String get countryCode {
    try {
      final parts = Platform.localeName.split(RegExp(r'[-_.]'));
      if (parts.length >= 2) {
        final country = parts[1].trim().toUpperCase();
        if (country.length == 2 && RegExp(r'^[A-Z]{2}$').hasMatch(country)) {
          return country;
        }
      }
    } catch (_) {}
    return 'US';
  }

  static Future<AnimatedArtwork?> search(
    Dio dio, {
    required String title,
    required String artist,
    String? album,
  }) async {
    final query = (album == null || album.trim().isEmpty)
        ? '$artist $title'
        : '$album $artist $title';

    final root = await canvasGetJson(
      dio,
      _searchUrl,
      queryParameters: {
        'query': query,
        'limit': '10',
        'types': 'TRACKS',
        'countryCode': countryCode,
      },
      headers: const {
        'X-Tidal-Token': _embedToken,
        'User-Agent': canvasUserAgent,
      },
    );
    if (root == null) return null;

    final tracks = root['tracks'];
    final items = tracks is Map ? tracks['items'] : null;
    if (items is! List) return null;

    for (final item in items) {
      if (item is! Map) continue;
      final trackTitle = item['title']?.toString();
      if (trackTitle == null || trackTitle.isEmpty) continue;

      final rawArtists = item['artists'];
      final artists = rawArtists is List
          ? rawArtists
              .whereType<Map>()
              .map((a) => a['name']?.toString() ?? '')
              .where((s) => s.isNotEmpty)
              .toList()
          : const <String>[];

      if (!_isMatch(trackTitle, artists, title, artist)) continue;

      final albumObj = item['album'];
      final videoCover =
          albumObj is Map ? albumObj['videoCover']?.toString() : null;
      if (videoCover == null || videoCover.trim().isEmpty) continue;
      final videoUrl = coverUrl(videoCover.trim());
      if (videoUrl == null) continue;

      final joinedArtists = artists.join(', ');
      return AnimatedArtwork(
        url: videoUrl,
        title: trackTitle,
        artist: joinedArtists.isEmpty ? null : joinedArtists,
        album: albumObj is Map ? albumObj['title']?.toString() : null,
        source: CanvasSource.tidal,
      );
    }
    return null;
  }

  static Future<AnimatedArtwork?> searchAlbum(
    Dio dio, {
    required String album,
    required String artist,
  }) async {
    final root = await canvasGetJson(
      dio,
      _searchUrl,
      queryParameters: {
        'query': '$album $artist',
        'limit': '10',
        'types': 'ALBUMS',
        'countryCode': countryCode,
      },
      headers: const {
        'X-Tidal-Token': _embedToken,
        'User-Agent': canvasUserAgent,
      },
    );
    if (root == null) return null;

    final albums = root['albums'];
    final items = albums is Map ? albums['items'] : null;
    if (items is! List) return null;

    for (final item in items) {
      if (item is! Map) continue;
      final recordTitle = item['title']?.toString();
      if (recordTitle == null || recordTitle.isEmpty) continue;

      final rawArtists = item['artists'];
      final artists = rawArtists is List
          ? rawArtists
              .whereType<Map>()
              .map((a) => a['name']?.toString() ?? '')
              .where((s) => s.isNotEmpty)
              .toList()
          : const <String>[];

      if (!_isMatch(recordTitle, artists, album, artist)) continue;

      final videoCover = item['videoCover']?.toString();
      if (videoCover == null || videoCover.trim().isEmpty) continue;
      final videoUrl = coverUrl(videoCover.trim());
      if (videoUrl == null) continue;

      final joinedArtists = artists.join(', ');
      return AnimatedArtwork(
        url: videoUrl,
        title: null,
        artist: joinedArtists.isEmpty ? null : joinedArtists,
        album: recordTitle,
        source: CanvasSource.tidal,
      );
    }
    return null;
  }

  static bool _isMatch(
    String gotName,
    List<String> gotArtists,
    String wantName,
    String wantArtist,
  ) {
    if (!canvasTitlesMatch(wantName, gotName)) return false;
    final joinedCredited = gotArtists.where((s) => s.isNotEmpty).join(', ');
    if (joinedCredited.isEmpty) return false;
    return canvasArtistsMatch(
      wantArtist,
      joinedCredited,
      wantTitle: wantName,
      gotTitle: gotName,
    );
  }

  static String? coverUrl(String id) {
    final parts = id.split('-');
    if (parts.length != 5 || parts.any((p) => p.isEmpty)) return null;
    return 'https://resources.tidal.com/videos/${parts.join('/')}/1280x1280.mp4';
  }
}
