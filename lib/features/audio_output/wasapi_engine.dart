import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/services.dart';

import 'dac_device.dart';

/// Dart client for the isolated Windows WASAPI engine.
///
/// The engine enumerates endpoints, probes exclusive PCM, and drives
/// hardware volume. PCM render stays in libmpv (`ao=wasapi`).
class WasapiEngine {
  static const _channel = MethodChannel('lastwave/wasapi');
  static const _events = EventChannel('lastwave/wasapi/events');

  const WasapiEngine();

  bool get isSupported => Platform.isWindows;

  Stream<Map<String, dynamic>> get deviceEvents {
    if (!isSupported) return const Stream.empty();
    return _events.receiveBroadcastStream().map((event) {
      if (event is Map) {
        return event.map((k, v) => MapEntry(k.toString(), v));
      }
      return <String, dynamic>{};
    });
  }

  Future<List<DacDevice>> enumerateDevices() async {
    if (!isSupported) return const [];
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('enumerateDevices');
      if (raw == null) return const [];
      return raw
          .whereType<Map>()
          .map(DacDevice.fromJson)
          .toList();
    } on PlatformException catch (e) {
      wasapiLog('enumerateDevices failed: ${e.message}');
      return const [];
    }
  }

  Future<DacDevice?> probeDevice(String id) async {
    if (!isSupported) return null;
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'probeDevice',
        {'id': id},
      );
      if (raw == null) return null;
      return DacDevice.fromJson(raw);
    } on PlatformException catch (e) {
      wasapiLog('probeDevice failed: ${e.message}');
      return null;
    }
  }

  Future<bool> setHardwareVolume(String id, double scalar) async {
    if (!isSupported) return false;
    try {
      await _channel.invokeMethod<void>('setHardwareVolume', {
        'id': id,
        'scalar': scalar.clamp(0.0, 1.0),
      });
      return true;
    } on PlatformException catch (e) {
      wasapiLog('setHardwareVolume failed: ${e.message}');
      return false;
    }
  }

  Future<double?> getHardwareVolume(String id) async {
    if (!isSupported) return null;
    try {
      final v = await _channel.invokeMethod<num>('getHardwareVolume', {'id': id});
      return v?.toDouble();
    } on PlatformException catch (e) {
      wasapiLog('getHardwareVolume failed: ${e.message}');
      return null;
    }
  }

  Future<String> defaultDeviceId() async {
    if (!isSupported) return '';
    try {
      return await _channel.invokeMethod<String>('defaultDeviceId') ?? '';
    } on PlatformException catch (e) {
      wasapiLog('defaultDeviceId failed: ${e.message}');
      return '';
    }
  }
}

void wasapiLog(String message) {
  developer.log(message, name: 'WASAPI');
}
