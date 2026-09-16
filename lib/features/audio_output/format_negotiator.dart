import 'dac_device.dart';
import 'output_path_status.dart';
import 'pcm_format.dart';

/// Negotiates a DAC exclusive format from the source PCM.
///
/// Exact source match is required for a native/bit-perfect decision.
/// Fallbacks never pretend to be bit-perfect.
class FormatNegotiator {
  const FormatNegotiator();

  FormatDecision negotiate({
    required PcmFormat source,
    required DacDevice? device,
    required bool exclusiveRequested,
  }) {
    if (device == null) {
      return FormatDecision(
        source: source,
        output: exclusiveRequested ? null : source,
        nativeMatch: false,
        resampling: exclusiveRequested,
        formatConversion: exclusiveRequested,
        note: exclusiveRequested
            ? 'No output device selected'
            : 'Shared mode — Windows mixer may resample',
      );
    }

    if (!exclusiveRequested) {
      return FormatDecision(
        source: source,
        output: source,
        nativeMatch: false,
        resampling: true,
        formatConversion: true,
        note: 'WASAPI Shared — Windows mixer in path',
      );
    }

    if (!device.exclusiveSupported || device.formats.isEmpty) {
      return FormatDecision(
        source: source,
        output: null,
        nativeMatch: false,
        resampling: true,
        formatConversion: true,
        note: 'WASAPI Exclusive unavailable on ${device.name}',
      );
    }

    if (device.supports(source)) {
      return FormatDecision(
        source: source,
        output: source,
        nativeMatch: true,
        resampling: false,
        formatConversion: false,
        note: 'DAC supports ${source.label}',
      );
    }

    final sameRate = device.formats
        .where((f) =>
            f.sampleRateHz == source.sampleRateHz &&
            f.channels == source.channels)
        .toList()
      ..sort((a, b) => b.bitDepth.compareTo(a.bitDepth));
    if (sameRate.isNotEmpty) {
      final pick = _closestDepth(sameRate, source.bitDepth);
      return FormatDecision(
        source: source,
        output: pick,
        nativeMatch: false,
        resampling: false,
        formatConversion: pick.bitDepth != source.bitDepth,
        note: 'Native bit depth unavailable — using ${pick.label}',
      );
    }

    final sameDepth = device.formats
        .where((f) =>
            f.bitDepth == source.bitDepth && f.channels == source.channels)
        .toList()
      ..sort((a, b) => a.sampleRateHz.compareTo(b.sampleRateHz));
    if (sameDepth.isNotEmpty) {
      final pick = _closestRate(sameDepth, source.sampleRateHz);
      return FormatDecision(
        source: source,
        output: pick,
        nativeMatch: false,
        resampling: true,
        formatConversion: false,
        note: 'Native sample rate unavailable — using ${pick.label}',
      );
    }

    if (device.formats.isNotEmpty) {
      final pick = _closestOverall(device.formats, source);
      return FormatDecision(
        source: source,
        output: pick,
        nativeMatch: false,
        resampling: pick.sampleRateHz != source.sampleRateHz,
        formatConversion: pick.bitDepth != source.bitDepth,
        note: 'Native format unavailable — using ${pick.label}',
      );
    }

    return FormatDecision(
      source: source,
      output: null,
      nativeMatch: false,
      resampling: true,
      formatConversion: true,
      note: 'No compatible exclusive PCM format',
    );
  }

  BitPerfectReason evaluate({
    required FormatDecision decision,
    required bool exclusiveRequested,
    required bool exclusiveActive,
    required bool deviceAvailable,
    required bool dspActive,
    required bool peqActive,
    required bool softwareVolume,
    required bool crossfade,
    required double speed,
  }) {
    if (!deviceAvailable) return BitPerfectReason.deviceUnavailable;
    if (peqActive) return BitPerfectReason.peqActive;
    if (dspActive) return BitPerfectReason.dspActive;
    if (crossfade) return BitPerfectReason.crossfadeActive;
    if ((speed - 1.0).abs() > 0.001) return BitPerfectReason.speedNotUnity;
    if (!exclusiveRequested || !exclusiveActive) {
      return exclusiveRequested
          ? BitPerfectReason.exclusiveUnavailable
          : BitPerfectReason.sharedMode;
    }
    if (decision.output == null) return BitPerfectReason.formatUnsupported;
    if (decision.resampling) return BitPerfectReason.resampling;
    if (decision.formatConversion || !decision.nativeMatch) {
      return BitPerfectReason.formatConversion;
    }
    if (softwareVolume) return BitPerfectReason.softwareVolume;
    return BitPerfectReason.bitPerfect;
  }

  PcmFormat _closestDepth(List<PcmFormat> options, int depth) {
    PcmFormat best = options.first;
    var bestDelta = (best.bitDepth - depth).abs();
    for (final f in options) {
      final d = (f.bitDepth - depth).abs();
      if (d < bestDelta) {
        best = f;
        bestDelta = d;
      }
    }
    return best;
  }

  PcmFormat _closestRate(List<PcmFormat> options, int rate) {
    PcmFormat best = options.first;
    var bestDelta = (best.sampleRateHz - rate).abs();
    for (final f in options) {
      final d = (f.sampleRateHz - rate).abs();
      if (d < bestDelta) {
        best = f;
        bestDelta = d;
      }
    }
    return best;
  }

  PcmFormat _closestOverall(List<PcmFormat> options, PcmFormat source) {
    PcmFormat best = options.first;
    var bestScore = 1 << 30;
    for (final f in options) {
      final score = (f.sampleRateHz - source.sampleRateHz).abs() +
          (f.bitDepth - source.bitDepth).abs() * 4000;
      if (score < bestScore) {
        best = f;
        bestScore = score;
      }
    }
    return best;
  }
}
