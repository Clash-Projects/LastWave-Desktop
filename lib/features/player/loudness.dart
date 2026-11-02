import 'dart:math' as math;

/// ReplayGain-style loudness correction aimed at about -14 LUFS.
///
/// Tag math follows LastWave-Native [LoudnessNormalizer]: stored
/// ReplayGain already targets the -18 LUFS reference, so a +4 dB preamp
/// lands near -14 LUFS. This file does not measure loudness. When a
/// stream or file exposes no gain tag, playback uses [fallbackDb].
class LoudnessMath {
  LoudnessMath._();

  static const double targetLufs = -14;
  static const double replayGainReferenceLufs = -18;

  /// Added on top of a real ReplayGain tag. Not applied to [fallbackDb]
  /// (mpv's replaygain-fallback replaces the preamp).
  static const double preampDb = targetLufs - replayGainReferenceLufs;

  /// Conservative attenuation when no ReplayGain metadata is exposed.
  /// A boost would push already-loud streams past full scale.
  static const double fallbackDb = -3;

  static const double clampDb = 15;

  /// Two album-gain readings count as the same tag when they are this
  /// close. Farther apart, album mode does not force one queue gain.
  static const double sharedAlbumToleranceDb = 0.25;

  static const modes = ['off', 'track', 'album'];

  static String normalizeMode(String? raw) {
    final id = (raw ?? '').trim().toLowerCase();
    return modes.contains(id) ? id : 'off';
  }

  /// Parsed ReplayGain in dB, or null when the string is missing or
  /// implausible. Accepts "-7.5 dB" and "3.0".
  static double? parseDb(String? value) {
    if (value == null) return null;
    var text = value.trim().toLowerCase();
    if (text.isEmpty || text == 'null' || text == 'none') return null;
    if (text.endsWith('db')) {
      text = text.substring(0, text.length - 2).trim();
    }
    final parsed = double.tryParse(text);
    if (parsed == null || !parsed.isFinite) return null;
    if (parsed < -51 || parsed > 51) return null;
    return parsed;
  }

  /// Track or album tag to feed ReplayGain, before preamp. Null when
  /// this mode has nothing to apply (off, or no gain tag). Album prefers
  /// the album tag and falls back to the track tag.
  static double? tagGainDb({
    required String mode,
    double? trackGainDb,
    double? albumGainDb,
  }) {
    if (normalizeMode(mode) == 'off') return null;
    final selected = normalizeMode(mode) == 'album'
        ? (albumGainDb ?? trackGainDb)
        : (trackGainDb ?? albumGainDb);
    if (selected == null || !selected.isFinite) return null;
    return selected;
  }

  static bool sameAlbumGain(double? a, double? b) {
    if (a == null || b == null) return false;
    if (!a.isFinite || !b.isFinite) return false;
    return (a - b).abs() <= sharedAlbumToleranceDb;
  }

  /// Tag gain plus the -14 LUFS preamp, clamped, then lowered so a
  /// known peak stays at or under 0 dBFS. Null tag means "use fallback",
  /// which is the caller's job — this returns null rather than inventing
  /// a measurement.
  static double? correctionDb({
    required String mode,
    double? trackGainDb,
    double? albumGainDb,
    double? peakLinear,
  }) {
    final selected = tagGainDb(
      mode: mode,
      trackGainDb: trackGainDb,
      albumGainDb: albumGainDb,
    );
    if (selected == null) return null;
    var gain = (selected + preampDb).clamp(-clampDb, clampDb).toDouble();
    final peak = peakLinear;
    if (peak != null && peak.isFinite && peak > 0) {
      final ceiling = 20 * math.log(1 / peak) / math.ln10;
      if (ceiling.isFinite && gain > ceiling) gain = ceiling;
    }
    return gain;
  }

  static String settingsSubtitle(String mode) {
    final fallback = fallbackDb.toStringAsFixed(0);
    switch (normalizeMode(mode)) {
      case 'track':
        return 'Targets about -14 LUFS when the file exposes ReplayGain '
            '(+${preampDb.toStringAsFixed(0)} dB on the -18 LUFS reference). '
            'No gain tag: fixed $fallback dB, not a loudness scan.';
      case 'album':
        return 'Uses one album ReplayGain for the current album when those '
            'tags agree; otherwise the track gain. No gain tag: fixed '
            '$fallback dB, not a loudness scan.';
      default:
        return 'Leaves the decoded level alone.';
    }
  }
}
