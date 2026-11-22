import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../features/library/local_music_library.dart';
import '../../features/search/shared_providers.dart';
import '../components/buttons.dart';
import '../components/states.dart';
import '../theme/tokens.dart';

/// Music folders the Library indexes (moved here from the Playlists page).
/// Files play in place and are never uploaded.
class LibraryFoldersView extends ConsumerWidget {
  const LibraryFoldersView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watching the scan state rebuilds this after add / forget / rescan,
    // which is when the folder list in the database changes.
    final scan = ref.watch(localScanProvider);
    final folders = ref.watch(databaseProvider).localFolders();
    final busy = scan.running;
    final library = ref.read(localMusicLibraryProvider);

    Future<void> add() async {
      final path = await FilePicker.getDirectoryPath(
        dialogTitle: 'Add a music folder',
      );
      if (path == null || path.trim().isEmpty) return;
      await library.addFolder(path.trim());
    }

    return ListView(
      padding: waveDockPadding(context, const EdgeInsets.fromLTRB(24, 16, 24, 24)),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                busy
                    ? scan.label
                    : (scan.label.isEmpty
                        ? 'Songs in these folders appear in your Library. '
                            'They stay on this PC and are never uploaded.'
                        : scan.label),
                style: WaveType.meta.copyWith(color: waveTextSecondary(context)),
              ),
            ),
            if (busy) ...[
              const SizedBox(
                width: 16,
                height: 16,
                child: ProgressRing(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
            ],
            WaveGhostButton(
              label: 'Rescan',
              icon: FluentIcons.refresh,
              onPressed: busy || folders.isEmpty ? null : library.rescan,
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: busy ? null : add,
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(FluentIcons.add, size: 12),
                  SizedBox(width: 8),
                  Text('Add folder'),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (folders.isEmpty)
          WaveEmpty(
            icon: FluentIcons.folder_open,
            title: 'No music folders',
            subtitle: 'Add a folder with your music files (MP3, FLAC, M4A, '
                'OGG, Opus, WAV, AAC) to build your Library.',
            actionLabel: busy ? null : 'Add folder',
            onAction: busy ? null : add,
          )
        else
          for (final folder in folders)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
              decoration: BoxDecoration(
                color: waveSurface(context),
                borderRadius: WaveRadius.controlsRadius,
                border: Border.all(color: waveDivider(context)),
              ),
              child: Row(
                children: [
                  Icon(FluentIcons.folder,
                      size: 16, color: waveTextSecondary(context)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      folder,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: WaveType.trackTitle,
                    ),
                  ),
                  WaveGhostButton(
                    label: 'Open',
                    icon: FluentIcons.open_folder_horizontal,
                    onPressed: () => launchUrl(Uri.file(folder)),
                  ),
                  WaveGhostButton(
                    label: 'Remove',
                    onPressed: busy ? null : () => library.forgetFolder(folder),
                  ),
                ],
              ),
            ),
      ],
    );
  }
}
