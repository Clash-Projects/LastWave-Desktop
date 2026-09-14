import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

import '../../core/audio/stream_models.dart';
import '../../design_system/components.dart';
import '../../design_system/icons.dart';
import '../../design_system/tokens.dart';
import '../../widgets/artwork.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/quality_badge.dart';
import '../../widgets/section.dart';
import '../player/playback_service.dart';
import 'download_manager.dart';

/// Editorial downloads: masthead + inline-progress ledger rows.
/// Replaces per-row boxed cards with flat ledger (icon · title ledger ·
/// badge · play · delete).
class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final entries = ref.watch(downloadManagerProvider);
    final manager =
        ref.read(downloadManagerProvider.notifier);
    final done =
        entries.where((e) => e.status == DownloadStatus.done);
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
                LwSpacing.xl, LwSpacing.lg, LwSpacing.xl, 0),
            child: EdPage(
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  CollectionHeader(
                    kicker: 'Offline',
                    title: 'Downloads',
                    meta:
                        '${done.length} ${done.length == 1 ? 'track' : 'tracks'} available offline',
                    fallbackIcon:
                        LucideIcons.download,
                    artworkSize: 96,
                  ),
                  const SizedBox(
                      height: LwSpacing.md),
                  const EdLedgerHeader(
                      metaLabel: ''),
                ],
              ),
            ),
          ),
        ),
        if (entries.isEmpty)
          const SliverToBoxAdapter(
            child: EmptyState(
              icon: LucideIcons.download,
              title: 'No downloads yet',
              subtitle:
                  'Download any track to keep it offline in full quality.',
            ),
          )
        else
          SuperSliverList.builder(
            itemCount: entries.length,
            itemBuilder: (context, i) {
              final e = entries[i];
              final player = ref.read(
                  playbackServiceProvider.notifier);
              return Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: LwSpacing.lg),
                child: Container(
                  height: 56,
                  padding:
                      const EdgeInsets.symmetric(
                          horizontal: LwSpacing.sm),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                          color: dark
                              ? LwColors.outlineSoft
                              : LwColors
                                  .lightOutlineSoft),
                    ),
                  ),
                  child: Row(
                    children: [
                      _DownloadArt(
                          entry: e,
                          downloading: e.status ==
                                  DownloadStatus
                                      .downloading ||
                              e.status ==
                                  DownloadStatus.queued),
                      const SizedBox(
                          width: LwSpacing.sm),
                      Expanded(
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          mainAxisAlignment:
                              MainAxisAlignment.center,
                          children: [
                            Text(e.title,
                                maxLines: 1,
                                overflow:
                                    TextOverflow.ellipsis,
                                style: LwType.title
                                    .copyWith(
                                        fontSize: 13)),
                            if (e.status ==
                                DownloadStatus
                                    .downloading)
                              Padding(
                                padding:
                                    const EdgeInsets.only(
                                        top: 5),
                                child:
                                    LinearProgressIndicator(
                                  value: e.progress > 0
                                      ? e.progress
                                      : null,
                                  minHeight: 3,
                                  borderRadius:
                                      BorderRadius.circular(
                                          2),
                                ),
                              )
                              else
                              Text(
                                e.status ==
                                        DownloadStatus
                                            .error
                                    ? (e.error ??
                                        'Download failed — retry from the track menu')
                                    : e.status ==
                                            DownloadStatus
                                                .queued
                                        ? 'Waiting…'
                                        : e.artist,
                                maxLines: 1,
                                overflow:
                                    TextOverflow.ellipsis,
                                style: LwType.caption
                                    .copyWith(
                                        color: dark
                                            ? LwColors
                                                .textSecondary
                                            : LwColors
                                                .lightTextSecondary),
                              ),
                          ],
                        ),
                      ),
                      if (e.badge.isNotEmpty) ...[
                        QualityBadge(label: e.badge),
                        const SizedBox(
                            width: LwSpacing.xs),
                      ],
                      if (e.status ==
                          DownloadStatus.done)
                        LwIconButton(
                          tooltip:
                              'Play offline file',
                          icon: const Icon(
                              LucideIcons.play,
                              size: 15),
                          onPressed: () =>
                              player.play(
                            PlayableTrack(
                              title: e.title,
                              artist: e.artist,
                              playbackUrl:
                                  e.filePath ?? '',
                            ),
                            sourceLabel: 'Downloads',
                          ),
                        ),
                      LwIconButton(
                        tooltip: 'Delete download',
                        icon: const Icon(
                            LucideIcons.trash2,
                            size: 15),
                        onPressed: () =>
                            manager.delete(e.key),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        const SliverToBoxAdapter(
            child: SizedBox(height: 96)),
      ],
    );
  }
}

/// 40px artwork with progress veil while downloading/queued.
class _DownloadArt extends StatelessWidget {
  final DownloadEntry entry;
  final bool downloading;
  const _DownloadArt(
      {required this.entry, required this.downloading});
  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Artwork(
            url: '',
            size: 40,
            radius: LwRadius.sm,
            fallbackIcon: LucideIcons.music),
        if (downloading)
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                color:
                    Colors.black.withValues(alpha: 0.45),
                borderRadius:
                    BorderRadius.circular(LwRadius.sm),
              ),
              child: const Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
