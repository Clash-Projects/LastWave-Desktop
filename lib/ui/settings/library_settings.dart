import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/prefs.dart';
import '../../features/home/home_providers.dart';
import '../../features/library/yt_library_sync.dart';
import '../../features/search/shared_providers.dart';
import '../components/buttons.dart';
import '../theme/tokens.dart';

/// Settings → Library: podcasts, YouTube playlist sync, and exclusions.
class LibrarySettings extends ConsumerStatefulWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const LibrarySettings({super.key, required this.onUpdate});

  @override
  ConsumerState<LibrarySettings> createState() => _LibrarySettingsState();
}

class _LibrarySettingsState extends ConsumerState<LibrarySettings> {
  void _restore(String key) {
    ref.read(databaseProvider).removeExclusion(key);
    ref.invalidate(feedProvider);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(prefsProvider);
    final sync = ref.watch(ytSyncStatusProvider);
    final exclusions = ref.watch(databaseProvider).listExclusions();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Podcasts', style: WaveType.sectionTitle),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Text(
                'Show YouTube Music podcasts on Home, Search, and the Podcasts page. Turning this off keeps saved resume positions.',
                style: WaveType.meta.copyWith(color: waveTextSecondary(context)),
              ),
            ),
            const SizedBox(width: 12),
            ToggleSwitch(
              checked: prefs.podcastsEnabled,
              onChanged: (v) => widget.onUpdate((p) => p.setPodcastsEnabled(v)),
            ),
          ],
        ),
        const SizedBox(height: 22),
        Text('YouTube Music sync', style: WaveType.sectionTitle),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Text(
                'Keep Liked Songs and your playlists the same here and on YouTube Music. Changes here go up within seconds; changes on YouTube arrive within about a minute. Local songs are never uploaded, and new playlists are created as private.',
                style: WaveType.meta.copyWith(color: waveTextSecondary(context)),
              ),
            ),
            const SizedBox(width: 12),
            ToggleSwitch(
              checked: prefs.syncYtLibrary,
              onChanged: (v) async {
                await widget.onUpdate((p) => p.setSyncYtLibrary(v));
                if (v) ref.read(ytLibrarySyncProvider).kick();
              },
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            WaveGhostButton(
              label: sync.running ? 'Syncing…' : 'Sync now',
              icon: FluentIcons.sync,
              onPressed: sync.running || !prefs.syncYtLibrary
                  ? null
                  : () => ref.read(ytLibrarySyncProvider).kick(),
            ),
            if (sync.heldRemovals > 0)
              WaveGhostButton(
                label: 'Remove ${sync.heldRemovals} songs',
                icon: FluentIcons.delete,
                onPressed: () =>
                    ref.read(ytLibrarySyncProvider).applyHeldRemovals(),
              ),
          ],
        ),
        if (sync.message.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            sync.message,
            style: WaveType.meta.copyWith(color: waveTextSecondary(context)),
          ),
        ],
        const SizedBox(height: 22),
        Text('Hidden from recommendations', style: WaveType.sectionTitle),
        const SizedBox(height: 6),
        Text(
          'Restore a track to let Mix Lab and Home suggest it again.',
          style: WaveType.meta.copyWith(color: waveTextSecondary(context)),
        ),
        const SizedBox(height: 8),
        if (exclusions.isEmpty)
          Text(
            'No tracks are hidden.',
            style: WaveType.meta.copyWith(color: waveTextTertiary(context)),
          )
        else
          for (final item in exclusions)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.name.isEmpty ? item.key : item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: WaveType.trackTitle,
                        ),
                        if (item.artist.isNotEmpty)
                          Text(
                            item.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: WaveType.meta.copyWith(
                              color: waveTextSecondary(context),
                            ),
                          ),
                      ],
                    ),
                  ),
                  WaveGhostButton(
                    label: 'Restore',
                    onPressed: () => _restore(item.key),
                  ),
                ],
              ),
            ),
      ],
    );
  }
}
