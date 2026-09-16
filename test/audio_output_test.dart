import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/audio_output/dac_device.dart';
import 'package:lastwave_desktop/features/audio_output/format_negotiator.dart';
import 'package:lastwave_desktop/features/audio_output/output_path_status.dart';
import 'package:lastwave_desktop/features/audio_output/pcm_format.dart';

void main() {
  const negotiator = FormatNegotiator();

  DacDevice dac({
    bool exclusive = true,
    List<PcmFormat> formats = const [
      PcmFormat(sampleRateHz: 44100, bitDepth: 16),
      PcmFormat(sampleRateHz: 48000, bitDepth: 16),
      PcmFormat(sampleRateHz: 44100, bitDepth: 24),
      PcmFormat(sampleRateHz: 48000, bitDepth: 24),
      PcmFormat(sampleRateHz: 88200, bitDepth: 24),
      PcmFormat(sampleRateHz: 96000, bitDepth: 24),
      PcmFormat(sampleRateHz: 176400, bitDepth: 24),
      PcmFormat(sampleRateHz: 192000, bitDepth: 24),
    ],
  }) =>
      DacDevice(
        id: 'dac',
        name: 'FiiO K7',
        exclusiveSupported: exclusive,
        hardwareVolume: true,
        formats: formats,
      );

  group('native format match', () {
    test('16/44.1 stays 16/44.1', () {
      const source = PcmFormat(sampleRateHz: 44100, bitDepth: 16);
      final d = negotiator.negotiate(
        source: source,
        device: dac(),
        exclusiveRequested: true,
      );
      expect(d.nativeMatch, isTrue);
      expect(d.output, source);
      expect(d.resampling, isFalse);
    });

    test('24/44.1 stays 24/44.1', () {
      const source = PcmFormat(sampleRateHz: 44100, bitDepth: 24);
      final d = negotiator.negotiate(
        source: source,
        device: dac(),
        exclusiveRequested: true,
      );
      expect(d.output, source);
      expect(d.nativeMatch, isTrue);
    });

    test('24/48 stays 24/48', () {
      const source = PcmFormat(sampleRateHz: 48000, bitDepth: 24);
      final d = negotiator.negotiate(
        source: source,
        device: dac(),
        exclusiveRequested: true,
      );
      expect(d.output, source);
    });

    test('24/96 stays 24/96', () {
      const source = PcmFormat(sampleRateHz: 96000, bitDepth: 24);
      final d = negotiator.negotiate(
        source: source,
        device: dac(),
        exclusiveRequested: true,
      );
      expect(d.output, source);
      expect(d.resampling, isFalse);
    });

    test('24/192 stays 24/192', () {
      const source = PcmFormat(sampleRateHz: 192000, bitDepth: 24);
      final d = negotiator.negotiate(
        source: source,
        device: dac(),
        exclusiveRequested: true,
      );
      expect(d.output, source);
    });
  });

  group('fallback is explicit', () {
    test('44.1 → 48 when 44.1 missing', () {
      const source = PcmFormat(sampleRateHz: 44100, bitDepth: 24);
      final d = negotiator.negotiate(
        source: source,
        device: dac(formats: const [
          PcmFormat(sampleRateHz: 48000, bitDepth: 24),
          PcmFormat(sampleRateHz: 96000, bitDepth: 24),
        ]),
        exclusiveRequested: true,
      );
      expect(d.nativeMatch, isFalse);
      expect(d.resampling, isTrue);
      expect(d.output?.sampleRateHz, 48000);
    });

    test('unsupported 384 kHz does not claim native', () {
      const source = PcmFormat(sampleRateHz: 384000, bitDepth: 32);
      final d = negotiator.negotiate(
        source: source,
        device: dac(),
        exclusiveRequested: true,
      );
      expect(d.nativeMatch, isFalse);
      expect(d.note.toLowerCase(), contains('unavailable'));
    });

    test('shared mode never matches native', () {
      const source = PcmFormat(sampleRateHz: 96000, bitDepth: 24);
      final d = negotiator.negotiate(
        source: source,
        device: dac(),
        exclusiveRequested: false,
      );
      expect(d.nativeMatch, isFalse);
      expect(d.note.toLowerCase(), contains('shared'));
    });
  });

  group('bit-perfect state machine', () {
    FormatDecision native() => negotiator.negotiate(
          source: const PcmFormat(sampleRateHz: 96000, bitDepth: 24),
          device: dac(),
          exclusiveRequested: true,
        );

    test('exclusive + native + no DSP + unity volume = bit-perfect', () {
      expect(
        negotiator.evaluate(
          decision: native(),
          exclusiveRequested: true,
          exclusiveActive: true,
          deviceAvailable: true,
          dspActive: false,
          peqActive: false,
          softwareVolume: false,
          crossfade: false,
          speed: 1.0,
        ),
        BitPerfectReason.bitPerfect,
      );
    });

    test('PEQ blocks bit-perfect', () {
      expect(
        negotiator.evaluate(
          decision: native(),
          exclusiveRequested: true,
          exclusiveActive: true,
          deviceAvailable: true,
          dspActive: false,
          peqActive: true,
          softwareVolume: false,
          crossfade: false,
          speed: 1.0,
        ),
        BitPerfectReason.peqActive,
      );
    });

    test('software volume blocks bit-perfect', () {
      expect(
        negotiator.evaluate(
          decision: native(),
          exclusiveRequested: true,
          exclusiveActive: true,
          deviceAvailable: true,
          dspActive: false,
          peqActive: false,
          softwareVolume: true,
          crossfade: false,
          speed: 1.0,
        ),
        BitPerfectReason.softwareVolume,
      );
    });

    test('shared mode is not bit-perfect', () {
      expect(
        negotiator.evaluate(
          decision: native(),
          exclusiveRequested: false,
          exclusiveActive: false,
          deviceAvailable: true,
          dspActive: false,
          peqActive: false,
          softwareVolume: false,
          crossfade: false,
          speed: 1.0,
        ),
        BitPerfectReason.sharedMode,
      );
    });

    test('same-format consecutive tracks stay native', () {
      const a = PcmFormat(sampleRateHz: 96000, bitDepth: 24);
      const b = PcmFormat(sampleRateHz: 96000, bitDepth: 24);
      expect(a.matches(b), isTrue);
    });

    test('different-format tracks require a new exclusive format', () {
      const a = PcmFormat(sampleRateHz: 44100, bitDepth: 16);
      const b = PcmFormat(sampleRateHz: 96000, bitDepth: 24);
      expect(a.matches(b), isFalse);
      final next = negotiator.negotiate(
        source: b,
        device: dac(),
        exclusiveRequested: true,
      );
      expect(next.output, b);
    });
  });

  group('rate/depth fallbacks', () {
    test('44.1 → 96 when only 96 is listed', () {
      const source = PcmFormat(sampleRateHz: 44100, bitDepth: 24);
      final d = negotiator.negotiate(
        source: source,
        device: dac(formats: const [
          PcmFormat(sampleRateHz: 96000, bitDepth: 24),
        ]),
        exclusiveRequested: true,
      );
      expect(d.resampling, isTrue);
      expect(d.nativeMatch, isFalse);
      expect(d.output?.sampleRateHz, 96000);
    });

    test('96 → 192 when 96 is missing', () {
      const source = PcmFormat(sampleRateHz: 96000, bitDepth: 24);
      final d = negotiator.negotiate(
        source: source,
        device: dac(formats: const [
          PcmFormat(sampleRateHz: 192000, bitDepth: 24),
        ]),
        exclusiveRequested: true,
      );
      expect(d.resampling, isTrue);
      expect(d.output?.sampleRateHz, 192000);
    });

    test('unsupported bit depth does not claim native', () {
      const source = PcmFormat(sampleRateHz: 96000, bitDepth: 32);
      final d = negotiator.negotiate(
        source: source,
        device: dac(),
        exclusiveRequested: true,
      );
      expect(d.nativeMatch, isFalse);
      expect(d.formatConversion, isTrue);
    });
  });

  group('status reasons', () {
    FormatDecision native() => negotiator.negotiate(
          source: const PcmFormat(sampleRateHz: 96000, bitDepth: 24),
          device: dac(),
          exclusiveRequested: true,
        );

    test('exclusive failure is exclusiveUnavailable', () {
      expect(
        negotiator.evaluate(
          decision: native(),
          exclusiveRequested: true,
          exclusiveActive: false,
          deviceAvailable: true,
          dspActive: false,
          peqActive: false,
          softwareVolume: false,
          crossfade: false,
          speed: 1.0,
        ),
        BitPerfectReason.exclusiveUnavailable,
      );
    });

    test('device missing is deviceUnavailable', () {
      expect(
        negotiator.evaluate(
          decision: native(),
          exclusiveRequested: true,
          exclusiveActive: false,
          deviceAvailable: false,
          dspActive: false,
          peqActive: false,
          softwareVolume: false,
          crossfade: false,
          speed: 1.0,
        ),
        BitPerfectReason.deviceUnavailable,
      );
    });

    test('crossfade blocks bit-perfect', () {
      expect(
        negotiator.evaluate(
          decision: native(),
          exclusiveRequested: true,
          exclusiveActive: true,
          deviceAvailable: true,
          dspActive: false,
          peqActive: false,
          softwareVolume: false,
          crossfade: true,
          speed: 1.0,
        ),
        BitPerfectReason.crossfadeActive,
      );
    });

    test('DSP blocks bit-perfect', () {
      expect(
        negotiator.evaluate(
          decision: native(),
          exclusiveRequested: true,
          exclusiveActive: true,
          deviceAvailable: true,
          dspActive: true,
          peqActive: false,
          softwareVolume: false,
          crossfade: false,
          speed: 1.0,
        ),
        BitPerfectReason.dspActive,
      );
    });

    test('exclusive unavailable on device', () {
      const source = PcmFormat(sampleRateHz: 96000, bitDepth: 24);
      final d = negotiator.negotiate(
        source: source,
        device: dac(exclusive: false, formats: const []),
        exclusiveRequested: true,
      );
      expect(d.nativeMatch, isFalse);
      expect(d.output, isNull);
      expect(
        negotiator.evaluate(
          decision: d,
          exclusiveRequested: true,
          exclusiveActive: false,
          deviceAvailable: true,
          dspActive: false,
          peqActive: false,
          softwareVolume: false,
          crossfade: false,
          speed: 1.0,
        ),
        BitPerfectReason.exclusiveUnavailable,
      );
    });
  });

  group('24-bit is not reported as 32-bit', () {
    test('DAC with 24 and 32 keeps 24-bit source native', () {
      const source = PcmFormat(sampleRateHz: 44100, bitDepth: 24);
      final d = negotiator.negotiate(
        source: source,
        device: dac(formats: const [
          PcmFormat(sampleRateHz: 44100, bitDepth: 16),
          PcmFormat(sampleRateHz: 44100, bitDepth: 24),
          PcmFormat(sampleRateHz: 44100, bitDepth: 32),
        ]),
        exclusiveRequested: true,
      );
      expect(d.nativeMatch, isTrue);
      expect(d.output?.bitDepth, 24);
      expect(d.formatConversion, isFalse);
    });

    test('s32 container with forced s24 is 24-bit', () {
      expect(bitDepthFromMpvFormat('s32', forcedFormat: 's24'), 24);
      expect(bitDepthFromMpvFormat('s24'), 24);
      expect(mpvFormatIsFloat('float'), isTrue);
      expect(mpvSampleFormat(24), 's24');
    });

    test('audio-out-params float is not a PCM match', () {
      expect(
        pcmFromMpvOutParams(
          'samplerate=44100,format=float,channel-count=2',
          forcedFormat: 's24',
        ),
        isNull,
      );
      expect(
        pcmFromMpvOutParams(
          'samplerate=44100,format=s32,channel-count=2',
          forcedFormat: 's24',
        ),
        const PcmFormat(sampleRateHz: 44100, bitDepth: 24, channels: 2),
      );
    });
  });
}
