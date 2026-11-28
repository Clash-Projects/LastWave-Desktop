import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/storage/prefs.dart';
import 'package:lastwave_desktop/features/equalizer/ear_calibration.dart';
import 'package:lastwave_desktop/features/equalizer/ear_tone_generator.dart';
import 'package:lastwave_desktop/features/equalizer/equalizer_controller.dart';
import 'package:lastwave_desktop/features/equalizer/equalizer_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('EarToneGenerator', () {
    test('produces valid RIFF PCM16 stereo WAV within -18 dBFS safety cap', () {
      const rate = 48000;
      const durationMs = 1000;
      final bytes = EarToneGenerator.synthesizeWarbleWav(
        freqHz: 1000,
        attenuationDb: 0.0,
        channel: EarChannel.both,
        sampleRateHz: rate,
        durationMs: durationMs,
      );

      final header = EarToneGenerator.parseWavHeader(bytes);
      expect(header, isNotNull);
      expect(header!.sampleRateHz, rate);
      expect(header.channels, 2);
      expect(header.bitsPerSample, 16);
      expect(header.dataBytes, rate * 4);
      expect(bytes.length, 44 + header.dataBytes);

      final view = ByteData.sublistView(bytes);
      var maxSample = 0;
      for (var off = 44; off < bytes.length; off += 2) {
        final s = view.getInt16(off, Endian.little).abs();
        if (s > maxSample) maxSample = s;
      }
      // -18 dBFS ceiling (~0.1259 * 32767 ≈ 4125)
      expect(maxSample, greaterThan(1000));
      expect(maxSample, lessThanOrEqualTo(4200));
    });

    test('left and right channel isolation mutes the opposite channel', () {
      final leftOnly = EarToneGenerator.synthesizeWarbleWav(
        freqHz: 1000,
        attenuationDb: 0.0,
        channel: EarChannel.left,
        durationMs: 500,
      );
      final rightOnly = EarToneGenerator.synthesizeWarbleWav(
        freqHz: 1000,
        attenuationDb: 0.0,
        channel: EarChannel.right,
        durationMs: 500,
      );

      int maxChannelSample(Uint8List bytes, int channelOffset) {
        final view = ByteData.sublistView(bytes);
        var maxVal = 0;
        for (var off = 44 + channelOffset; off < bytes.length; off += 4) {
          final v = view.getInt16(off, Endian.little).abs();
          if (v > maxVal) maxVal = v;
        }
        return maxVal;
      }

      expect(maxChannelSample(leftOnly, 0), greaterThan(1000));
      expect(maxChannelSample(leftOnly, 2), equals(0));
      expect(maxChannelSample(rightOnly, 0), equals(0));
      expect(maxChannelSample(rightOnly, 2), greaterThan(1000));
    });

    test('parseWavHeader rejects non-WAV bytes cleanly', () {
      expect(EarToneGenerator.parseWavHeader(Uint8List(10)), isNull);
      expect(EarToneGenerator.parseWavHeader(Uint8List(64)), isNull);
    });
  });

  group('EarCalibrationSession & Synthesizer', () {
    test('adaptive staircase narrows step on reversals and locks all bands', () {
      final session = EarCalibrationSession(mode: EarTestMode.bothEars);
      expect(session.totalSteps, EarProfileSynthesizer.bothEarsFrequencies.length);
      expect(session.isCompleted, isFalse);

      // Step 0: reversal lowers step size from 6 dB to 3 dB.
      final initial = session.currentAttenuationDb;
      expect(session.recordResponse(ListenerResponse.hearClearly), isFalse);
      expect(session.currentAttenuationDb, lessThan(initial));
      expect(session.recordResponse(ListenerResponse.cannotHear), isFalse);
      expect(session.stepSizeDb, 3.0);

      // Explicit lock advances cleanly to the next band.
      expect(session.recordResponse(ListenerResponse.barelyHear), isTrue);
      expect(session.stepIndex, 1);

      while (!session.isCompleted) {
        session.recordResponse(ListenerResponse.barelyHear);
      }
      expect(session.isCompleted, isTrue);

      final result = session.buildResult();
      expect(result.balancedGainsDb.length, eqBandFreqsHz.length);
      for (final g in result.balancedGainsDb) {
        expect(g, inInclusiveRange(-eqMaxGainDb, eqMaxGainDb));
      }
    });

    test('ISO-226 healthy baseline yields near-flat curve', () {
      final baseline = <int, double>{
        for (final entry in EarProfileSynthesizer.normalSensitivityOffsetDb.entries)
          entry.key: -24.0 + entry.value,
      };
      final result = EarProfileSynthesizer.synthesize(
        mode: EarTestMode.bothEars,
        leftThresholdsDb: baseline,
        rightThresholdsDb: baseline,
        strength: CalibrationStrength.full,
      );
      for (final g in result.balancedGainsDb) {
        expect(g.abs(), lessThanOrEqualTo(0.2));
      }
      expect(result.summary, contains('Near-neutral'));
    });

    test('high-frequency roll-off produces positive upper-band compensation', () {
      final baseline = <int, double>{
        63: -10.0,
        250: -20.0,
        500: -22.5,
        1000: -24.0,
        2000: -22.5,
        4000: -12.0, // ~14 dB softer than normal -2 dB offset
        8000: -6.0, // ~14 dB softer than normal +4 dB offset
      };
      final subtle = EarProfileSynthesizer.synthesize(
        mode: EarTestMode.bothEars,
        leftThresholdsDb: baseline,
        rightThresholdsDb: baseline,
        strength: CalibrationStrength.subtle,
      );
      final full = EarProfileSynthesizer.synthesize(
        mode: EarTestMode.bothEars,
        leftThresholdsDb: baseline,
        rightThresholdsDb: baseline,
        strength: CalibrationStrength.full,
      );

      // 4k (index 7) and 8k (index 8) should be boosted above 1k (index 5).
      expect(full.balancedGainsDb[7], greaterThan(full.balancedGainsDb[5]));
      expect(full.balancedGainsDb[8], greaterThan(full.balancedGainsDb[5]));
      expect(full.balancedGainsDb[8].abs(), greaterThan(subtle.balancedGainsDb[8].abs()));
      for (final g in full.balancedGainsDb) {
        expect(g, inInclusiveRange(-eqMaxGainDb, eqMaxGainDb));
      }
    });

    test('split L/R mode reports asymmetry when one ear is softer', () {
      final left = {1000: -18.0, 250: -14.0, 63: -4.0, 4000: -16.0, 8000: -10.0};
      final right = {1000: -24.0, 250: -20.0, 63: -10.0, 4000: -26.0, 8000: -20.0};

      final result = EarProfileSynthesizer.synthesize(
        mode: EarTestMode.leftAndRight,
        leftThresholdsDb: left,
        rightThresholdsDb: right,
      );
      expect(result.leftRightDeltaDb, isNotNull);
      expect(result.leftRightDeltaDb!, greaterThan(5.0));
      expect(result.summary, contains('Left ear'));
    });

    test('SavedEarProfile round-trips JSON and ignores malformed payloads', () {
      const profile = SavedEarProfile(
        id: 'ear_1',
        name: 'Late Night IEM',
        createdAtMs: 1700000000000,
        mode: EarTestMode.leftAndRight,
        strength: CalibrationStrength.balanced,
        gainsDb: [1.0, 0.5, 0.0, -0.5, 0.0, 0.2, 1.0, 2.0, 2.5, 1.5],
        leftThresholdsDb: {1000: -24.0},
        rightThresholdsDb: {1000: -24.0},
        summary: 'Crisp treble clarity',
      );
      final encoded = SavedEarProfile.encodeList([profile]);
      final decoded = SavedEarProfile.decodeList(encoded);
      expect(decoded, hasLength(1));
      expect(decoded.first.id, 'ear_1');
      expect(decoded.first.name, 'Late Night IEM');
      expect(decoded.first.mode, EarTestMode.leftAndRight);
      expect(decoded.first.gainsDb, profile.gainsDb);

      expect(SavedEarProfile.decodeList('not valid json'), isEmpty);
      expect(SavedEarProfile.decodeList('[{"id":"","name":"x"}]'), isEmpty);
    });
  });

  group('EqualizerNotifier & Prefs persistence', () {
    test('saves, reloads, applies, and deletes custom ear profiles', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = Prefs(await SharedPreferences.getInstance());
      final emittedFilters = <String>[];

      final notifier = EqualizerNotifier.forTesting(
        prefs,
        onAudioFilter: (af) async => emittedFilters.add(af),
      );

      const profile = SavedEarProfile(
        id: 'ear_test_1',
        name: 'My Ear Profile',
        createdAtMs: 123456,
        mode: EarTestMode.bothEars,
        strength: CalibrationStrength.balanced,
        gainsDb: [1.5, 1.0, 0.0, -0.5, 0.0, 0.5, 1.5, 2.5, 3.0, 2.0],
        summary: 'Crisp treble clarity',
      );

      await notifier.saveAndApplyEarProfile(profile);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(notifier.state.enabled, isTrue);
      expect(notifier.state.activeEarProfileId, 'ear_test_1');
      expect(notifier.state.presetName, 'My Ear Profile');
      expect(notifier.state.savedEarProfiles, hasLength(1));
      expect(emittedFilters.last, contains('equalizer='));

      // Reload from Prefs in a fresh notifier instance.
      final reloaded = EqualizerNotifier.forTesting(prefs);
      expect(reloaded.state.savedEarProfiles, hasLength(1));
      expect(reloaded.state.activeEarProfileId, 'ear_test_1');

      // Switching to a built-in preset clears activeEarProfileId.
      await reloaded.applyPreset(EqualizerPresets.rock);
      expect(reloaded.state.activeEarProfileId, isNull);
      expect(reloaded.state.presetName, 'Rock');

      // Re-applying saved ear profile restores it.
      await reloaded.applyEarProfile(profile);
      expect(reloaded.state.activeEarProfileId, 'ear_test_1');

      // Portable backup keys include saved ear profiles and active id.
      expect(prefs.portablePrefKeys, contains('lw_custom_eq_profiles'));
      expect(prefs.portablePrefKeys, contains('lw_active_ear_profile_id'));
      expect(
        prefs.portablePref('lw_custom_eq_profiles')?.toString(),
        contains('My Ear Profile'),
      );

      // Deleting active profile clears activeEarProfileId and falls back to Custom.
      await reloaded.deleteEarProfile('ear_test_1');
      expect(reloaded.state.savedEarProfiles, isEmpty);
      expect(reloaded.state.activeEarProfileId, isNull);
      expect(reloaded.state.presetName, EqualizerPresets.customName);
    });
  });
}
