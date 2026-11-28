import 'dart:math' as math;
import 'dart:typed_data';

/// Which ear receives the calibration cue.
enum EarChannel {
  both,
  left,
  right,
}

/// Parsed metadata from a 16-bit PCM RIFF/WAVE header.
class WavHeaderInfo {
  final int sampleRateHz;
  final int channels;
  final int bitsPerSample;
  final int dataBytes;

  const WavHeaderInfo({
    required this.sampleRateHz,
    required this.channels,
    required this.bitsPerSample,
    required this.dataBytes,
  });
}

/// Pure-Dart calibrated warble-tone PCM16 stereo WAV synthesizer.
///
/// Generates safety-capped pulsed warble tones (gentle +/-2% FM modulation
/// at 4.5 Hz with 30 ms raised-cosine ramps and a quiet tail gap) so:
/// - looping in `PlaylistMode.single` produces zero click artifacts,
/// - standing-wave nulls inside ear canals are smoothed out,
/// - peak amplitude never exceeds -18 dBFS (safe listening headroom).
class EarToneGenerator {
  EarToneGenerator._();

  static const int defaultSampleRateHz = 48000;
  static const int defaultDurationMs = 1800;

  /// -18 dBFS linear amplitude ceiling (~0.12589 of full scale).
  static const double referencePeakAmplitude = 0.12589254117941673;

  static const double minAttenuationDb = -42.0;
  static const double maxAttenuationDb = 0.0;

  /// Synthesizes a 16-bit stereo PCM WAV buffer for [freqHz] at
  /// [attenuationDb] relative to [referencePeakAmplitude].
  static Uint8List synthesizeWarbleWav({
    required int freqHz,
    required double attenuationDb,
    EarChannel channel = EarChannel.both,
    int sampleRateHz = defaultSampleRateHz,
    int durationMs = defaultDurationMs,
  }) {
    final safeFreq = freqHz.clamp(20, 20000).toDouble();
    final safeAtten = attenuationDb.clamp(minAttenuationDb, maxAttenuationDb);
    final safeRate = sampleRateHz.clamp(8000, 96000);
    final safeDurMs = durationMs.clamp(200, 5000);

    final totalFrames = (safeRate * safeDurMs) ~/ 1000;
    const channels = 2;
    const bitsPerSample = 16;
    const bytesPerSample = bitsPerSample ~/ 8;
    final dataBytes = totalFrames * channels * bytesPerSample;
    final totalBytes = 44 + dataBytes;

    final out = ByteData(totalBytes);
    _writeAscii(out, 0, 'RIFF');
    out.setUint32(4, 36 + dataBytes, Endian.little);
    _writeAscii(out, 8, 'WAVE');
    _writeAscii(out, 12, 'fmt ');
    out.setUint32(16, 16, Endian.little); // PCM fmt chunk size
    out.setUint16(20, 1, Endian.little); // PCM format tag
    out.setUint16(22, channels, Endian.little);
    out.setUint32(24, safeRate, Endian.little);
    out.setUint32(28, safeRate * channels * bytesPerSample, Endian.little);
    out.setUint16(32, channels * bytesPerSample, Endian.little);
    out.setUint16(34, bitsPerSample, Endian.little);
    _writeAscii(out, 36, 'data');
    out.setUint32(40, dataBytes, Endian.little);

    final linearGain =
        referencePeakAmplitude * math.pow(10.0, safeAtten / 20.0);
    final playLeft = channel == EarChannel.both || channel == EarChannel.left;
    final playRight = channel == EarChannel.both || channel == EarChannel.right;

    // Two gentle bursts inside the loop window with quiet gaps at edges.
    final pulse1Start = (totalFrames * 0.05).round();
    final pulse1End = (totalFrames * 0.42).round();
    final pulse2Start = (totalFrames * 0.52).round();
    final pulse2End = (totalFrames * 0.89).round();
    final rampFrames = math.max(1, (safeRate * 0.030).round());

    double phase = 0.0;
    const warbleRateHz = 4.5;
    const warbleDepth = 0.02; // +/- 2% FM warble

    for (var i = 0; i < totalFrames; i++) {
      final t = i / safeRate;
      final env1 = _pulseEnvelope(i, pulse1Start, pulse1End, rampFrames);
      final env2 = _pulseEnvelope(i, pulse2Start, pulse2End, rampFrames);
      final env = math.max(env1, env2);

      final instFreq =
          safeFreq * (1.0 + warbleDepth * math.sin(2.0 * math.pi * warbleRateHz * t));
      phase += 2.0 * math.pi * instFreq / safeRate;
      if (phase > 2.0 * math.pi) {
        phase -= 2.0 * math.pi * (phase / (2.0 * math.pi)).floor();
      }

      final sampleFloat = math.sin(phase) * env * linearGain;
      final sampleInt =
          (sampleFloat * 32767.0).round().clamp(-32767, 32767);

      final offset = 44 + i * 4;
      out.setInt16(offset, playLeft ? sampleInt : 0, Endian.little);
      out.setInt16(offset + 2, playRight ? sampleInt : 0, Endian.little);
    }

    return out.buffer.asUint8List();
  }

  static double _pulseEnvelope(int frame, int start, int end, int ramp) {
    if (frame <= start || frame >= end) return 0.0;
    final len = end - start;
    final effRamp = math.min(ramp, len ~/ 3);
    if (effRamp <= 0) return 1.0;
    final fromStart = frame - start;
    if (fromStart < effRamp) {
      return 0.5 * (1.0 - math.cos(math.pi * fromStart / effRamp));
    }
    final toEnd = end - frame;
    if (toEnd < effRamp) {
      return 0.5 * (1.0 - math.cos(math.pi * toEnd / effRamp));
    }
    return 1.0;
  }

  static void _writeAscii(ByteData out, int offset, String text) {
    for (var i = 0; i < text.length; i++) {
      out.setUint8(offset + i, text.codeUnitAt(i));
    }
  }

  /// Parses basic metadata from [bytes], or returns null if invalid.
  static WavHeaderInfo? parseWavHeader(Uint8List bytes) {
    if (bytes.length < 44) return null;
    final data = ByteData.sublistView(bytes);
    String readAscii(int off, int len) =>
        String.fromCharCodes(bytes.sublist(off, off + len));
    if (readAscii(0, 4) != 'RIFF' ||
        readAscii(8, 4) != 'WAVE' ||
        readAscii(12, 4) != 'fmt ' ||
        readAscii(36, 4) != 'data') {
      return null;
    }
    return WavHeaderInfo(
      sampleRateHz: data.getUint32(24, Endian.little),
      channels: data.getUint16(22, Endian.little),
      bitsPerSample: data.getUint16(34, Endian.little),
      dataBytes: data.getUint32(40, Endian.little),
    );
  }
}
