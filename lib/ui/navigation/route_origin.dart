import 'package:fluent_ui/fluent_ui.dart';

/// Where the gesture that opened the current route came from.
///
/// The shell records the last pointer release (one `Listener` around the
/// whole chrome) and an anchored page builder consumes it while it builds, so
/// the destination scales up out of the point the user pressed instead of
/// cutting in. An anchor nobody consumed within [ttl] is dropped, so a deep
/// link, global hotkey, command-palette jump or restored session can never
/// inherit a stale one — those fall back to the plain crossfade.
///
/// Only the pointer position is carried, not the tapped widget's rect: cards
/// hand their taps straight to `context.go` from dozens of call sites, a
/// global key per card would be far more invasive, and for any card actually
/// pressed the two coincide (the press lands inside the card).
class WaveRouteOrigin {
  WaveRouteOrigin._(this.position, this.recordedAt);

  /// Pointer position in window coordinates.
  final Offset position;

  final DateTime recordedAt;

  /// How long a recorded anchor stays eligible for consumption.
  static const Duration ttl = Duration(milliseconds: 600);

  static WaveRouteOrigin? _last;

  /// Called from the shell's single pointer-down listener.
  static void record(Offset position) {
    _last = WaveRouteOrigin._(position, DateTime.now());
  }

  /// Consumes the recorded anchor if it is fresh; null otherwise.
  static WaveRouteOrigin? consume() {
    final last = _last;
    _last = null;
    if (last == null) return null;
    if (DateTime.now().difference(last.recordedAt) > ttl) return null;
    return last;
  }

  /// [position] as a Flutter alignment (-1..1) inside [size].
  ///
  /// Window-relative rather than content-relative: the rail/title/dock insets
  /// would shift the anchor by a few pixels under a 6% scale, which is not
  /// visible, whereas measuring the content box would push the anchor back
  /// into the shell's layout.
  Alignment alignmentIn(Size size) {
    if (size.width <= 0 || size.height <= 0) return Alignment.center;
    return Alignment(
      (2 * position.dx / size.width - 1).clamp(-1.0, 1.0),
      (2 * position.dy / size.height - 1).clamp(-1.0, 1.0),
    );
  }
}
