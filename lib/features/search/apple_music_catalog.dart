import 'package:dio/dio.dart';

/// One Apple Music catalog recording. The API returns metadata only;
/// LastWave resolves playable audio through its configured playback sources.
class AppleMusicCatalogTrack {
  final String id;
  final String title;
  final String artist;
  final String album;
  final String artworkUrl;
  final String isrc;
  final String url;
  final int durationSeconds;

  const AppleMusicCatalogTrack({
    required this.id,
    required this.title,
    required this.artist,
    this.album = '',
    this.artworkUrl = '',
    this.isrc = '',
    this.url = '',
    this.durationSeconds = 0,
  });
}

class AppleMusicCatalogException implements Exception {
  final String message;
  const AppleMusicCatalogException(this.message);

  @override
  String toString() => message;
}

/// Apple Music catalog search using an app-owner supplied developer token.
/// The signing key is never stored in the app; only the short-lived JWT is.
class AppleMusicCatalogApi {
  final Dio _dio;
  final Future<String?> Function() _readDeveloperToken;

  AppleMusicCatalogApi({
    required this._dio,
    required this._readDeveloperToken,
  });

  Future<List<AppleMusicCatalogTrack>> searchSongs(
    String query, {
    String storefront = 'us',
    int limit = 50,
  }) async {
    final term = query.trim();
    if (term.isEmpty) return const [];

    final token = (await _readDeveloperToken())?.trim() ?? '';
    if (token.isEmpty) {
      throw const AppleMusicCatalogException(
        'Apple Music catalog search needs a developer token. Add one in Settings → Integrations.',
      );
    }

    try {
      final response = await _dio.get<Map<String, dynamic>>(
        'https://api.music.apple.com/v1/catalog/${storefront.toLowerCase()}/search',
        queryParameters: {
          'term': term,
          'types': 'songs',
          'limit': limit.clamp(1, 25),
        },
        options: Options(
          headers: {
            'Authorization': 'Bearer $token',
            'Accept': 'application/json',
          },
        ),
      );
      final root = response.data ?? const <String, dynamic>{};
      final results = _asMap(root['results']);
      final songs = _asMap(results?['songs']);
      final data = songs?['data'];
      if (data is! List) return const [];

      final output = <AppleMusicCatalogTrack>[];
      for (final item in data) {
        final resource = _asMap(item);
        if (resource == null) continue;
        final attributes = _asMap(resource['attributes']);
        if (attributes == null) continue;

        final title = _string(attributes['name']);
        final artist = _string(attributes['artistName']);
        if (title.isEmpty || artist.isEmpty) continue;

        final artwork = _asMap(attributes['artwork']);
        var artworkUrl = _string(artwork?['url']);
        if (artworkUrl.isNotEmpty) {
          artworkUrl = artworkUrl
              .replaceAll('{w}', '512')
              .replaceAll('{h}', '512');
        }
        final durationMs = attributes['durationInMillis'];
        final durationSeconds = durationMs is num
            ? (durationMs / 1000).round()
            : 0;

        output.add(AppleMusicCatalogTrack(
          id: _string(resource['id']),
          title: title,
          artist: artist,
          album: _string(attributes['albumName']),
          artworkUrl: artworkUrl,
          isrc: _string(attributes['isrc']),
          url: _string(attributes['url']),
          durationSeconds: durationSeconds,
        ));
      }
      return output;
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 401 || code == 403) {
        throw const AppleMusicCatalogException(
          'Apple Music rejected the developer token. Check that it is valid and not expired.',
        );
      }
      if (code == 404) {
        throw const AppleMusicCatalogException(
          'Apple Music catalog is not available for this storefront.',
        );
      }
      if (code == 429) {
        throw const AppleMusicCatalogException(
          'Apple Music search is temporarily rate-limited. Try again shortly.',
        );
      }
      throw const AppleMusicCatalogException(
        'Could not reach the Apple Music catalog. Check your connection and try again.',
      );
    }
  }

  static Map<String, dynamic>? _asMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }

  static String _string(Object? value) => value?.toString().trim() ?? '';
}
