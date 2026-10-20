/// 10-band Equalizer models and presets ported from LastWave-Native.
///
/// Center frequencies map directly to the ISO octave bands. Gain range is
/// ±8 dB to guarantee clean, unclipped, audiophile-grade output.
library;

const List<int> eqBandFreqsHz = [
  31,
  63,
  125,
  250,
  500,
  1000,
  2000,
  4000,
  8000,
  16000,
];

const double eqMaxGainDb = 8.0;

/// Compact frequency label under each band slider ("31", "125", "1k", "16k"...).
String eqBandLabel(int hz) => hz >= 1000 ? '${hz ~/ 1000}k' : '$hz';

class EqPreset {
  final String name;
  final List<double> gainsDb;

  const EqPreset(this.name, this.gainsDb);
}

/// Listening-tested curves from LastWave-Native.
class EqualizerPresets {
  EqualizerPresets._();

  static const String customName = 'Custom';

  static const flat = EqPreset(
    'Default',
    [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
  );

  /// Crystal-open audiophile reference curve for Studio Master Clarity.
  /// Tight, controlled sub-bass depth, deliberate low-mid dip that removes
  /// congestion, natural vocal body, presence lift and a silky air shelf.
  static const studioMaster = EqPreset(
    'Studio Master',
    [2.7, 2.2, 0.6, -2.6, -0.6, 1.2, 3.0, 4.0, 4.3, 4.8],
  );

  static const vocalClarity = EqPreset(
    'Vocal Clarity',
    [-1.2, -0.5, 0.0, 1.0, 2.5, 3.5, 2.8, 2.0, 1.5, 1.0],
  );

  static const deepBassClean = EqPreset(
    'Deep Bass Clean',
    [4.8, 3.5, 2.5, 0.0, -0.5, 0.0, 0.0, 0.0, 0.5, 0.5],
  );

  static const rock = EqPreset(
    'Rock',
    [3.8, 3.0, 1.5, -1.0, -0.8, 0.5, 2.0, 3.0, 3.8, 4.0],
  );

  static const pop = EqPreset(
    'Pop',
    [-0.8, 0.0, 1.0, 2.0, 1.8, 1.0, 0.5, 1.0, 1.8, 2.5],
  );

  static const electronic = EqPreset(
    'Electronic',
    [4.2, 3.0, 2.0, -0.5, 0.5, 2.0, 2.5, 2.5, 3.2, 4.0],
  );

  static const rnb = EqPreset(
    'R&B',
    [4.8, 3.5, 2.0, -0.5, -0.8, 0.5, 1.8, 2.5, 3.0, 3.0],
  );

  static const acoustic = EqPreset(
    'Acoustic',
    [2.8, 2.0, 1.5, 1.0, 1.8, 2.0, 1.2, 1.0, 1.2, 1.5],
  );

  static const classical = EqPreset(
    'Classical',
    [2.8, 2.0, 1.5, 0.0, 0.0, 0.5, 1.8, 2.0, 2.8, 3.0],
  );

  static const jazz = EqPreset(
    'Jazz',
    [2.2, 1.5, 1.0, -0.5, 0.2, 1.0, 1.8, 2.0, 2.5, 2.5],
  );

  static const trebleAir = EqPreset(
    'Treble Air',
    [0.0, 0.0, -0.5, -0.5, 0.2, 1.0, 1.8, 3.0, 4.0, 5.0],
  );

  static const List<EqPreset> all = [
    flat,
    studioMaster,
    vocalClarity,
    deepBassClean,
    rock,
    pop,
    electronic,
    rnb,
    acoustic,
    classical,
    jazz,
    trebleAir,
  ];

  static EqPreset? byName(String name) {
    for (final preset in all) {
      if (preset.name.toLowerCase() == name.toLowerCase()) {
        return preset;
      }
    }
    return null;
  }
}

/// Output preset descriptor for the native Studio Master Clarity chain.
class ClarityPreset {
  final int index;
  final String key;
  final String displayName;
  final String description;
  final List<double> trimsDb;

  const ClarityPreset({
    required this.index,
    required this.key,
    required this.displayName,
    required this.description,
    required this.trimsDb,
  });
}

class ClarityPresets {
  ClarityPresets._();

  static const reference = ClarityPreset(
    index: 0,
    key: 'reference',
    displayName: 'Reference',
    description: 'Unmodified audiophile reference curve; all stage trims 0 dB.',
    trimsDb: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
  );

  static const speaker = ClarityPreset(
    index: 1,
    key: 'speaker',
    displayName: 'Speaker',
    description: 'Reduced sub-bass (-1.5 dB) and gentler air (-0.5 dB) for small desktop drivers.',
    trimsDb: [0.0, -1.5, 0.0, 0.0, 0.0, -0.5, 0.0, 0.0],
  );

  static const headphone = ClarityPreset(
    index: 2,
    key: 'headphone',
    displayName: 'Headphone',
    description: 'Lighter bass (-0.5 dB) and softer presence (-1.0 dB) for close-coupled drivers.',
    trimsDb: [0.0, -0.5, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0],
  );

  static const dac = ClarityPreset(
    index: 3,
    key: 'dac',
    displayName: 'DAC',
    description: 'Gentler air (-1.5 dB shelf, -1.0 dB exciter) for revealing external DAC chains.',
    trimsDb: [0.0, 0.0, 0.0, 0.0, 0.0, -1.5, 0.0, -1.0],
  );

  static const List<ClarityPreset> all = [
    reference,
    speaker,
    headphone,
    dac,
  ];

  static ClarityPreset byKey(String key) {
    for (final p in all) {
      if (p.key.toLowerCase() == key.toLowerCase()) return p;
    }
    return reference;
  }
}

class EqualizerState {
  final bool enabled;
  final String presetName;
  final List<double> gainsDb;
  final bool studioClarityEnabled;
  final String clarityPresetKey;

  const EqualizerState({
    this.enabled = false,
    this.presetName = 'Default',
    this.gainsDb = const [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
    this.studioClarityEnabled = false,
    this.clarityPresetKey = 'reference',
  });

  EqualizerState copyWith({
    bool? enabled,
    String? presetName,
    List<double>? gainsDb,
    bool? studioClarityEnabled,
    String? clarityPresetKey,
  }) {
    return EqualizerState(
      enabled: enabled ?? this.enabled,
      presetName: presetName ?? this.presetName,
      gainsDb: gainsDb ?? this.gainsDb,
      studioClarityEnabled: studioClarityEnabled ?? this.studioClarityEnabled,
      clarityPresetKey: clarityPresetKey ?? this.clarityPresetKey,
    );
  }

  /// Active ClarityPreset descriptor.
  ClarityPreset get clarityPreset => ClarityPresets.byKey(clarityPresetKey);

  /// Combined curve with Studio Master Clarity trims factored in.
  List<double> get combinedGainsDb {
    return List.generate(eqBandFreqsHz.length, (i) {
      double gain = enabled ? gainsDb[i] : 0.0;
      if (studioClarityEnabled) {
        final clarity = ClarityPresets.byKey(clarityPresetKey);
        final smGain = EqualizerPresets.studioMaster.gainsDb[i];
        double trim = 0.0;
        if (i == 1) {
          trim = clarity.trimsDb[1]; // 63Hz
        } else if (i == 3) {
          trim = clarity.trimsDb[2]; // 250Hz
        } else if (i == 4) {
          trim = clarity.trimsDb[3]; // 500Hz
        } else if (i == 6 || i == 7) {
          trim = clarity.trimsDb[4]; // 2k-4k presence
        } else if (i >= 8) {
          trim = clarity.trimsDb[5]; // 8k-16k air
        }
        gain += (smGain + trim);
      }
      return gain.clamp(-eqMaxGainDb, eqMaxGainDb);
    });
  }

  /// Whether any audio filtering is active (EQ enabled or Studio Clarity active).
  bool get isProcessingActive => enabled || studioClarityEnabled;
}
