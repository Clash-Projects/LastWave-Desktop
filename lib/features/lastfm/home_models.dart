/// Track/artist/album/user models for scrobbler data (Last.fm, ListenBrainz, Libre.fm).
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

/// Shared Last.fm 2.0 / GNU FM JSON payload parser used by both
/// `HomeRepository` (Last.fm) and `LibreFmScrobbler` (Libre.fm).
abstract final class LastFmResponseParser {
  static Map<String, dynamic> asMap(Object? v) =>
      v is Map<String, dynamic>
          ? v
          : (v is Map ? Map<String, dynamic>.from(v) : const {});

  static List<Map<String, dynamic>> asList(Object? v) {
    if (v is List) {
      return v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    }
    if (v is Map) return [Map<String, dynamic>.from(v)];
    return const [];
  }

  static String bestImage(Object? images) {
    var fallback = '';
    for (final img in asList(images)) {
      final url = img['#text']?.toString() ?? '';
      if (url.isEmpty ||
          url.contains('2a96cbd8') ||
          url.contains('default_album') ||
          url.contains('noimage')) {
        continue;
      }
      fallback = url;
      final size = img['size']?.toString() ?? '';
      if (size == 'extralarge' || size == 'large') return url;
    }
    return fallback;
  }

  static List<HomeTrack> parseRecentTracks(Map<String, dynamic> json) {
    final tracks = asList(asMap(json['recenttracks'])['track']);
    final out = <HomeTrack>[];
    for (final t in tracks) {
      final attr = asMap(t['@attr']);
      if (attr['nowplaying'] == 'true') continue;
      final artist = t['artist'] is Map
          ? (t['artist'] as Map)['#text']?.toString() ??
              (t['artist'] as Map)['name']?.toString() ??
              ''
          : t['artist']?.toString() ?? '';
      final date = asMap(t['date'])['uts']?.toString() ?? '';
      final tsSec = int.tryParse(date);
      out.add(HomeTrack(
        name: t['name']?.toString() ?? '',
        artist: artist,
        artworkUrl: bestImage(t['image']),
        timestampMillis: tsSec != null ? tsSec * 1000 : null,
      ));
    }
    return out.where((t) => t.name.isNotEmpty).toList();
  }

  static int parseTotalAttr(Map<String, dynamic> root, String key) {
    final attr = asMap(asMap(root[key])['@attr']);
    return int.tryParse(attr['total']?.toString() ?? '') ?? 0;
  }

  static HomeStats parseStats({
    required Map<String, dynamic> userInfoJson,
    Map<String, dynamic> topTracksJson = const {},
    Map<String, dynamic> topArtistsJson = const {},
    Map<String, dynamic> topAlbumsJson = const {},
  }) {
    final info = asMap(userInfoJson['user']);
    return HomeStats(
      scrobbles: int.tryParse(info['playcount']?.toString() ?? '') ?? 0,
      trackCount: parseTotalAttr(topTracksJson, 'toptracks'),
      artistCount: parseTotalAttr(topArtistsJson, 'topartists'),
      albumCount: parseTotalAttr(topAlbumsJson, 'topalbums'),
      avatarUrl: bestImage(info['image']),
    );
  }

  static int parsePeriodPlayCount(Map<String, dynamic> json) =>
      parseTotalAttr(json, 'recenttracks');

  static List<HomeTrack> parseTopTracks(Map<String, dynamic> json) {
    return asList(asMap(json['toptracks'])['track'])
        .map((t) => HomeTrack(
              name: t['name']?.toString() ?? '',
              artist: asMap(t['artist'])['name']?.toString() ??
                  t['artist']?.toString() ??
                  '',
              artworkUrl: bestImage(t['image']),
              playCount:
                  int.tryParse(t['playcount']?.toString() ?? '') ?? 0,
            ))
        .where((t) => t.name.isNotEmpty)
        .toList();
  }

  static List<({String name, int playCount, String artworkUrl})>
      parseTopArtists(Map<String, dynamic> json) {
    return asList(asMap(json['topartists'])['artist'])
        .map((a) => (
              name: a['name']?.toString() ?? '',
              playCount: int.tryParse(a['playcount']?.toString() ?? '') ?? 0,
              artworkUrl: bestImage(a['image']),
            ))
        .where((a) => a.name.isNotEmpty)
        .toList();
  }

  static List<({String name, String artist, int playCount, String artworkUrl})>
      parseTopAlbums(Map<String, dynamic> json) {
    return asList(asMap(json['topalbums'])['album'])
        .map((a) {
          final artist = asMap(a['artist'])['name']?.toString() ??
              a['artist']?.toString() ??
              '';
          return (
            name: a['name']?.toString() ?? '',
            artist: artist,
            playCount: int.tryParse(a['playcount']?.toString() ?? '') ?? 0,
            artworkUrl: bestImage(a['image']),
          );
        })
        .where((a) => a.name.isNotEmpty)
        .toList();
  }
}
