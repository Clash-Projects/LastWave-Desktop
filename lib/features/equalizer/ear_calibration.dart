import 'dart:convert';
import 'dart:math' as math;

import 'ear_tone_generator.dart';
import 'equalizer_models.dart';

/// Whether calibration tests both ears together or left and right separately.
enum EarTestMode {
  bothEars('both', 'Both Ears (Quick)'),
  leftAndRight('lr', 'Left + Right Ear');

  final String key;
  final String label;
  const EarTestMode(this.key, this.label);

  static EarTestMode fromKey(String? raw) =>
      raw == 'lr' ? leftAndRight : bothEars;
}

/// Compensation amount applied on top of raw measured deviations.
enum CalibrationStrength {
  subtle('subtle', 'Subtle', 0.55),
  balanced('balanced', 'Balanced', 0.80),
  full('full', 'Full', 1.00);

  final String key;
  final String label;
  final double factor;
  const CalibrationStrength(this.key, this.label, this.factor);

  static CalibrationStrength fromKey(String? raw) => switch (raw) {
        'subtle' => subtle,
        'full' => full,
        _ => balanced,
      };
}

/// Listener action during a frequency test step.
enum ListenerResponse {
  hearClearly,
  barelyHear,
  cannotHear,
}

/// One frequency probe inside an ear calibration run.
class EarProbeStep {
  final EarChannel channel;
  final int freqHz;

  const EarProbeStep({
    required this.channel,
    required this.freqHz,
  });

  String get bandTitle => switch (freqHz) {
        <= 80 => 'Sub-Bass ($freqHz Hz)',
        <= 160 => 'Warm Bass ($freqHz Hz)',
        <= 350 => 'Low-Mid Body ($freqHz Hz)',
        <= 750 => 'Midrange ($freqHz Hz)',
        <= 1400 => 'Reference Mid ($freqHz Hz)',
        <= 2800 => 'Vocal Presence (${eqBandLabel(freqHz)} Hz)',
        <= 5500 => 'Upper Clarity (${eqBandLabel(freqHz)} Hz)',
        _ => 'Treble Air (${eqBandLabel(freqHz)} Hz)',
      };

  String get channelLabel => switch (channel) {
        EarChannel.both => 'Both Ears',
        EarChannel.left => 'Left Ear',
        EarChannel.right => 'Right Ear',
      };
}

/// Completed measurement result before or after strength scaling.
class EarCalibrationResult {
  final EarTestMode mode;
  final Map<int, double> leftThresholdsDb;
  final Map<int, double> rightThresholdsDb;
  final List<double> balancedGainsDb;
  final double? leftRightDeltaDb;
  final String summary;

  const EarCalibrationResult({
    required this.mode,
    required this.leftThresholdsDb,
    required this.rightThresholdsDb,
    required this.balancedGainsDb,
    this.leftRightDeltaDb,
    required this.summary,
  });
}

/// Persisted custom listener ear EQ profile.
class SavedEarProfile {
  final String id;
  final String name;
  final int createdAtMs;
  final EarTestMode mode;
  final CalibrationStrength strength;
  final List<double> gainsDb;
  final Map<int, double> leftThresholdsDb;
  final Map<int, double> rightThresholdsDb;
  final String summary;

  const SavedEarProfile({
    required this.id,
    required this.name,
    required this.createdAtMs,
    required this.mode,
    required this.strength,
    required this.gainsDb,
    this.leftThresholdsDb = const {},
    this.rightThresholdsDb = const {},
    this.summary = '',
  });

  EqPreset toEqPreset() => EqPreset(name, gainsDb);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'createdAtMs': createdAtMs,
        'mode': mode.key,
        'strength': strength.key,
        'gainsDb': gainsDb,
        'leftThresholdsDb': {
          for (final e in leftThresholdsDb.entries) '${e.key}': e.value,
        },
        'rightThresholdsDb': {
          for (final e in rightThresholdsDb.entries) '${e.key}': e.value,
        },
        'summary': summary,
      };

  static SavedEarProfile? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final id = raw['id']?.toString().trim() ?? '';
    final name = raw['name']?.toString().trim() ?? '';
    if (id.isEmpty || name.isEmpty) return null;

    final rawGains = raw['gainsDb'];
    if (rawGains is! List || rawGains.length != eqBandFreqsHz.length) {
      return null;
    }
    final gains = <double>[];
    for (final v in rawGains) {
      if (v is! num || !v.isFinite) return null;
      gains.add(
        double.parse(
          v.toDouble().clamp(-eqMaxGainDb, eqMaxGainDb).toStringAsFixed(1),
        ),
      );
    }

    Map<int, double> parseThresh(dynamic mapRaw) {
      if (mapRaw is! Map) return const {};
      final out = <int, double>{};
      for (final entry in mapRaw.entries) {
        final freq = int.tryParse('${entry.key}');
        final val = entry.value;
        if (freq != null && val is num && val.isFinite) {
          out[freq] = val.toDouble();
        }
      }
      return out;
    }

    return SavedEarProfile(
      id: id,
      name: name,
      createdAtMs: raw['createdAtMs'] is num
          ? (raw['createdAtMs'] as num).toInt()
          : 0,
      mode: EarTestMode.fromKey(raw['mode']?.toString()),
      strength: CalibrationStrength.fromKey(raw['strength']?.toString()),
      gainsDb: List<double>.unmodifiable(gains),
      leftThresholdsDb: Map<int, double>.unmodifiable(
        parseThresh(raw['leftThresholdsDb']),
      ),
      rightThresholdsDb: Map<int, double>.unmodifiable(
        parseThresh(raw['rightThresholdsDb']),
      ),
      summary: raw['summary']?.toString() ?? '',
    );
  }

  static String encodeList(List<SavedEarProfile> profiles) =>
      jsonEncode([for (final p in profiles) p.toJson()]);

  static List<SavedEarProfile> decodeList(String raw) {
    if (raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final out = <SavedEarProfile>[];
      for (final item in decoded) {
        final parsed = fromJson(item);
        if (parsed != null) out.add(parsed);
      }
      return List<SavedEarProfile>.unmodifiable(out);
    } catch (_) {
      return const [];
    }
  }
}

/// Psychoacoustic curve synthesis from threshold measurements to LastWave's
/// 10 ISO bands (`[31, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000] Hz`).
class EarProfileSynthesizer {
  EarProfileSynthesizer._();

  /// Normal ISO-226 moderate-level (~60 phon) relative threshold offsets vs 1 kHz.
  /// Subtracting these keeps healthy ears near a flat ~0 dB curve instead of
  /// over-boosting sub-bass where human ears naturally need more SPL.
  static const Map<int, double> normalSensitivityOffsetDb = {
    63: 14.0,
    125: 8.0,
    250: 4.0,
    500: 1.5,
    1000: 0.0,
    2000: -1.5,
    4000: -2.0,
    8000: 4.0,
  };

  static const List<int> bothEarsFrequencies = [
    1000,
    500,
    250,
    63,
    2000,
    4000,
    8000,
  ];

  static const List<int> splitEarFrequencies = [
    1000,
    250,
    63,
    4000,
    8000,
  ];

  /// Expected sensitivity offset at any [freqHz] via log2 interpolation.
  static double expectedOffsetAt(int freqHz) {
    final keys = normalSensitivityOffsetDb.keys.toList()..sort();
    return _interpolateLogFreq(
      freqHz.toDouble(),
      {for (final k in keys) k: normalSensitivityOffsetDb[k]!},
    );
  }

  /// Synthesizes a 10-band EQ profile and summary from measured thresholds.
  static EarCalibrationResult synthesize({
    required EarTestMode mode,
    required Map<int, double> leftThresholdsDb,
    required Map<int, double> rightThresholdsDb,
    CalibrationStrength strength = CalibrationStrength.balanced,
  }) {
    final effectiveLeft =
        leftThresholdsDb.isNotEmpty ? leftThresholdsDb : rightThresholdsDb;
    final effectiveRight =
        rightThresholdsDb.isNotEmpty ? rightThresholdsDb : leftThresholdsDb;

    final combinedOffsets = <int, double>{};
    final allFreqs = <int>{...effectiveLeft.keys, ...effectiveRight.keys}.toList()
      ..sort();

    final leftRef = effectiveLeft[1000] ?? _mean(effectiveLeft.values);
    final rightRef = effectiveRight[1000] ?? _mean(effectiveRight.values);

    final earDeltas = <double>[];
    for (final freq in allFreqs) {
      final expected = expectedOffsetAt(freq);
      final lVal = effectiveLeft[freq];
      final rVal = effectiveRight[freq];

      final lDev = lVal != null ? (lVal - leftRef) - expected : null;
      final rDev = rVal != null ? (rVal - rightRef) - expected : null;

      if (lDev != null && rDev != null) {
        // Weight the slightly less sensitive ear a bit higher without
        // over-driving the stronger ear.
        final hi = math.max(lDev, rDev);
        final lo = math.min(lDev, rDev);
        combinedOffsets[freq] = 0.65 * hi + 0.35 * lo;
        earDeltas.add(lVal! - rVal!);
      } else {
        combinedOffsets[freq] = (lDev ?? rDev ?? 0.0);
      }
    }

    // Half-gain rule (~0.58) keeps music natural and avoids harsh peaks.
    const halfGainCompression = 0.58;
    final scale = halfGainCompression * strength.factor;

    final rawBands = <double>[];
    for (final bandHz in eqBandFreqsHz) {
      double interp = _interpolateLogFreq(bandHz.toDouble(), combinedOffsets);
      if (bandHz < 63) {
        interp *= 0.70; // Gentle sub-bass taper below 63 Hz
      } else if (bandHz > 8000) {
        interp *= 0.75; // Gentle air-band taper at 16 kHz
      }
      rawBands.add(interp * scale);
    }

    // Mean-center so overall loudness remains balanced, then clamp to +/-8 dB.
    final avg = _mean(rawBands);
    final gainsDb = List<double>.generate(rawBands.length, (i) {
      final centered = (rawBands[i] - avg).clamp(-eqMaxGainDb, eqMaxGainDb);
      return double.parse(centered.toStringAsFixed(1));
    }, growable: false);

    double? lrDelta;
    if (mode == EarTestMode.leftAndRight && earDeltas.isNotEmpty) {
      lrDelta = double.parse(_mean(earDeltas).toStringAsFixed(1));
    }

    final summary = _buildSummary(gainsDb, mode, lrDelta);

    return EarCalibrationResult(
      mode: mode,
      leftThresholdsDb: Map<int, double>.unmodifiable(effectiveLeft),
      rightThresholdsDb: Map<int, double>.unmodifiable(effectiveRight),
      balancedGainsDb: List<double>.unmodifiable(gainsDb),
      leftRightDeltaDb: lrDelta,
      summary: summary,
    );
  }

  static String _buildSummary(
    List<double> gains,
    EarTestMode mode,
    double? lrDelta,
  ) {
    final bassAvg = (gains[0] + gains[1] + gains[2]) / 3.0;
    final midAvg = (gains[4] + gains[5]) / 2.0;
    final highAvg = (gains[7] + gains[8] + gains[9]) / 3.0;

    final traits = <String>[];
    if (bassAvg >= 1.2) {
      traits.add('warm bass support');
    } else if (bassAvg <= -1.2) {
      traits.add('tightened bass');
    }
    if (midAvg >= 1.2) {
      traits.add('vocal midrange lift');
    }
    if (highAvg >= 1.2) {
      traits.add('crisp treble clarity');
    } else if (highAvg <= -1.2) {
      traits.add('smoothed treble');
    }

    final tonalPart = traits.isEmpty
        ? 'Near-neutral reference response'
        : _capitalize(traits.join(' + '));

    if (mode == EarTestMode.leftAndRight && lrDelta != null) {
      if (lrDelta.abs() < 1.5) {
        return '$tonalPart · Balanced L/R ears';
      }
      final softerEar = lrDelta > 0 ? 'Left' : 'Right';
      return '$tonalPart · $softerEar ear ~${lrDelta.abs().toStringAsFixed(1)} dB softer';
    }
    return tonalPart;
  }

  static String _capitalize(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

  static double _mean(Iterable<double> values) {
    var sum = 0.0;
    var count = 0;
    for (final v in values) {
      sum += v;
      count++;
    }
    return count == 0 ? 0.0 : sum / count;
  }

  static double _interpolateLogFreq(double freqHz, Map<int, double> anchors) {
    if (anchors.isEmpty) return 0.0;
    final keys = anchors.keys.toList()..sort();
    if (freqHz <= keys.first) return anchors[keys.first]!;
    if (freqHz >= keys.last) return anchors[keys.last]!;

    final targetLog = math.log(freqHz);
    for (var i = 0; i < keys.length - 1; i++) {
      final f0 = keys[i];
      final f1 = keys[i + 1];
      if (freqHz >= f0 && freqHz <= f1) {
        final l0 = math.log(f0);
        final l1 = math.log(f1);
        final t = (targetLog - l0) / (l1 - l0);
        return anchors[f0]! + (anchors[f1]! - anchors[f0]!) * t;
      }
    }
    return 0.0;
  }
}

/// Interactive adaptive-staircase state machine for "play -> listen -> tell".
class EarCalibrationSession {
  final EarTestMode mode;
  final List<EarProbeStep> steps;

  int _stepIndex = 0;
  double _currentAttenuationDb = -16.0;
  double _stepSizeDb = 6.0;
  int _lastDirection = 0; // -1 quieter, +1 louder
  int _reversals = 0;
  int _responsesInStep = 0;

  final Map<int, double> _leftThresholdsDb = {};
  final Map<int, double> _rightThresholdsDb = {};

  EarCalibrationSession({required this.mode}) : steps = _buildSteps(mode);

  static List<EarProbeStep> _buildSteps(EarTestMode mode) {
    if (mode == EarTestMode.bothEars) {
      return [
        for (final f in EarProfileSynthesizer.bothEarsFrequencies)
          EarProbeStep(channel: EarChannel.both, freqHz: f),
      ];
    }
    return [
      for (final f in EarProfileSynthesizer.splitEarFrequencies)
        EarProbeStep(channel: EarChannel.left, freqHz: f),
      for (final f in EarProfileSynthesizer.splitEarFrequencies)
        EarProbeStep(channel: EarChannel.right, freqHz: f),
    ];
  }

  bool get isCompleted => _stepIndex >= steps.length;
  int get stepIndex => _stepIndex;
  int get totalSteps => steps.length;
  double get progress =>
      steps.isEmpty ? 1.0 : (_stepIndex / steps.length).clamp(0.0, 1.0);

  EarProbeStep get currentStep =>
      steps[_stepIndex.clamp(0, steps.length - 1)];

  double get currentAttenuationDb => _currentAttenuationDb;
  double get stepSizeDb => _stepSizeDb;
  int get responsesInStep => _responsesInStep;

  Map<int, double> get leftThresholdsDb =>
      Map<int, double>.unmodifiable(_leftThresholdsDb);
  Map<int, double> get rightThresholdsDb =>
      Map<int, double>.unmodifiable(_rightThresholdsDb);

  /// Records a listener response for the current frequency probe.
  /// Returns `true` when this response locked the current band and advanced
  /// to the next step (or completed the session).
  bool recordResponse(ListenerResponse response) {
    if (isCompleted) return false;
    _responsesInStep++;

    switch (response) {
      case ListenerResponse.barelyHear:
        _lockCurrentAndAdvance();
        return true;

      case ListenerResponse.hearClearly:
        if (_currentAttenuationDb <= EarToneGenerator.minAttenuationDb + 0.5) {
          _lockCurrentAndAdvance();
          return true;
        }
        if (_lastDirection == 1) {
          _reversals++;
          _stepSizeDb = math.max(2.0, _stepSizeDb / 2.0);
        }
        _lastDirection = -1;
        _currentAttenuationDb = (_currentAttenuationDb - _stepSizeDb)
            .clamp(
              EarToneGenerator.minAttenuationDb,
              EarToneGenerator.maxAttenuationDb,
            )
            .toDouble();
        if (_reversals >= 2 && _stepSizeDb <= 2.0) {
          _lockCurrentAndAdvance();
          return true;
        }
        return false;

      case ListenerResponse.cannotHear:
        if (_currentAttenuationDb >= EarToneGenerator.maxAttenuationDb - 0.5) {
          _lockCurrentAndAdvance();
          return true;
        }
        if (_lastDirection == -1) {
          _reversals++;
          _stepSizeDb = math.max(2.0, _stepSizeDb / 2.0);
        }
        _lastDirection = 1;
        _currentAttenuationDb = (_currentAttenuationDb + _stepSizeDb)
            .clamp(
              EarToneGenerator.minAttenuationDb,
              EarToneGenerator.maxAttenuationDb,
            )
            .toDouble();
        if (_reversals >= 2 && _stepSizeDb <= 2.0) {
          _lockCurrentAndAdvance();
          return true;
        }
        return false;
    }
  }

  void _lockCurrentAndAdvance() {
    final step = currentStep;
    if (step.channel == EarChannel.left || step.channel == EarChannel.both) {
      _leftThresholdsDb[step.freqHz] = _currentAttenuationDb;
    }
    if (step.channel == EarChannel.right || step.channel == EarChannel.both) {
      _rightThresholdsDb[step.freqHz] = _currentAttenuationDb;
    }

    _stepIndex++;
    _resetProbeForNextStep();
  }

  void _resetProbeForNextStep() {
    _stepSizeDb = 6.0;
    _lastDirection = 0;
    _reversals = 0;
    _responsesInStep = 0;
    if (isCompleted) return;
    // Start slightly softer around 1k-4k and slightly higher at 63 Hz so the
    // first tone at each band starts comfortably near expected audibility.
    final nextFreq = currentStep.freqHz;
    final offset = EarProfileSynthesizer.expectedOffsetAt(nextFreq);
    _currentAttenuationDb = (-18.0 + offset * 0.5)
        .clamp(
          EarToneGenerator.minAttenuationDb + 4.0,
          EarToneGenerator.maxAttenuationDb - 4.0,
        )
        .toDouble();
  }

  EarCalibrationResult buildResult({
    CalibrationStrength strength = CalibrationStrength.balanced,
  }) {
    return EarProfileSynthesizer.synthesize(
      mode: mode,
      leftThresholdsDb: _leftThresholdsDb,
      rightThresholdsDb: _rightThresholdsDb,
      strength: strength,
    );
  }
}
