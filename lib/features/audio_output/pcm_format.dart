/// PCM format used for WASAPI exclusive negotiation.
class PcmFormat {
  final int sampleRateHz;
  final int bitDepth;
  final int channels;

  const PcmFormat({
    required this.sampleRateHz,
    required this.bitDepth,
    this.channels = 2,
  });

  double get sampleRateKhz => sampleRateHz / 1000.0;

  String get label => '$bitDepth-bit / ${rateLabel(sampleRateHz)}';

  static String rateLabel(int hz) {
    if (hz % 1000 == 0) return '${hz ~/ 1000} kHz';
    final k = hz / 1000.0;
    return '${k.toStringAsFixed(1)} kHz';
  }

  bool matches(PcmFormat other) =>
      sampleRateHz == other.sampleRateHz &&
      bitDepth == other.bitDepth &&
      channels == other.channels;

  factory PcmFormat.fromJson(Map<dynamic, dynamic> json) => PcmFormat(
        sampleRateHz: (json['sampleRateHz'] as num?)?.toInt() ?? 0,
        bitDepth: (json['bitDepth'] as num?)?.toInt() ?? 0,
        channels: (json['channels'] as num?)?.toInt() ?? 2,
      );

  Map<String, Object> toJson() => {
        'sampleRateHz': sampleRateHz,
        'bitDepth': bitDepth,
        'channels': channels,
      };

  @override
  bool operator ==(Object other) =>
      other is PcmFormat && matches(other);

  @override
  int get hashCode => Object.hash(sampleRateHz, bitDepth, channels);

  @override
  String toString() => label;
}

PcmFormat pcmFromStream({
  required int bitDepth,
  required double samplingRateKhz,
  int channels = 2,
}) {
  final hz = (samplingRateKhz * 1000).round();
  return PcmFormat(
    sampleRateHz: hz <= 0 ? 44100 : hz,
    bitDepth: bitDepth <= 0 ? 16 : bitDepth,
    channels: channels,
  );
}

int bitDepthFromMpvFormat(String? format, {String? forcedFormat}) {
  if (format == null || format.isEmpty) return 0;
  final f = format.toLowerCase();
  if (f.contains('float') || f.contains('dbl') || f.contains('double')) {
    return 0;
  }
  if (f.contains('s24') || f.contains('24')) return 24;
  if (f.contains('s16') || f.contains('16')) return 16;
  if (f.contains('s32') || f.contains('32')) {
    // WASAPI 24-bit exclusive is almost always a 32-bit container.
    if (forcedFormat == 's24') return 24;
    return 32;
  }
  if (f.contains('s8') || f.contains('u8')) return 8;
  return 0;
}

bool mpvFormatIsFloat(String? format) {
  if (format == null || format.isEmpty) return false;
  final f = format.toLowerCase();
  return f.contains('float') || f.contains('dbl') || f.contains('double');
}

String mpvSampleFormat(int bitDepth) {
  switch (bitDepth) {
    case 16:
      return 's16';
    case 24:
      return 's24';
    case 32:
      return 's32';
    default:
      return bitDepth > 24 ? 's32' : 's16';
  }
}

PcmFormat? pcmFromMpvOutParams(
  String raw, {
  String? forcedFormat,
  int channels = 2,
}) {
  if (raw.isEmpty) return null;
  final formatMatch = RegExp(r'format=([^\s,}]+)').firstMatch(raw);
  final rateMatch = RegExp(r'samplerate=(\d+)').firstMatch(raw);
  final chMatch = RegExp(r'channel-count=(\d+)').firstMatch(raw);
  final format = formatMatch?.group(1);
  if (mpvFormatIsFloat(format)) return null;
  final rate = int.tryParse(rateMatch?.group(1) ?? '') ?? 0;
  if (rate <= 0) return null;
  final depth = bitDepthFromMpvFormat(format, forcedFormat: forcedFormat);
  if (depth <= 0) return null;
  final ch = int.tryParse(chMatch?.group(1) ?? '') ?? channels;
  return PcmFormat(
    sampleRateHz: rate,
    bitDepth: depth,
    channels: ch <= 0 ? 2 : ch,
  );
}
