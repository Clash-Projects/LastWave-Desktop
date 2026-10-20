import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Consecutive failed probe rounds required before reporting offline.
/// A single failed round holds the last state (reads as "unknown",
/// not "offline" — one DNS blip or slow lookup must never raise the
/// bar); recovery is immediate on the next success.
const int offlineStrikeThreshold = 2;

/// Pure flip logic behind [NetworkMonitor]: reached-HTTP resets the
/// count and reports online, silence accumulates strikes and reports
/// offline only at [offlineStrikeThreshold]. Unit tested; the
/// timer/`HttpClient` shell around it is not.
class ConnectivityStrikes {
  int _failures = 0;

  int get failures => _failures;

  bool recordResult({required bool responded}) {
    if (responded) {
      _failures = 0;
      return true;
    }
    _failures++;
    return _failures < offlineStrikeThreshold;
  }
}

/// Desktop connectivity monitor (no platform plugin needed).
///
/// Probes real HTTP reachability — against
/// OS-standard captive-portal endpoints on infra the app already
/// streams from (Google edge primary, Apple secondary). Any HTTP
/// response proves packets flow (even a 5xx or portal intercept — a
/// host outage is not a device outage); only silence (DNS/socket
/// failure, timeout) counts a strike, and it takes two consecutive
/// strikes to flip offline. Exposes [isOnline] as a StateFlow-like
/// [StateNotifier], mirroring Android `NetworkMonitor.isOnline`.
class NetworkMonitor extends StateNotifier<bool> {
  Timer? _timer;
  bool _disposed = false;
  bool _checking = false;
  bool _visible = true;
  final HttpClient _client;
  final ConnectivityStrikes _strikes = ConnectivityStrikes();

  static const _probeTimeout = Duration(seconds: 5);
  static const _foregroundInterval = Duration(seconds: 15);
  // Minimized / tray-hidden: nothing on screen consumes the flag, so a
  // DNS+TCP wake every 15s is pure waste. A minute still flips the
  // offline bar promptly, and [setVisible] probes immediately on restore
  // so the flag is never stale when it can be seen. Playback failure
  // handling does not consult this flag, so nothing audible depends on it.
  static const _backgroundInterval = Duration(minutes: 1);
  static final _primary =
      Uri.parse('https://www.youtube.com/generate_204');
  static final _secondary = Uri.parse(
      'https://www.apple.com/library/test/success.html');

  NetworkMonitor()
      : _client = HttpClient()
          ..connectionTimeout = _probeTimeout
          ..idleTimeout = const Duration(seconds: 10),
        super(true) {
    _check();
    _restartTimer();
  }

  /// Window visibility gate. Backs the probe cadence off while minimized
  /// or tray-hidden and re-probes immediately on restore.
  void setVisible(bool visible) {
    if (_visible == visible) return;
    _visible = visible;
    _restartTimer();
    if (visible) unawaited(_check());
  }

  void _restartTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(
      _visible ? _foregroundInterval : _backgroundInterval,
      (_) => _check(),
    );
  }

  /// True when the URL answers with any HTTP response. Drained so the
  /// persistent connection is reusable; never throws.
  Future<bool> _probe(Uri url) async {
    try {
      final request =
          await _client.getUrl(url).timeout(_probeTimeout);
      final response =
          await request.close().timeout(_probeTimeout);
      await response.drain().timeout(_probeTimeout);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _check() async {
    // One probe round at a time: the restore path can now fire an
    // immediate check on top of a scheduled one, and two overlapping
    // rounds would double-count strikes (flipping offline early).
    if (_disposed || _checking) return;
    _checking = true;
    try {
      // Secondary runs only when the primary stays silent.
      final responded =
          await _probe(_primary) || await _probe(_secondary);
      _emit(_strikes.recordResult(responded: responded));
    } finally {
      _checking = false;
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
    _client.close(force: true);
    super.dispose();
  }
}

final networkMonitorProvider =
    StateNotifierProvider<NetworkMonitor, bool>((ref) {
  final monitor = NetworkMonitor();
  ref.onDispose(monitor.dispose);
  return monitor;
});
