import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';

import '../../ui/theme/tokens.dart';
import 'output_path_status.dart';

/// Compact WinUI 3 stream-path summary for Settings.
class WaveStreamPathPanel extends StatelessWidget {
  final OutputPathStatus path;
  const WaveStreamPathPanel({super.key, required this.path});

  @override
  Widget build(BuildContext context) {
    final secondary = waveTextSecondary(context);
    Widget row(String key, String value) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            SizedBox(
              width: 80,
              child: Text(
                key,
                style: WaveType.overline.copyWith(color: secondary),
              ),
            ),
            Expanded(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: WaveType.meta,
              ),
            ),
          ],
        ),
      );
    }

    final statusColor =
        path.bitPerfect ? WaveColors.success : WaveColors.warn;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        row('Source', path.sourceLabel),
        row('Output', path.outputLabel),
        row(
          Platform.isWindows ? 'WASAPI' : 'Mode',
          path.exclusiveActive ? 'Exclusive' : 'Shared',
        ),
        row(
          'Mixer',
          path.exclusiveActive ? 'Bypassed' : 'In path',
        ),
        row(
          'DSP',
          path.dspActive || path.peqActive ? 'Active' : 'Bypassed',
        ),
        row(
          'Volume',
          path.hardwareVolume
              ? 'DAC hardware'
              : (path.softwareVolume ? 'Software' : 'Unity'),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: statusColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            path.bitPerfect ? '✓ Bit-Perfect stream active' : path.reason.label,
            style: WaveType.meta.copyWith(
              fontWeight: FontWeight.w600,
              color: statusColor,
            ),
          ),
        ),
        if (path.error != null) ...[
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: WaveColors.danger.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              path.error!,
              style: WaveType.meta.copyWith(
                fontWeight: FontWeight.w600,
                color: WaveColors.danger,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
