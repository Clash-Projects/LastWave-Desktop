import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/prefs.dart';
import '../../features/home/home_providers.dart';
import '../../features/library/playlists.dart';
import '../../features/library/yt_playlist_sync.dart';
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
  bool _syncing = false;
  String _syncMessage = '';

  Future<void> _sync() async {
    setState(() {
      _syncing = true;
      _syncMessage = '';
    });
    final result = await ref.read(ytPlaylistSyncProvider).syncNow();
    if (!mounted) return;
    setState(() {
      _syncing = false;
      _syncMessage = result.message;
    });
  }

  void _setSelected(int id, bool on) {
    final sync = ref.read(ytPlaylistSyncProvider);
    final next = {...sync.load().selectedIds};
    if (on) {
      next.add(id);
    } else {
      next.remove(id);
    }
    sync.setSelected(next);
    setState(() {});
  }

  void _restore(String key) {
    ref.read(databaseProvider).removeExclusion(key);
    ref.invalidate(feedProvider);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(prefsProvider);
    final playlists = ref
        .watch(playlistRepositoryProvider)
        .where((p) => !p.isLikedSongs && !p.isLocal)
        .toList();
    final sync = ref.watch(ytPlaylistSyncProvider).load();
    final exclusions = ref.watch(databaseProvider).listExclusions();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Library', style: WaveType.pageTitle),
        const SizedBox(height: 4),
        Text(
          'Podcasts, folders you play in place, and what gets mirrored.',
          style: WaveType.body.copyWith(color: waveTextSecondary(context)),
        ),
        const SizedBox(height: 16),
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
        Text(
          'Sync copies the playlists you tick to your YouTube Music library. Liked Songs and Local songs are never uploaded. A remote playlist is deleted only when you remove it here and that row’s delete option is on.',
          style: WaveType.meta.copyWith(color: waveTextSecondary(context)),
        ),
        const SizedBox(height: 10),
        if (playlists.isEmpty)
          Text(
            'Create a playlist to sync it.',
            style: WaveType.meta.copyWith(color: waveTextTertiary(context)),
          )
        else
          for (final playlist in playlists) ...[
            Checkbox(
              checked: sync.selectedIds.contains(playlist.id),
              onChanged: (v) => _setSelected(playlist.id, v == true),
              content: Text(
                playlist.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 28, bottom: 6),
              child: Checkbox(
                checked: sync.mappings[playlist.id]?.deleteRemoteWithLocal ==
                    true,
                onChanged: (v) {
                  ref
                      .read(ytPlaylistSyncProvider)
                      .setDeleteRemote(playlist.id, v == true);
                  setState(() {});
                },
                content: const Text(
                  'Delete the YouTube copy when I delete it here',
                ),
              ),
            ),
          ],
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: WavePrimaryButton(
            label: _syncing ? 'Syncing…' : 'Sync now',
            icon: FluentIcons.sync,
            onPressed: _syncing ? null : _sync,
          ),
        ),
        if (_syncMessage.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(_syncMessage, style: WaveType.body),
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
