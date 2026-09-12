import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../design_system/icons.dart';

import '../../core/audio/stream_models.dart';
import '../../design_system/components.dart';
import '../../design_system/tokens.dart';
import '../player/playback_service.dart';
import 'download_manager.dart';

/// Offline library: download progress, quality badges, delete.
class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(downloadManagerProvider);
    final done =
        entries.where((e) => e.status == DownloadStatus.done);
    return ListView(
      padding: const EdgeInsets.fromLTRB(
          LwSpacing.lg, LwSpacing.lg, LwSpacing.lg, 96),
      children: [
        const Text('Downloads', style: LwType.display),
        const SizedBox(height: 4),
        Text(
          '${done.length} tracks offline · stored under Music/LastWave with synced-lyrics sidecars.',
          style: LwType.body
              .copyWith(color: LwColors.textSecondary),
        ),
        const SizedBox(height: LwSpacing.md),
        if (entries.isEmpty)
          const EmptyState(
            icon: LwIcons.download,
            title: 'No downloads yet',
            subtitle:
                'Download any track to keep it offline in full quality.',
          )
        else
          ...entries.map((e) {
            final player =
                ref.read(playbackServiceProvider.notifier);
            return ListTile(
              leading: e.status == DownloadStatus.done
                  ? const Icon(LwIcons.music,
                      color: LwColors.textSecondary)
                  : const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                          strokeWidth: 2),
                    ),
              title: Text(e.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              subtitle: e.status ==
                      DownloadStatus.downloading
                  ? LinearProgressIndicator(
                      value: e.progress > 0
                          ? e.progress
                          : null,
                    )
                  : Text(
                      e.status == DownloadStatus.error
                          ? (e.error ?? 'Failed')
                          : e.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (e.badge.isNotEmpty)
                    QualityBadge(label: e.badge),
                  if (e.status == DownloadStatus.done)
                    IconButton(
                      icon: const Icon(
                          LwIcons.play,
                          size: 16),
                      tooltip: 'Play offline file',
                      onPressed: () => player.play(
                        PlayableTrack(
                          title: e.title,
                          artist: e.artist,
                          playbackUrl: e.filePath ?? '',
                        ),
                        sourceLabel: 'Downloads',
                      ),
                    ),
                  IconButton(
                    icon: const Icon(
                        LwIcons.trash2,
                        size: 15),
                    tooltip: 'Delete download',
                    onPressed: () => ref
                        .read(downloadManagerProvider
                            .notifier)
                        .delete(e.key),
                  ),
                ],
              ),
            );
          }),
      ],
    );
  }
}
