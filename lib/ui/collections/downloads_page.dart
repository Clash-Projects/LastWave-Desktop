import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:super_sliver_list/super_sliver_list.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/audio/stream_models.dart';
import '../../core/storage/prefs.dart';
import '../../features/downloads/download_manager.dart';
import '../../features/library/playlists.dart';
import '../../features/player/playback_service.dart';
import '../components/artwork.dart';
import '../components/buttons.dart';
import '../components/hero.dart';
import '../components/menus.dart';
import '../components/states.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';

/// Downloads: Offline hero + 40px-artwork rows
/// (art · title/artist · progress or quality chip · play · delete).
class WaveDownloadsPage extends ConsumerWidget {
  const WaveDownloadsPage({super.key});

  String _artworkFor(WidgetRef ref, DownloadEntry e) {
    final playlists = ref.watch(playlistRepositoryProvider);
    for (final p in playlists) {
      for (final t in p.tracks) {
        if (t.name.toLowerCase() == e.title.toLowerCase() &&
            t.artist.toLowerCase() ==
                e.artist.toLowerCase() &&
            t.artworkUrl.isNotEmpty) {
          return t.artworkUrl;
        }
      }
    }
    return '';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(downloadManagerProvider);
    final done =
        entries.where((e) => e.status == DownloadStatus.done);
    final failed =
        entries.where((e) => e.status == DownloadStatus.error).toList();
    return WaveEntranceGroup(
      child: CustomScrollView(
        slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding:
                const EdgeInsets.fromLTRB(24, 20, 24, 0),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: WaveDensity.contentMax,
              ),
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  WaveEntrance(
                    rise: 10,
                    child: WaveCollectionHero(
                    overline: 'Offline',
                    title: 'Downloads',
                    meta:
                        '${done.length} ${done.length == 1 ? 'track' : 'tracks'} available offline · ${entries.length} total',
                    fallbackIcon: FluentIcons.download,
                    artworkSize: 120,
                  ),
                  ),
                  const SizedBox(height: 12),
                  const _LocationRow(),
                  const SizedBox(height: 12),
                  // Local InfoBar for failures — never breaks the list.
                  if (failed.isNotEmpty)
                    Padding(
                      padding:
                          const EdgeInsets.only(bottom: 12),
                      child: InfoBar(
                        severity: InfoBarSeverity.warning,
                        title: Text(
                            '${failed.length} download${failed.length == 1 ? '' : 's'} failed'),
                        content: Text(failed.first.error ??
                            'Check connection and retry.'),
                        action: Button(
                          onPressed: () {
                            final m = ref.read(
                                downloadManagerProvider
                                    .notifier);
                            for (final f in failed) {
                              m.downloadTrack(
                                title: f.title,
                                artist: f.artist,
                              );
                            }
                          },
                          child: const Text('Retry all'),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        if (entries.isEmpty)
          const SliverToBoxAdapter(
            child: WaveEmpty(
              icon: FluentIcons.download,
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
              final art = _artworkFor(ref, e);
              return WaveEntrance(
                index: i,
                rise: 10,
                child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                ),
                child: _DownloadRow(entry: e, artwork: art),
              ),
              );
            },
          ),
        const SliverToBoxAdapter(
          child: SizedBox(height: 24),
        ),
        ],
      ),
    );
  }
}

/// Download folder row: current location + change / reset.
/// Stateful so the path refreshes right after picking (prefs is not
/// a listenable provider).
class _LocationRow extends ConsumerStatefulWidget {
  const _LocationRow();
  @override
  ConsumerState<_LocationRow> createState() => _LocationRowState();
}

class _LocationRowState extends ConsumerState<_LocationRow> {
  Future<void> _pick() async {
    try {
      final path = await FilePicker.getDirectoryPath(
        dialogTitle: 'Choose download folder',
      );
      if (path == null || path.trim().isEmpty) return;
      await ref.read(prefsProvider).setDownloadDir(path);
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _reset() async {
    try {
      await ref.read(prefsProvider).resetDownloadDir();
      if (mounted) setState(() {});
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final custom = ref.read(prefsProvider).downloadDir;
    return Row(
      children: [
        const Icon(FluentIcons.open_folder_horizontal, size: 15),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            custom.isEmpty ? 'Saving to default location' : custom,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: WaveType.meta.copyWith(
              color: waveTextSecondary(context),
            ),
          ),
        ),
        Button(
          onPressed: _pick,
          child: const Text('Change folder'),
        ),
        if (custom.isNotEmpty) ...[
          const SizedBox(width: 8),
          Button(
            onPressed: _reset,
            child: const Text('Reset'),
          ),
        ],
      ],
    );
  }
}

/// Interactive download row: hover wash, double-click to play,
/// right-click menu (play / go to artist / delete).
class _DownloadRow extends ConsumerStatefulWidget {
  final DownloadEntry entry;
  final String artwork;
  const _DownloadRow({required this.entry, required this.artwork});

  @override
  ConsumerState<_DownloadRow> createState() => _DownloadRowState();
}

class _DownloadRowState extends ConsumerState<_DownloadRow> {
  bool _hover = false;

  void _play() {
    final e = widget.entry;
    if (e.status != DownloadStatus.done) return;
    ref.read(playbackServiceProvider.notifier).play(
          PlayableTrack(
            title: e.title,
            artist: e.artist,
            artworkUrl: widget.artwork,
            playbackUrl: e.filePath ?? '',
          ),
          sourceLabel: 'Downloads',
          startRadio: ref.read(prefsProvider).autoplaySimilar,
        );
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final art = widget.artwork;
    final manager = ref.read(downloadManagerProvider.notifier);
    final downloading = e.status == DownloadStatus.downloading;
    final queued = e.status == DownloadStatus.queued;
    final dark = waveIsDark(context);
    return WaveContextMenu(
      items: () => [
        if (e.status == DownloadStatus.done)
          WaveMenuAction(
            leading: const Icon(FluentIcons.play, size: 13),
            label: 'Play offline file',
            onPressed: _play,
          ),
        WaveMenuAction(
          leading: const Icon(FluentIcons.contact, size: 13),
          label: 'Go to artist',
          onPressed: () => context.go(
              '/artist/${Uri.encodeComponent(e.artist)}'),
        ),
        const WaveMenuSeparator(),
        WaveMenuAction(
          leading: const Icon(FluentIcons.delete, size: 13),
          label: 'Delete download',
          onPressed: () => manager.delete(e.key),
        ),
      ],
      child: MouseRegion(
        cursor: e.status == DownloadStatus.done
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onDoubleTap: _play,
          child: AnimatedContainer(
            duration: WaveMotion.fast,
            curve: Curves.easeOutCubic,
            height: 54,
            decoration: BoxDecoration(
              color: _hover
                  ? (dark ? Colors.white : Colors.black)
                      .withValues(alpha: 0.07)
                  : Colors.transparent,
              borderRadius:
                  BorderRadius.circular(WaveRadius.tiny),
            ),
            child: Row(
              children: [
                Stack(
                  children: [
                    WaveArtwork(
                        url: art,
                        size: 40,
                        radius: 6,
                        label: e.title,
                        title: e.title,
                        artist: e.artist),
                    if (downloading || queued)
                      Positioned.fill(
                        child: Container(
                          decoration: BoxDecoration(
                            color:
                                Colors.black.withValues(alpha: 0.45),
                            borderRadius:
                                BorderRadius.circular(6),
                          ),
                          child: const Center(
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: ProgressRing(strokeWidth: 2),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        e.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: WaveType.trackTitle,
                      ),
                      if (downloading)
                        Padding(
                          padding: const EdgeInsets.only(top: 5),
                          child: ProgressBar(
                            value: e.progress > 0
                                ? (e.progress * 100).clamp(0, 100)
                                : null,
                          ),
                        )
                      else
                        Text(
                          e.status == DownloadStatus.error
                              ? (e.error ??
                                  'Download failed — retry from the track menu')
                              : queued
                                  ? 'Waiting…'
                                  : e.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: WaveType.meta.copyWith(
                            color: waveTextSecondary(context),
                          ),
                        ),
                    ],
                  ),
                ),
                if (!downloading && e.badge.isNotEmpty) ...[
                  WaveChip(label: e.badge),
                  const SizedBox(width: 6),
                ],
                // Status text: progress % / size / status — tabular.
                if (downloading)
                  Text(
                    e.progress > 0
                        ? '${(e.progress * 100).round()}%'
                        : 'Starting…',
                    style: WaveType.meta.copyWith(
                      fontFeatures: const [
                        FontFeature.tabularFigures()
                      ],
                      color: waveTextTertiary(context),
                    ),
                  )
                else if (e.status == DownloadStatus.error)
                  const Icon(FluentIcons.error,
                      size: 14, color: Color(0xFFE0506A)),
                if (e.status == DownloadStatus.done)
                  WaveIconButton(
                    tooltip: 'Play offline file',
                    icon: const Icon(FluentIcons.play, size: 14),
                    onPressed: _play,
                  ),
                if (e.status == DownloadStatus.error)
                  WaveIconButton(
                    tooltip: 'Retry download',
                    icon:
                        const Icon(FluentIcons.refresh, size: 14),
                    onPressed: () => manager.downloadTrack(
                      title: e.title,
                      artist: e.artist,
                    ),
                  ),
                if (e.status == DownloadStatus.done &&
                    e.filePath != null)
                  WaveIconButton(
                    tooltip: 'Open file location',
                    icon: const Icon(
                        FluentIcons.open_folder_horizontal,
                        size: 14),
                    onPressed: () =>
                        _openLocation(context, e.filePath!),
                  ),
                WaveIconButton(
                  tooltip: 'Delete download',
                  icon: const Icon(FluentIcons.delete, size: 14),
                  onPressed: () => manager.delete(e.key),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openLocation(
      BuildContext context, String filePath) async {
    // Best-effort: reveal the file in Explorer/Finder/Files.
    try {
      final uri = Uri.file(filePath);
      // url_launcher handles file:// on desktop; failure is silent.
      final ok = await canLaunchUrl(uri);
      if (ok) await launchUrl(uri);
    } catch (_) {}
  }
}
