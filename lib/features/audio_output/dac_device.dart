import 'pcm_format.dart';

class DacDevice {
  final String id;
  final String name;
  final String manufacturer;
  final String enumerator;
  final bool isDefault;
  final bool exclusiveSupported;
  final bool hardwareVolume;
  final List<PcmFormat> formats;

  const DacDevice({
    required this.id,
    required this.name,
    this.manufacturer = '',
    this.enumerator = '',
    this.isDefault = false,
    this.exclusiveSupported = false,
    this.hardwareVolume = false,
    this.formats = const [],
  });

  String get displayName {
    if (manufacturer.isNotEmpty &&
        !name.toLowerCase().contains(manufacturer.toLowerCase())) {
      return '$manufacturer · $name';
    }
    return name;
  }

  String get mpvDeviceName =>
      id.isEmpty ? 'auto' : (id.startsWith('wasapi/') ? id : 'wasapi/$id');

  bool supports(PcmFormat format) =>
      formats.any((f) => f.matches(format));

  String get supportedSummary {
    if (formats.isEmpty) return 'No exclusive PCM formats reported';
    final byDepth = <int, List<int>>{};
    for (final f in formats) {
      byDepth.putIfAbsent(f.bitDepth, () => []).add(f.sampleRateHz);
    }
    final depths = byDepth.keys.toList()..sort();
    return depths.map((d) {
      final rates = (byDepth[d]!..sort()).map(PcmFormat.rateLabel).join(' / ');
      return '$d-bit: $rates';
    }).join('\n');
  }

  factory DacDevice.fromJson(Map<dynamic, dynamic> json) {
    final raw = json['formats'];
    final formats = <PcmFormat>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) formats.add(PcmFormat.fromJson(item));
      }
    }
    return DacDevice(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? 'Audio device',
      manufacturer: json['manufacturer']?.toString() ?? '',
      enumerator: json['enumerator']?.toString() ?? '',
      isDefault: json['isDefault'] == true,
      exclusiveSupported: json['exclusiveSupported'] == true,
      hardwareVolume: json['hardwareVolume'] == true,
      formats: formats,
    );
  }
}
