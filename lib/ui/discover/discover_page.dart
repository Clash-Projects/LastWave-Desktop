import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/track_actions.dart'
    show formatDuration, playGenerated, playableFromGenerated;
import '../../features/feed/feed_repository.dart';
import '../../features/home/home_providers.dart';
import '../../features/player/playback_service.dart';
import '../components/buttons.dart';
import '../components/desktop_table.dart';
import '../components/hero.dart';
import '../components/states.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

/// New-release songs for Discover. Fresh Finds from the home feed are
/// merged in when that feed has already loaded; they are not required
/// before the new-music browse can paint.
final discoverQueueProvider = FutureProvider<List<GeneratedTrack>>((ref) {
  return ref.watch(feedRepositoryProvider).fetchNewMusicTracks(limit: 30);
});

List<GeneratedTrack> mergeDiscoverQueue(
  List<GeneratedTrack> fresh,
  List<GeneratedTrack> released,
) {
  final seen = <String>{};
  final out = <GeneratedTrack>[];
  for (final track in [...fresh, ...released]) {
    if (track.name.trim().isEmpty) continue;
    if (!seen.add(track.key)) continue;
    out.add(track);
    if (out.length >= 40) break;
  }
  return out;
}

class WaveDiscoverPage extends ConsumerWidget {
  const WaveDiscoverPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fresh = ref.watch(
      feedProvider.select(
        (async) => async.asData?.value.freshFinds ?? const <GeneratedTrack>[],
      ),
    );
    final released = ref.watch(discoverQueueProvider);
    final merged = mergeDiscoverQueue(
      fresh,
      released.asData?.value ?? const <GeneratedTrack>[],
    );

    if (released.isLoading && merged.isEmpty) {
      return const WaveLoading(label: 'Finding new music…');
    }
    if (released.hasError && merged.isEmpty) {
      return WaveError(
        title: 'Discover is unavailable',
        message: '${released.error}',
        onRetry: () {
          ref.invalidate(discoverQueueProvider);
          ref.invalidate(feedProvider);
        },
      );
    }
    if (merged.isEmpty) {
      return WaveEmpty(
        icon: WaveIcons.discover,
        title: 'Nothing new right now',
        subtitle: 'New releases and fresh finds will show up here.',
        actionLabel: 'Retry',
        onAction: () {
          ref.invalidate(discoverQueueProvider);
          ref.invalidate(feedProvider);
        },
      );
    }

    final playingKey = ref.watch(
      playbackServiceProvider.select((s) => s.current?.queueKey),
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 22, 28, 28),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: WaveDensity.contentMax),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                WaveCollectionHero(
                  overline: 'Listen',
                  title: 'Discover',
                  meta: '${merged.length} fresh tracks',
                  fallbackIcon: WaveIcons.discover,
                  primaryActions: [
                    WavePrimaryButton(
                      label: 'Play',
                      icon: FluentIcons.play,
                      onPressed: () => playGenerated(
                        ref,
                        context,
                        merged.first,
                        sourceLabel: 'Discover',
                        queueAll: merged,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                WaveDesktopTable<GeneratedTrack>(
                  items: merged,
                  keyOf: (t) => t.key,
                  titleOf: (t) => t.name,
                  subtitleOf: (t) => t.artist,
                  albumOf: (t) => t.album,
                  artworkOf: (t) => t.artworkUrl,
                  videoIdOf: (t) => t.videoId,
                  playableOf: playableFromGenerated,
                  durationOf: (t) => t.durationSeconds > 0
                      ? formatDuration(Duration(seconds: t.durationSeconds))
                      : '',
                  titleSortOf: (t) => t.name.toLowerCase(),
                  artistSortOf: (t) => t.artist.toLowerCase(),
                  isCurrent: (t) => playingKey == t.key,
                  isPlaying: (t) {
                    final playing = ref.watch(
                      playbackServiceProvider.select((p) => p.isPlaying),
                    );
                    return playingKey == t.key && playing;
                  },
                  showArtistColumn: true,
                  shrinkWrap: true,
                  onPlay: (i) => playGenerated(
                    ref,
                    context,
                    merged[i],
                    sourceLabel: 'Discover',
                    queueAll: merged,
                    startIndex: i,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
