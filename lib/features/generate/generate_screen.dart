import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../design_system/icons.dart';

import '../../design_system/components.dart';
import '../../design_system/tokens.dart';
import '../feed/feed_repository.dart';
import '../home/home_screen.dart' show playGenerated;
import '../library/playlists.dart';
import '../player/playback_service.dart';

final _mixProvider = FutureProvider.autoDispose
    .family<List<GeneratedTrack>, ({int total, int nonce})>(
        (ref, args) {
  return ref
      .watch(feedRepositoryProvider)
      .fetchMix(total: args.total);
});

/// Mix Lab: taste-driven mix generation (mirrors Android Generate).
class GenerateScreen extends ConsumerStatefulWidget {
  const GenerateScreen({super.key});
  @override
  ConsumerState<GenerateScreen> createState() =>
      _GenerateScreenState();
}

class _GenerateScreenState
    extends ConsumerState<GenerateScreen> {
  int _total = 32;
  int _nonce = 0;

  @override
  Widget build(BuildContext context) {
    final data =
        ref.watch(_mixProvider((total: _total, nonce: _nonce)));
    return ListView(
      padding: const EdgeInsets.fromLTRB(
          LwSpacing.lg, LwSpacing.lg, LwSpacing.lg, 96),
      children: [
        const Text('Mix Lab', style: LwType.display),
        const SizedBox(height: 4),
        Text(
          'A fresh $_total-track mix from your taste profile — recent obsessions, all-time staples and discovery branches.',
          style: LwType.body
              .copyWith(color: LwColors.textSecondary),
        ),
        const SizedBox(height: LwSpacing.md),
        Row(
          children: [
            for (final n in [24, 32, 40])
              Padding(
                padding:
                    const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text('$n tracks'),
                  selected: _total == n,
                  onSelected: (_) =>
                      setState(() => _total = n),
                ),
              ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: () =>
                  setState(() => _nonce++),
              icon: const Icon(LwIcons.refreshCw,
                  size: 15),
              label: const Text('Regenerate'),
            ),
          ],
        ),
        const SizedBox(height: LwSpacing.md),
        data.when(
          loading: () => const SkeletonRow(count: 10),
          error: (e, _) => EmptyState(
            icon: LwIcons.cloudOff,
            title: 'Mix failed',
            subtitle: e.toString(),
            actionLabel: 'Retry',
            onAction: () =>
                setState(() => _nonce++),
          ),
          data: (tracks) {
            if (tracks.isEmpty) {
              return const EmptyState(
                icon: LwIcons.wand2,
                title: 'No mix yet',
                subtitle:
                    'Connect Last.fm or play more music first.',
              );
            }
            return Column(
              children: [
                Row(
                  children: [
                    FilledButton.icon(
                      onPressed: () => playGenerated(
                        ref,
                        context,
                        tracks.first,
                        sourceLabel: 'Mix Lab',
                        queueAll: tracks,
                      ),
                      icon: const Icon(LwIcons.play,
                          size: 15),
                      label: const Text('Play mix'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: () =>
                          _saveAsPlaylist(tracks),
                      icon: const Icon(
                          LwIcons.listPlus,
                          size: 15),
                      label:
                          const Text('Save as playlist'),
                    ),
                  ],
                ),
                const SizedBox(height: LwSpacing.sm),
                ...tracks.asMap().entries.map((e) {
                  final t = e.value;
                  final playing = ref
                          .watch(playbackServiceProvider)
                          .current
                          ?.queueKey ==
                      t.key;
                  return TrackTile(
                    title: t.name,
                    subtitle: t.artist,
                    artworkUrl: t.artworkUrl,
                    trailing: '${e.key + 1}',
                    playing: playing,
                    onTap: () => playGenerated(
                        ref, context, t,
                        sourceLabel: 'Mix Lab',
                        queueAll: tracks,
                        startIndex: e.key),
                  );
                }),
              ],
            );
          },
        ),
      ],
    );
  }

  Future<void> _saveAsPlaylist(
      List<GeneratedTrack> tracks) async {
    final created = await ref
        .read(playlistRepositoryProvider.notifier)
        .createCustom(
            'Mix · ${DateTime.now().day}/${DateTime.now().month}');
    final notifier =
        ref.read(playlistRepositoryProvider.notifier);
    for (final t in tracks) {
      await notifier.addTrack(
        created.id,
        StoredTrack(
          name: t.name,
          artist: t.artist,
          artworkUrl: t.artworkUrl,
          videoId: t.videoId,
        ),
      );
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                'Saved ${tracks.length} tracks to ${created.title}')),
      );
    }
  }
}
