import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'net_log.dart';

/// Desktop connectivity monitor (no platform plugin needed).
///
/// Polls a lightweight DNS lookup; exposes [isOnline] as a StateFlow-like
/// [StateNotifier], mirroring Android `NetworkMonitor.isOnline`.
///
/// The banner this drives used to be the only symptom users could
/// describe, and a failed lookup here was swallowed by `catch (_)` with
/// nothing recorded anywhere. Failures now go to [NetLog], and the first
/// offline episode of each outage runs a full [NetProbe] so "offline" can
/// be split into DNS / HTTPS / redirect / app-endpoint.
class NetworkMonitor extends StateNotifier<bool> {
  Timer? _timer;
  bool _disposed = false;
  bool _probeRan = false;

  NetworkMonitor() : super(true) {
    _check();
    _timer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _check(),
    );
  }

  Future<void> _check() async {
    try {
      final result = await InternetAddress.lookup('ws.audioscrobbler.com')
          .timeout(const Duration(seconds: 5));
      _emit(result.isNotEmpty);
    } catch (e) {
      NetLog.write('DNS FAIL ws.audioscrobbler.com ${e.runtimeType}');
      try {
        final fallback = await InternetAddress.lookup('music.youtube.com')
            .timeout(const Duration(seconds: 5));
        _emit(fallback.isNotEmpty);
      } catch (e2) {
        NetLog.write('DNS FAIL music.youtube.com ${e2.runtimeType}');
        _emit(false);
      }
    }
  }

  bool isCurrentlyConnected() => state;

  void _emit(bool value) {
    if (_disposed || state == value) return;
    state = value;
    // Probe once per outage, not once per 15s poll.
    if (value) {
      _probeRan = false;
    } else {
      unawaited(_runProbeOnce());
    }
  }

  Future<void> _runProbeOnce() async {
    if (_probeRan || _disposed) return;
    _probeRan = true;
    try {
      await NetProbe.runAndLog();
    } catch (e) {
      NetLog.write('PROBE aborted ${e.runtimeType}');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

final networkMonitorProvider =
    StateNotifierProvider<NetworkMonitor, bool>((ref) {
  final monitor = NetworkMonitor();
  ref.onDispose(monitor.dispose);
  return monitor;
});
