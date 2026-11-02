import 'dart:math' as math;

/// Filter sweep for a timed dual-deck overlap.
///
/// Frequency moves on a log curve across the overlap. Nothing here
/// detects beats, downbeats, or musical key.
class TimedMixSweep {
  TimedMixSweep._();

  static double hz(double fromHz, double toHz, double progress) {
    final t = progress.clamp(0.0, 1.0);
    final a = math.log(fromHz);
    final b = math.log(toHz);
    return math.exp(a + (b - a) * t);
  }

  /// Outgoing deck darkens as the low-pass closes.
  static String outgoing(double progress) {
    final freq = hz(16000, 180, progress).round();
    return 'lowpass=f=$freq:poles=1';
  }

  /// Incoming deck fills in as the high-pass opens.
  static String incoming(double progress) {
    final freq = hz(7000, 40, progress).round();
    return 'highpass=f=$freq:poles=1';
  }
}
