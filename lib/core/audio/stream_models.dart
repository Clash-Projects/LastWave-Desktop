/// Shared audio/track models.
///
/// Quality tier constants (YouTube / 320k / 16·44.1 / 24·96 / 24·192):
/// -1 = YouTube only, 5 = 320k MP3, 6 = CD 16/44.1 FLAC,
/// 7 = Hi-Res 24/96, 27 = Max Hi-Res 24/192.
class AudioQualityTiers {
  static const int youtubeOnly = -1;
  static const int mp3_320 = 5;
  static const int cdLossless = 6;
  static const int hiRes96 = 7;
  static const int maxHiRes = 27;

  static String label(int quality) {
    switch (quality) {
      case youtubeOnly:
        return 'Opus · YouTube';
      case mp3_320:
        return '320k MP3';
      case cdLossless:
        return 'Lossless · 16/44.1';
      case hiRes96:
        return 'Hi-Res · 24/96';
      case maxHiRes:
        return 'Hi-Res · 24/192';
      default:
        return 'Auto';
    }
  }

  static String shortBadge({
    required bool isLossless,
    required int bitDepth,
    required double samplingRateKhz,
    required String codec,
  }) {
    if (!isLossless) return codec.toUpperCase();
    if (bitDepth >= 24 && samplingRateKhz >= 88) return 'HI-RES';
    if (bitDepth >= 24) return 'HI-RES';
    return 'LOSSLESS';
  }
}

enum RepeatMode { off, all, one }

/// A playable queue item. Serialization keys mirror Android
/// `PlayableTrack` so persisted sessions stay conceptually compatible.
class PlayableTrack {
  final String title;
  final String artist;
  final String album;
  final String artworkUrl;
  final String videoId;
  final String playbackUrl;
  final String playbackMimeType;

  const PlayableTrack({
    required this.title,
    required this.artist,
    this.album = '',
    this.artworkUrl = '',
    this.videoId = '',
    this.playbackUrl = '',
    this.playbackMimeType = '',
  });

  String get mediaId {
    if (playbackUrl.isNotEmpty) return 'local:$playbackUrl';
    if (videoId.isNotEmpty) return videoId;
    return 'query:${artist.toLowerCase()}|${title.toLowerCase()}';
  }

  String get queueKey =>
      '${title.toLowerCase()}|${artist.toLowerCase()}';

  Map<String, dynamic> toJson() => {
        'title': title,
        'artist': artist,
        'album': album,
        'artworkUrl': artworkUrl,
        'videoId': videoId,
        'playbackUrl': playbackUrl,
        'playbackMimeType': playbackMimeType,
      };

  factory PlayableTrack.fromJson(Map<String, dynamic> json) =>
      PlayableTrack(
        title: json['title']?.toString() ?? '',
        artist: json['artist']?.toString() ?? '',
        album: json['album']?.toString() ?? '',
        artworkUrl: json['artworkUrl']?.toString() ?? '',
        videoId: json['videoId']?.toString() ?? '',
        playbackUrl: json['playbackUrl']?.toString() ?? '',
        playbackMimeType: json['playbackMimeType']?.toString() ?? '',
      );

  PlayableTrack copyWith({
    String? title,
    String? artist,
    String? album,
    String? artworkUrl,
    String? videoId,
    String? playbackUrl,
    String? playbackMimeType,
  }) =>
      PlayableTrack(
        title: title ?? this.title,
        artist: artist ?? this.artist,
        album: album ?? this.album,
        artworkUrl: artworkUrl ?? this.artworkUrl,
        videoId: videoId ?? this.videoId,
        playbackUrl: playbackUrl ?? this.playbackUrl,
        playbackMimeType: playbackMimeType ?? this.playbackMimeType,
      );
}

/// A resolved playable stream (lossless or YouTube).
class ResolvedStream {
  final String url;
  final String mimeType;
  final int bitrateKbps;
  final String audioCodec;
  final String cacheKey;
  final Map<String, String> requestHeaders;
  final bool isLossless;
  final int bitDepth;
  final double samplingRateKhz;
  final String artworkUrl;
  final String albumTitle;
  final DateTime? expiresAt;

  const ResolvedStream({
    required this.url,
    this.mimeType = 'audio/webm',
    this.bitrateKbps = 160,
    this.audioCodec = 'OPUS',
    this.cacheKey = '',
    this.requestHeaders = const {},
    this.isLossless = false,
    this.bitDepth = 16,
    this.samplingRateKhz = 44.1,
    this.artworkUrl = '',
    this.albumTitle = '',
    this.expiresAt,
  });

  bool get isExpired {
    final exp = expiresAt;
    if (exp == null) return false;
    return DateTime.now()
        .isAfter(exp.subtract(const Duration(minutes: 2)));
  }

  String get qualityBadge => AudioQualityTiers.shortBadge(
        isLossless: isLossless,
        bitDepth: bitDepth,
        samplingRateKhz: samplingRateKhz,
        codec: audioCodec,
      );
}

/// In-memory LRU of resolved stream URLs. Playback and the lossless
/// client share this so skip/previous reuse a fresh URL instead of
/// hitting Qobuz/Tidal/YouTube again. Entries drop two minutes before
/// the signed URL expires.
class ResolvedStreamCache {
  ResolvedStreamCache({this.maxEntries = 24});

  final int maxEntries;
  final Map<String, ResolvedStream> _entries = {};

  ResolvedStream? get(String key) {
    final stream = _entries[key];
    if (stream == null) return null;
    if (stream.isExpired) {
      _entries.remove(key);
      return null;
    }
    return stream;
  }

  void put(String key, ResolvedStream stream) {
    if (key.isEmpty || stream.url.isEmpty || stream.isExpired) return;
    _entries.remove(key);
    _entries[key] = stream;
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  void invalidate(String key) => _entries.remove(key);

  void invalidateWhere(bool Function(String key) test) {
    _entries.removeWhere((k, _) => test(k));
  }

  void clear() => _entries.clear();

  int get length => _entries.length;
}
