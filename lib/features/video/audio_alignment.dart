import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

/// Audio-to-video alignment, ported from LastWave-Native `AudioAlignment`.
///
/// Music videos are often a different edit than the audio track (intro
/// skit, cut verses), so equal timestamps can still look out of sync. The
/// song's audio is compared with the video's own audio to find the real
/// offset. No correction is better than a wrong one, so every estimate
/// returns null unless one match clearly stands out.

/// Spacing of envelope samples; also the resolution of a measured offset.
const int alignmentHopMs = 50;

const int _minOverlapMs = 20000;
const double _minCorrelation = 0.45;

/// Music repeats, so the best match must clearly beat the best elsewhere.
const double _minPeakMargin = 1.15;
const double _relaxedMinCorrelation = 0.30;
const double _relaxedMinPeakMargin = 1.06;
const int _peakExclusionMs = 1000;
const int _maxHalfDisagreementMs = 150;

/// Per-hop RMS loudness of signed 16-bit little-endian mono PCM.
Float32List rmsFromPcm16(Uint8List bytes, int sampleRate) {
  final samples = bytes.lengthInBytes ~/ 2;
  final data = ByteData.sublistView(bytes);
  final perHop = math.max(1, sampleRate * alignmentHopMs ~/ 1000);
  final hops = samples ~/ perHop;
  final out = Float32List(hops);
  for (var h = 0; h < hops; h++) {
    var energy = 0.0;
    final base = h * perHop;
    for (var i = 0; i < perHop; i++) {
      final s = data.getInt16((base + i) * 2, Endian.little) / 32768.0;
      energy += s * s;
    }
    out[h] = math.sqrt(energy / perHop);
  }
  return out;
}

/// Turns per-hop loudness into onsets: how sharply the sound got louder.
/// Onsets survive different masters and bitrates better than loudness.
Float32List onsetEnvelope(Float32List rms) {
  final logEnergy = Float32List(rms.length);
  for (var i = 0; i < rms.length; i++) {
    logEnergy[i] = math.log(1 + rms[i] * 1000);
  }
  final out = Float32List(rms.length);
  for (var i = 1; i < rms.length; i++) {
    out[i] = math.max(0, logEnergy[i] - logEnergy[i - 1]);
  }
  return out;
}

/// Where [song] lines up inside [video]: what to add to a song position to
/// get the matching video position (positive when the video has an intro).
int? estimateVideoOffsetMs(
  Float32List song,
  Float32List video, {
  double minCorrelation = _minCorrelation,
  double minMargin = _minPeakMargin,
}) {
  const minOverlap = _minOverlapMs ~/ alignmentHopMs;
  if (song.length < minOverlap || video.length < minOverlap) return null;

  final minLag = -(song.length - minOverlap);
  final maxLag = video.length - minOverlap;
  final correlations = Float32List(maxLag - minLag + 1);
  for (var i = 0; i < correlations.length; i++) {
    correlations[i] = _correlationAtLag(song, video, minLag + i);
  }
  var bestIndex = 0;
  for (var i = 1; i < correlations.length; i++) {
    if (correlations[i] > correlations[bestIndex]) bestIndex = i;
  }
  final best = correlations[bestIndex];
  if (best < minCorrelation) return null;

  const exclusion = _peakExclusionMs ~/ alignmentHopMs;
  var runnerUp = 0.0;
  for (var i = 0; i < correlations.length; i++) {
    if ((i - bestIndex).abs() <= exclusion) continue;
    if (correlations[i] > runnerUp) runnerUp = correlations[i];
  }
  if (runnerUp > 0 && best / runnerUp < minMargin) return null;

  return (minLag + bestIndex) * alignmentHopMs;
}

int? _confirmedOffset(
  Float32List song,
  Float32List video, {
  required double minCorrelation,
  required double minMargin,
  required bool bothHalves,
}) {
  final whole = estimateVideoOffsetMs(
    song,
    video,
    minCorrelation: minCorrelation,
    minMargin: minMargin,
  );
  if (whole == null) return null;
  final middle = song.length ~/ 2;
  final first = estimateVideoOffsetMs(
    Float32List.sublistView(song, 0, middle),
    video,
    minCorrelation: minCorrelation,
    minMargin: minMargin,
  );
  final secondRaw = estimateVideoOffsetMs(
    Float32List.sublistView(song, middle),
    video,
    minCorrelation: minCorrelation,
    minMargin: minMargin,
  );
  final second = secondRaw == null ? null : secondRaw - middle * alignmentHopMs;
  if (bothHalves && (first == null || second == null)) return null;
  final halves = [?first, ?second];
  final confirmed =
      halves.isNotEmpty &&
      halves.every((h) => (h - whole).abs() <= _maxHalfDisagreementMs);
  return confirmed ? whole : null;
}

/// The offset and whether it needed the relaxed thresholds, or null.
///
/// A clean match is accepted when one half of the song independently lands
/// on it and neither half points elsewhere (a chance match on repeating
/// music rarely confirms itself, and a re-edit gets contradicted). When the
/// video is a different master or mix the correlation is weaker, so a
/// second, looser pass accepts it only if BOTH halves find the same spot.
({int offsetMs, bool relaxed})? estimateAlignment(
  Float32List song,
  Float32List video,
) {
  final strict = _confirmedOffset(
    song,
    video,
    minCorrelation: _minCorrelation,
    minMargin: _minPeakMargin,
    bothHalves: false,
  );
  if (strict != null) return (offsetMs: strict, relaxed: false);
  final loose = _confirmedOffset(
    song,
    video,
    minCorrelation: _relaxedMinCorrelation,
    minMargin: _relaxedMinPeakMargin,
    bothHalves: true,
  );
  return loose == null ? null : (offsetMs: loose, relaxed: true);
}

int? estimateConsistentVideoOffsetMs(Float32List song, Float32List video) =>
    estimateAlignment(song, video)?.offsetMs;

/// Isolate entry: raw PCM of both sides in, offset (or null) out.
({int offsetMs, bool relaxed})? alignPcm16(
  ({Uint8List song, Uint8List video, int sampleRate}) input,
) {
  final song = onsetEnvelope(rmsFromPcm16(input.song, input.sampleRate));
  final video = onsetEnvelope(rmsFromPcm16(input.video, input.sampleRate));
  return estimateAlignment(song, video);
}

/// Pearson correlation of the overlap when song[i] meets video[i + lag].
double _correlationAtLag(Float32List song, Float32List video, int lag) {
  final start = math.max(0, -lag);
  final end = math.min(song.length, video.length - lag);
  final count = end - start;
  if (count <= 0) return 0;

  var sumSong = 0.0;
  var sumVideo = 0.0;
  for (var i = start; i < end; i++) {
    sumSong += song[i];
    sumVideo += video[i + lag];
  }
  final meanSong = sumSong / count;
  final meanVideo = sumVideo / count;

  var covariance = 0.0;
  var varianceSong = 0.0;
  var varianceVideo = 0.0;
  for (var i = start; i < end; i++) {
    final a = song[i] - meanSong;
    final b = video[i + lag] - meanVideo;
    covariance += a * b;
    varianceSong += a * a;
    varianceVideo += b * b;
  }
  final denominator = math.sqrt(varianceSong * varianceVideo);
  return denominator > 0 ? covariance / denominator : 0;
}

/// Runs [alignPcm16] off the UI thread. A top-level function on purpose: a
/// closure built inside an object would drag that object (HTTP clients and
/// all) into the isolate message and fail to send. Falls back to running in
/// place if an isolate cannot be started.
Future<({int offsetMs, bool relaxed})?> alignPcm16Async(
  Uint8List song,
  Uint8List video,
  int sampleRate,
) async {
  try {
    return await Isolate.run(
      () => alignPcm16((song: song, video: video, sampleRate: sampleRate)),
    );
  } catch (_) {
    return alignPcm16((song: song, video: video, sampleRate: sampleRate));
  }
}
