import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/services.dart';

import '../../core/diagnostics/diagnostics_log.dart';
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
    }).handleError((error) {
      wasapiLog('deviceEvents stream error: $error');
    });
  }

  Future<List<DacDevice>> enumerateDevices() async {
    if (!isSupported) return const [];
    try {
      final raw = await _channel
          .invokeMethod<List<dynamic>>('enumerateDevices')
          .timeout(const Duration(seconds: 4));
      if (raw == null) return const [];
      return raw.whereType<Map>().map(DacDevice.fromJson).toList();
    } on TimeoutException {
      wasapiLog('enumerateDevices timed out');
      return const [];
    } on PlatformException catch (e) {
      wasapiLog('enumerateDevices failed: ${e.message}');
      return const [];
    } catch (e) {
      wasapiLog('Unexpected error in enumerateDevices: $e');
      return const [];
    }
  }

  Future<DacDevice?> probeDevice(String id) async {
    if (!isSupported || id.trim().isEmpty) return null;
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'probeDevice',
        {'id': id},
      ).timeout(const Duration(seconds: 5));

      if (raw == null) return null;
      return DacDevice.fromJson(raw);
    } on TimeoutException {
      wasapiLog('probeDevice timed out for device $id');
      return null;
    } on PlatformException catch (e) {
      wasapiLog('probeDevice failed for $id:${e.message}');
      return null;
    } catch (e) {
      wasapiLog('Unexpected error in probeDevice for $id:$e');
      return null;
    }
  }

  /// Verifies whether the specified DAC device supports a given PCM format
  /// before requesting exclusive mode from libmpv.
  Future<bool> isFormatSupported({
    required String id,
    required int sampleRate,
    required int channels,
    required int bitDepth,
  }) async {
    if (!isSupported || id.trim().isEmpty) return false;
    try {
      final supported = await _channel.invokeMethod<bool>('isFormatSupported', {
        'id': id,
        'sampleRate': sampleRate,
        'channels': channels,
        'bitDepth': bitDepth,
      }).timeout(const Duration(seconds: 3));

      return supported ?? false;
    } catch (e) {
      wasapiLog('Format check error ($sampleRate Hz, $bitDepth-bit):$e');
      return false;
    }
  }

  Future<bool> setHardwareVolume(String id, double scalar) async {
    if (!isSupported || id.trim().isEmpty) return false;
    try {
      await _channel.invokeMethod<void>('setHardwareVolume', {
        'id': id,
        'scalar': scalar.clamp(0.0, 1.0),
      }).timeout(const Duration(seconds: 2));
      return true;
    } on PlatformException catch (e) {
      wasapiLog('setHardwareVolume failed: ${e.message}');
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<double?> getHardwareVolume(String id) async {
    if (!isSupported || id.trim().isEmpty) return null;
    try {
      final v = await _channel.invokeMethod<num>('getHardwareVolume', {
        'id': id,
      }).timeout(const Duration(seconds: 2));
      return v?.toDouble();
    } on PlatformException catch (e) {
      wasapiLog('getHardwareVolume failed: ${e.message}');
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<String> defaultDeviceId() async {
    if (!isSupported) return '';
    try {
      return await _channel
              .invokeMethod<String>('defaultDeviceId')
              .timeout(const Duration(seconds: 2)) ??
          '';
    } on PlatformException catch (e) {
      wasapiLog('defaultDeviceId failed: ${e.message}');
      return '';
    } catch (_) {
      return '';
    }
  }
}

void wasapiLog(String message) {
  // Verbose: probes fire per device/format, so this only lands in the
  // exported session log when the user enables verbose logging.
  DiagnosticsLog.detail('wasapi $message');
  developer.log(message, name: 'WASAPI');
}