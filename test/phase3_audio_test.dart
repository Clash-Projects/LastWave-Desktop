import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/audio/stream_models.dart';
import 'package:lastwave_desktop/core/storage/prefs.dart';
import 'package:lastwave_desktop/features/audio_output/format_negotiator.dart';
import 'package:lastwave_desktop/features/audio_output/output_path_status.dart';
import 'package:lastwave_desktop/features/audio_output/pcm_format.dart';
import 'package:lastwave_desktop/features/equalizer/headphone_profiles.dart';
import 'package:lastwave_desktop/features/player/audio_graph.dart';
import 'package:lastwave_desktop/features/player/loudness.dart';
import 'package:lastwave_desktop/features/player/timed_mix.dart';

void main() {
  test('data saver is a persisted quality and names the YouTube fallback', () {
    expect(Prefs.allowedQualities, contains(AudioQualityTiers.dataSaver));
    expect(
      AudioQualityTiers.label(AudioQualityTiers.dataSaver),
      contains('smallest YouTube'),
    );
  });

  test('loudness uses tags when present and does not invent a scan', () {
    expect(
      LoudnessMath.tagGainDb(mode: 'track', trackGainDb: -6, albumGainDb: -3),
      -6,
    );
    expect(
      LoudnessMath.tagGainDb(mode: 'album', trackGainDb: -6, albumGainDb: -3),
      -3,
    );
    expect(
      LoudnessMath.tagGainDb(mode: 'album', trackGainDb: -6),
      -6,
    );
    expect(LoudnessMath.tagGainDb(mode: 'track'), isNull);
    expect(LoudnessMath.parseDb('-7.5 dB'), -7.5);
    expect(LoudnessMath.preampDb, 4);
    expect(LoudnessMath.fallbackDb, -3);
    expect(LoudnessMath.sameAlbumGain(-5.0, -5.2), isTrue);
    expect(LoudnessMath.sameAlbumGain(-5.0, -8.0), isFalse);
    expect(
      LoudnessMath.settingsSubtitle('track'),
      contains('not a loudness scan'),
    );
  });

  test('headphone correction is an extra filter and off is empty', () {
    expect(HeadphoneProfiles.off.lavfiFilter, isEmpty);
    expect(HeadphoneProfiles.byId('nope').id, 'off');
    final hd600 = HeadphoneProfiles.hd600.lavfiFilter;
    expect(hd600, contains('equalizer='));
    expect(hd600, isNot(contains('equalizer=f=31')));
  });

  test('equalizer and headphone share one lavfi chain', () {
    final merged = mergeEqualizerAndHeadphone(
      'format=floatp,lavfi=[equalizer=f=31:t=o:w=1:g=1.0]',
      'lavfi=[equalizer=f=100:t=q:w=0.70:g=-2.0]',
    );
    expect(merged, contains('f=31'));
    expect(merged, contains('f=100'));
    expect(merged.startsWith('format=floatp,lavfi=['), isTrue);
    final swept = afWithSweep(merged, 'lowpass=f=1000:poles=1');
    expect(swept, contains('f=31'));
    expect(swept, contains('lowpass=f=1000'));
  });

  test('timed mix sweep moves and is not a beat grid', () {
    expect(TimedMixSweep.outgoing(0), contains('lowpass'));
    expect(TimedMixSweep.incoming(1), contains('highpass'));
    expect(
      TimedMixSweep.hz(16000, 180, 1).round(),
      180,
    );
  });

  test('loudness, automix, and pitch block bit-perfect', () {
    final negotiator = FormatNegotiator();
    final decision = negotiator.negotiate(
      source: const PcmFormat(sampleRateHz: 44100, bitDepth: 16),
      device: null,
      exclusiveRequested: true,
    );
    BitPerfectReason reason({
      bool loudness = false,
      bool autoMix = false,
      double pitch = 1,
      double speed = 1,
    }) {
      return negotiator.evaluate(
        decision: decision,
        exclusiveRequested: true,
        exclusiveActive: true,
        deviceAvailable: true,
        dspActive: false,
        peqActive: false,
        softwareVolume: false,
        crossfade: false,
        speed: speed,
        loudness: loudness,
        autoMix: autoMix,
        pitch: pitch,
      );
    }

    expect(reason(loudness: true), BitPerfectReason.loudnessActive);
    expect(reason(autoMix: true), BitPerfectReason.autoMixActive);
    expect(reason(pitch: 1.2), BitPerfectReason.pitchNotUnity);
    expect(reason(speed: 1.25), BitPerfectReason.speedNotUnity);
  });
}
