import 'package:fluent_ui/fluent_ui.dart';

import '../design_system/components.dart';
import '../ui/components/buttons.dart';

/// Thin shim over [WaveChip]: quality pill (HI-RES / LOSSLESS / …).
///
/// Hi-res / lossless labels render highlighted; everything else quiet.
/// Keeps the [QualityBadge] constructor for call-site compatibility.
class QualityBadge extends StatelessWidget {
  final String label;
  const QualityBadge({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    final isHiRes = label == 'HI-RES';
    final isLossless = label.contains('LOSSLESS');
    return WaveChip(
      label: label,
      highlight: isHiRes || isLossless,
    );
  }
}

/// Back-compat alias used by older call sites.
class LwBadgeAlias extends LwBadge {
  const LwBadgeAlias({super.key, required super.label});
}
