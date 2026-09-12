import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Desktop connectivity monitor (no platform plugin needed).
///
/// Polls a lightweight DNS lookup; exposes [isOnline] as a StateFlow-like
/// [StateNotifier], mirroring Android `NetworkMonitor.isOnline`.
class NetworkMonitor extends StateNotifier<bool> {
  Timer? _timer;
  bool _disposed = false;

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
    } catch (_) {
      try {
        final fallback = await InternetAddress.lookup('music.youtube.com')
            .timeout(const Duration(seconds: 5));
        _emit(fallback.isNotEmpty);
      } catch (_) {
        _emit(false);
      }
    }
  }

  bool isCurrentlyConnected() => state;

  void _emit(bool value) {
    if (!_disposed && state != value) state = value;
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
