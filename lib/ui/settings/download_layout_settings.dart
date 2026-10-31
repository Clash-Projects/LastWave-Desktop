import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/prefs.dart';
import '../../features/downloads/download_manager.dart';
import '../../features/downloads/folder_layout.dart';
import '../../l10n/app_language.dart';
import '../components/buttons.dart';
import '../components/select.dart';
import '../theme/tokens.dart';
import 'settings_search.dart';

/// Settings → Downloads folder layout. New files only, until Reorganize.
class DownloadLayoutSettings extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const DownloadLayoutSettings({super.key, required this.onUpdate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(shellStringsProvider);
    final current = DownloadFolderLayout.fromId(
      ref.watch(prefsProvider).downloadStructure,
    );
    String label(DownloadFolderLayout layout) => switch (layout) {
          DownloadFolderLayout.flat => strings('folderFlat'),
          DownloadFolderLayout.artistAlbum => strings('folderArtistAlbum'),
          DownloadFolderLayout.artistYearAlbum => strings('folderArtistYear'),
          DownloadFolderLayout.albumOnly => strings('folderAlbum'),
          DownloadFolderLayout.yearAlbum => strings('folderYearAlbum'),
        };
    return SettingsTarget(
      id: 'downloads.layout',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(strings('folderLayout'), style: WaveType.sectionTitle),
          const SizedBox(height: 6),
          Text(
            strings('reorganizeHint'),
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
                  label: label(layout),
                  hint: layout.example,
                ),
            ],
            onChanged: (layout) =>
                onUpdate((p) => p.setDownloadStructure(layout.id)),
          ),
          const SizedBox(height: 8),
          WaveButton(
            onPressed: () async {
              final go = await showDialog<bool>(
                context: context,
                builder: (context) => ContentDialog(
                  title: Text(strings('reorganize')),
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
                      child: Text(strings('reorganize')),
                    ),
                  ],
                ),
              );
              if (go != true || !context.mounted) return;
              final result = await ref
                  .read(downloadManagerProvider.notifier)
                  .reorganize();
              if (!context.mounted) return;
              await showDialog<void>(
                context: context,
                builder: (context) => ContentDialog(
                  title: Text(strings('reorganize')),
                  content: Text(
                    'Moved ${result.moved}. Skipped ${result.skipped}.',
                  ),
                  actions: [
                    WaveFilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('OK'),
                    ),
                  ],
                ),
              );
            },
            child: Text(strings('reorganize')),
          ),
        ],
      ),
    );
  }
}
