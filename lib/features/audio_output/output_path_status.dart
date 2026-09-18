import 'dart:io';

import 'pcm_format.dart';

enum BitPerfectReason {
  bitPerfect,
  dspActive,
  peqActive,
  softwareVolume,
  resampling,
  formatConversion,
  exclusiveUnavailable,
  deviceUnavailable,
  formatUnsupported,
  sharedMode,
  speedNotUnity,
  crossfadeActive;

  String get label => switch (this) {
        BitPerfectReason.bitPerfect => 'Bit-Perfect',
        BitPerfectReason.dspActive =>
          'Bit-Perfect unavailable — DSP is active.',
        BitPerfectReason.peqActive =>
          'Bit-Perfect unavailable — PEQ is active.',
        BitPerfectReason.softwareVolume =>
          'Software — Bit-Perfect unavailable',
        BitPerfectReason.resampling =>
          'Bit-Perfect unavailable — resampling.',
        BitPerfectReason.formatConversion => 'Native format unavailable',
        BitPerfectReason.exclusiveUnavailable =>
          'WASAPI Exclusive unavailable',
        BitPerfectReason.deviceUnavailable => 'Output device unavailable',
        BitPerfectReason.formatUnsupported => 'Native format unavailable',
        BitPerfectReason.sharedMode => Platform.isWindows
            ? 'WASAPI Shared — mixer in path'
            : 'Shared — mixer in path',
        BitPerfectReason.speedNotUnity =>
          'Bit-Perfect unavailable — playback speed ≠ 1.0.',
        BitPerfectReason.crossfadeActive =>
          'Bit-Perfect unavailable — crossfade is enabled.',
      };
}

enum WasapiShareMode { exclusive, shared }

class FormatDecision {
  final PcmFormat source;
  final PcmFormat? output;
  final bool nativeMatch;
  final bool resampling;
  final bool formatConversion;
  final String note;

  const FormatDecision({
    required this.source,
    required this.output,
    required this.nativeMatch,
    required this.resampling,
    required this.formatConversion,
    this.note = '',
  });
}

class OutputPathStatus {
  final String deviceName;
  final String deviceId;
  final WasapiShareMode mode;
  final bool exclusiveRequested;
  final bool exclusiveActive;
  final PcmFormat? source;
  final PcmFormat? output;
  final bool resampling;
  final bool dspActive;
  final bool peqActive;
  final bool softwareVolume;
  final bool hardwareVolume;
  final bool crossfade;
  final double speed;
  final BitPerfectReason reason;
  final String? error;

  const OutputPathStatus({
    this.deviceName = 'System default',
    this.deviceId = '',
    this.mode = WasapiShareMode.shared,
    this.exclusiveRequested = false,
    this.exclusiveActive = false,
    this.source,
    this.output,
    this.resampling = false,
    this.dspActive = false,
    this.peqActive = false,
    this.softwareVolume = true,
    this.hardwareVolume = false,
    this.crossfade = false,
    this.speed = 1.0,
    this.reason = BitPerfectReason.sharedMode,
    this.error,
  });

  bool get bitPerfect => reason == BitPerfectReason.bitPerfect;

  String get outputLabel => output?.label ?? '—';
  String get sourceLabel => source?.label ?? '—';

  OutputPathStatus copyWith({
    String? deviceName,
    String? deviceId,
    WasapiShareMode? mode,
    bool? exclusiveRequested,
    bool? exclusiveActive,
    PcmFormat? source,
    PcmFormat? output,
    bool? resampling,
    bool? dspActive,
    bool? peqActive,
    bool? softwareVolume,
    bool? hardwareVolume,
    bool? crossfade,
    double? speed,
    BitPerfectReason? reason,
    String? error,
    bool clearError = false,
  }) =>
      OutputPathStatus(
        deviceName: deviceName ?? this.deviceName,
        deviceId: deviceId ?? this.deviceId,
        mode: mode ?? this.mode,
        exclusiveRequested: exclusiveRequested ?? this.exclusiveRequested,
        exclusiveActive: exclusiveActive ?? this.exclusiveActive,
        source: source ?? this.source,
        output: output ?? this.output,
        resampling: resampling ?? this.resampling,
        dspActive: dspActive ?? this.dspActive,
        peqActive: peqActive ?? this.peqActive,
        softwareVolume: softwareVolume ?? this.softwareVolume,
        hardwareVolume: hardwareVolume ?? this.hardwareVolume,
        crossfade: crossfade ?? this.crossfade,
        speed: speed ?? this.speed,
        reason: reason ?? this.reason,
        error: clearError ? null : (error ?? this.error),
      );
}
