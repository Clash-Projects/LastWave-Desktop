import 'package:fluent_ui/fluent_ui.dart';

/// Elevation — restrained Fluent shadows.
///
/// Content (L0) has no shadow. Chrome (L1) none. Panels (L2) one soft
/// 32px shadow. Flyouts (L3) layered shadow + 1px tonal ring.
class LwElevation {
  LwElevation._();

  static List<BoxShadow> get none => const [];

  static List<BoxShadow> get panel => [
        const BoxShadow(
          color: Color(0x73000000),
          blurRadius: 32,
          offset: Offset(-12, 0),
        ),
      ];

  static List<BoxShadow> get artwork => [
        const BoxShadow(
          color: Color(0x73000000),
          blurRadius: 32,
          offset: Offset(0, 12),
        ),
      ];

  static List<BoxShadow> get flyout => [
        const BoxShadow(
          color: Color(0x66000000),
          blurRadius: 16,
          offset: Offset(0, 8),
        ),
        const BoxShadow(
          color: Color(0x33000000),
          blurRadius: 4,
          offset: Offset(0, 2),
        ),
      ];

  static List<BoxShadow> get transport => [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.35),
          blurRadius: 8,
          offset: const Offset(0, 2),
        ),
      ];
}
