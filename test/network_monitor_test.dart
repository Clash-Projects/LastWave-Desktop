import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/network/network_monitor.dart';

void main() {
  group('ConnectivityStrikes', () {
    test('fresh monitor reports online on success', () {
      final strikes = ConnectivityStrikes();
      expect(
          strikes.recordResult(responded: true), isTrue);
      expect(strikes.failures, 0);
    });

    test('a single failure holds online (unknown, not offline)',
        () {
      final strikes = ConnectivityStrikes();
      expect(
          strikes.recordResult(responded: false), isTrue);
      expect(strikes.failures, 1);
    });

    test('two consecutive failures flip offline', () {
      final strikes = ConnectivityStrikes();
      strikes.recordResult(responded: false);
      expect(
          strikes.recordResult(responded: false), isFalse);
      expect(strikes.failures, 2);
    });

    test('success after one failure resets the count', () {
      final strikes = ConnectivityStrikes();
      strikes.recordResult(responded: false);
      expect(
          strikes.recordResult(responded: true), isTrue);
      // Needs two fresh failures again, not one.
      expect(
          strikes.recordResult(responded: false), isTrue);
      expect(
          strikes.recordResult(responded: false), isFalse);
    });

    test('recovers immediately on the next success', () {
      final strikes = ConnectivityStrikes();
      strikes.recordResult(responded: false);
      strikes.recordResult(responded: false);
      expect(
          strikes.recordResult(responded: true), isTrue);
      expect(strikes.failures, 0);
    });

    test('further failures stay offline', () {
      final strikes = ConnectivityStrikes();
      strikes.recordResult(responded: false);
      strikes.recordResult(responded: false);
      expect(
          strikes.recordResult(responded: false), isFalse);
    });

    test('threshold is two strikes', () {
      expect(offlineStrikeThreshold, 2);
    });
  });
}
