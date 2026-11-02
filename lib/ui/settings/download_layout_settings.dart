import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/prefs.dart';
import '../../features/downloads/download_manager.dart';
import '../../features/downloads/folder_layout.dart';
import '../components/buttons.dart';
import '../components/select.dart';
import '../theme/tokens.dart';

/// Settings → Downloads folder layout. New files only, until Reorganize.
class DownloadLayoutSettings extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const DownloadLayoutSettings({super.key, required this.onUpdate});

  Future<void> _reorganize(BuildContext context, WidgetRef ref) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => ContentDialog(
        title: const Text('Reorganize downloads'),
        content: const Text(
          'Move downloaded files into the selected folders? '
          'This does not run on its own.',
        ),
        actions: [
          WaveButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          WaveFilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Reorganize'),
          ),
        ],
      ),
    );
    if (go != true || !context.mounted) return;
    final result =
        await ref.read(downloadManagerProvider.notifier).reorganize();
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => ContentDialog(
        title: const Text('Reorganize downloads'),
        content: Text('Moved ${result.moved}. Skipped ${result.skipped}.'),
        actions: [
          WaveFilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = DownloadFolderLayout.fromId(
      ref.watch(prefsProvider).downloadStructure,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Folder layout', style: WaveType.trackTitle),
        const SizedBox(height: 4),
        Text(
          'Applies to new downloads. Existing files stay where they are '
          'until you reorganize.',
          style: WaveType.meta.copyWith(color: waveTextSecondary(context)),
        ),
        const SizedBox(height: 8),
        WaveSelect<DownloadFolderLayout>(
          expanded: true,
          value: current,
          options: [
            for (final layout in DownloadFolderLayout.values)
              WaveSelectOption(
                value: layout,
                label: layout.label,
                hint: layout.example,
              ),
          ],
          onChanged: (layout) =>
              onUpdate((p) => p.setDownloadStructure(layout.id)),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: WaveButton(
            onPressed: () => _reorganize(context, ref),
            child: const Text('Reorganize existing downloads'),
          ),
        ),
      ],
    );
  }
}
