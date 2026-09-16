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
              width: 72,
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        row('Source', path.sourceLabel),
        row('Output', path.outputLabel),
        row(
          'WASAPI',
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
        const SizedBox(height: 6),
        Text(
          path.bitPerfect ? 'Bit-Perfect' : path.reason.label,
          style: WaveType.label.copyWith(
            color: path.bitPerfect ? WaveColors.success : WaveColors.warn,
          ),
        ),
        if (path.error != null) ...[
          const SizedBox(height: 4),
          Text(
            path.error!,
            style: WaveType.meta.copyWith(color: WaveColors.danger),
          ),
        ],
      ],
    );
  }
}
