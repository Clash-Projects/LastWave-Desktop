import '../../core/audio/stream_models.dart';

/// Lossless-tier source contract.
///
/// Implemented by [AddonApi] (user addon URLs — the only lossless
/// catalog since the baked-in backend was removed). Playback,
/// downloads, and detail pages program against this — never the
/// concrete client.
abstract class LosslessSource {
  /// False when the source cannot serve anything (no backend / no
  /// addon URLs / missing client secret). Callers fall through to
  /// YouTube without attempting requests.
  bool get isConfigured;

  /// Best stream for a track, or null (miss → caller falls through).
  /// Throws [AddonQuotaException] when the addon quota is exhausted
  /// (callers fall through AND surface the quota notice).
  Future<ResolvedStream?> resolveStream({
    required String title,
    required String artist,
    String album = '',
    int expectedDurationSeconds = 0,
    int preferredQuality = 27,
  });

  /// Drop one cached entry (reportPlaybackFailure path).
  void invalidateStream({
    required String title,
    required String artist,
  });

  /// Drop the whole in-memory stream cache (track-change path).
  void clearStreamCache();
}
