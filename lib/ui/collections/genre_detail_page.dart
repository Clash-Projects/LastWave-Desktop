import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/track_actions.dart'
    show formatDuration, playGenerated, playableFromGenerated;
import '../../features/feed/feed_repository.dart' show GeneratedTrack;
import '../../features/player/playback_service.dart';
import '../../features/feed/genre_browse.dart';
import '../components/buttons.dart' show WaveGhostButton, WavePrimaryButton;
import '../components/desktop_table.dart';
import '../components/hero.dart';
import '../components/states.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

/// A Browse Categories genre: songs from YouTube Music for that genre,
/// with Play all / Shuffle and a playable track table.
class WaveGenreDetailPage extends ConsumerWidget {
  final String query;
  final String title;
  const WaveGenreDetailPage({super.key, required this.query, this.title = ''});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(genreTracksProvider(query));
    return async.when(
      loading: () => const WaveLoading(label: 'Loading songs…'),
      error: (e, _) => WaveError(
        title: 'Could not load this genre',
        message: '$e',
        onRetry: () => ref.invalidate(genreTracksProvider(query)),
      ),
      data: (tracks) {
        if (tracks.isEmpty) {
          return WaveEmpty(
            icon: WaveIcons.music,
            title: 'Nothing found',
            subtitle: 'No songs came back for this genre. Try again later.',
            actionLabel: 'Retry',
            onAction: () => ref.invalidate(genreTracksProvider(query)),
          );
        }
        return _Body(
          query: query,
          title: title.isNotEmpty ? title : query,
          tracks: tracks,
        );
      },
    );
  }
}

class _Body extends ConsumerStatefulWidget {
  final String query;
  final String title;
  final List<GeneratedTrack> tracks;
  const _Body({required this.query, required this.title, required this.tracks});

  @override
  ConsumerState<_Body> createState() => _BodyState();
}

class _BodyState extends ConsumerState<_Body> {
  @override
  Widget build(BuildContext context) {
    final tracks = widget.tracks;
    final title = widget.title;
    final playingKey = ref.watch(
      playbackServiceProvider.select((s) => s.current?.queueKey),
    );
    var cover = '';
    for (final t in tracks) {
      if (t.artworkUrl.isNotEmpty) {
        cover = t.artworkUrl;
        break;
      }
    }
    return WaveEntranceGroup(
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: WaveDensity.contentMax,
                ),
                child: WaveEntrance(
                  rise: 10,
                  child: WaveCollectionHero(
                    flightKind: 'genre',
                    flightId: widget.query,
                    overline: 'Genre',
                    title: title,
                    meta: '${tracks.length} songs',
                    artworkUrl: cover,
                    fallbackIcon: WaveIcons.music,
                    primaryActions: [
                      WavePrimaryButton(
                        label: 'Play all',
                        icon: FluentIcons.play,
                        onPressed: () => playGenerated(
                          ref,
                          context,
                          tracks.first,
                          sourceLabel: title,
                          queueAll: tracks,
                        ),
                      ),
                      WaveGhostButton(
                        label: 'Shuffle',
                        icon: WaveIcons.shuffle,
                        onPressed: () {
                          final shuffled = [...tracks]..shuffle();
                          playGenerated(
                            ref,
                            context,
                            shuffled.first,
                            sourceLabel: title,
                            queueAll: shuffled,
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: WaveDesktopTable<GeneratedTrack>(
              items: tracks,
              keyOf: (t) => t.key,
              titleOf: (t) => t.name,
              subtitleOf: (t) => t.artist,
              albumOf: (t) => t.album,
              artworkOf: (t) => t.artworkUrl,
              playableOf: playableFromGenerated,
              durationOf: (t) => t.durationSeconds > 0
                  ? formatDuration(Duration(seconds: t.durationSeconds))
                  : '',
              durationSortOf: (t) => t.durationSeconds,
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
              sliver: true,
              selectable: true,
              onPlay: (i) => playGenerated(
                ref,
                context,
                tracks[i],
                sourceLabel: title,
                queueAll: tracks,
                startIndex: i,
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }
}
