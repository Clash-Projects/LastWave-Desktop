/// Built-in headphone corrections.
///
/// A handful of well-known models, expressed as peaking filters mpv's
/// lavfi equalizer can run. These sit beside the 10-band EQ. They are
/// simplified curves in the direction of a Harman-style target, not a
/// download of the AutoEQ database and not a lab measurement of the
/// pair on your head.
class HeadphoneBand {
  final double hz;
  final double q;
  final double gainDb;

  const HeadphoneBand(this.hz, this.q, this.gainDb);
}

class HeadphoneProfile {
  final String id;
  final String name;
  final String description;
  final double preampDb;
  final List<HeadphoneBand> bands;

  const HeadphoneProfile({
    required this.id,
    required this.name,
    required this.description,
    this.preampDb = 0,
    this.bands = const [],
  });

  bool get isOff => id == 'off' || bands.isEmpty;

  /// Extra lavfi graph. Empty when the profile is Off.
  String get lavfiFilter {
    if (isOff) return '';
    final parts = <String>[
      for (final band in bands)
        'equalizer=f=${band.hz.toStringAsFixed(0)}'
        ':t=q:w=${band.q.toStringAsFixed(2)}'
        ':g=${band.gainDb.toStringAsFixed(1)}',
      if (preampDb.abs() >= 0.05) 'volume=${preampDb.toStringAsFixed(1)}dB',
    ];
    return 'lavfi=[${parts.join(',')}]';
  }
}

class HeadphoneProfiles {
  HeadphoneProfiles._();

  static const off = HeadphoneProfile(
    id: 'off',
    name: 'Off',
    description: 'No headphone correction.',
  );

  static const wh1000xm5 = HeadphoneProfile(
    id: 'sony-wh-1000xm5',
    name: 'Sony WH-1000XM5',
    description: 'Less sub-bass, a little more presence.',
    preampDb: -1,
    bands: [
      HeadphoneBand(45, 0.70, -4.0),
      HeadphoneBand(180, 0.90, -1.5),
      HeadphoneBand(2800, 1.20, 2.5),
      HeadphoneBand(6500, 2.00, 1.0),
    ],
  );

  static const qcUltra = HeadphoneProfile(
    id: 'bose-qc-ultra',
    name: 'Bose QC Ultra',
    description: 'Tames the bass shelf and the upper treble.',
    preampDb: -1,
    bands: [
      HeadphoneBand(55, 0.70, -3.5),
      HeadphoneBand(300, 1.00, -1.0),
      HeadphoneBand(3200, 1.00, 2.0),
      HeadphoneBand(8500, 2.00, -2.0),
    ],
  );

  static const airpodsMax = HeadphoneProfile(
    id: 'airpods-max',
    name: 'AirPods Max',
    description: 'Light bass cut and a softer 8 kHz region.',
    preampDb: -1,
    bands: [
      HeadphoneBand(50, 0.80, -2.5),
      HeadphoneBand(250, 1.00, -1.0),
      HeadphoneBand(3000, 1.20, 1.5),
      HeadphoneBand(7500, 2.50, -2.5),
    ],
  );

  static const hd600 = HeadphoneProfile(
    id: 'sennheiser-hd600',
    name: 'Sennheiser HD 600',
    description: 'Bass lift and a cut on the 6 kHz peak.',
    preampDb: -5.5,
    bands: [
      HeadphoneBand(105, 0.70, 5.5),
      HeadphoneBand(200, 0.80, -2.0),
      HeadphoneBand(5800, 3.00, -3.0),
      HeadphoneBand(10000, 0.70, -1.5),
    ],
  );

  static const m50x = HeadphoneProfile(
    id: 'ath-m50x',
    name: 'Audio-Technica ATH-M50x',
    description: 'Pulls back the V-shaped bass and treble.',
    preampDb: -1,
    bands: [
      HeadphoneBand(60, 0.70, -4.5),
      HeadphoneBand(300, 1.00, 2.0),
      HeadphoneBand(4000, 1.50, -2.0),
      HeadphoneBand(10000, 2.00, -3.5),
    ],
  );

  static const dt770 = HeadphoneProfile(
    id: 'dt-770',
    name: 'Beyerdynamic DT 770',
    description: 'Cuts the bass shelf and the 8 kHz spike.',
    preampDb: -1,
    bands: [
      HeadphoneBand(55, 0.70, -3.0),
      HeadphoneBand(250, 1.00, 1.0),
      HeadphoneBand(7800, 3.50, -5.0),
      HeadphoneBand(12000, 1.50, -1.5),
    ],
  );

  static const all = <HeadphoneProfile>[
    off,
    wh1000xm5,
    qcUltra,
    airpodsMax,
    hd600,
    m50x,
    dt770,
  ];

  static HeadphoneProfile byId(String? id) {
    final key = (id ?? '').trim().toLowerCase();
    for (final profile in all) {
      if (profile.id == key) return profile;
    }
    return off;
  }
}
