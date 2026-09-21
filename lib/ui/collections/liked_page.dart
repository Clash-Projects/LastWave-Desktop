import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/track_actions.dart'
    show
        formatDuration,
        mergeYtTracks,
        playGenerated,
        playableFromGenerated;
import '../../features/feed/feed_repository.dart';
import '../../features/innertube/yt_library_providers.dart';
import '../../features/library/playlists.dart';
import '../../features/player/playback_service.dart';
import '../components/buttons.dart';
import '../components/desktop_table.dart';
import '../components/hero.dart';
import '../components/states.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

/// Liked Songs: hero + filter + sort + dense table.
class WaveLikedPage extends ConsumerStatefulWidget {
  const WaveLikedPage({super.key});

  @override
  ConsumerState<WaveLikedPage> createState() =>
      _WaveLikedPageState();
}

class _WaveLikedPageState
    extends ConsumerState<WaveLikedPage> {
  final _filter = TextEditingController();
  String _q = '';
  String _sort = 'default';

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playlists = ref.watch(playlistRepositoryProvider);
    final liked =
        playlists.where((p) => p.isLikedSongs).firstOrNull;
    final all = liked?.tracks ?? const [];
    var tracks = all
        .where(
          (t) => '${t.name} ${t.artist}'
              .toLowerCase()
              .contains(_q.toLowerCase()),
        )
        .toList();
    if (_sort == 'title') {
      tracks.sort((a, b) => a.name.compareTo(b.name));
    } else if (_sort == 'artist') {
      tracks.sort((a, b) => a.artist.compareTo(b.artist));
    }
    final playingKey = ref.watch(
      playbackServiceProvider.select((s) => s.current?.queueKey),
    );
    // Signed-in YouTube Music likes merge in, deduped (local wins).
    final ytLiked =
        ref.watch(ytLikedSongsProvider).value ?? const [];
    final ytFiltered = ytLiked
        .where(
          (t) => '${t.title} ${t.artist}'
              .toLowerCase()
              .contains(_q.toLowerCase()),
        )
        .toList();
    List<GeneratedTrack> asGenerated() => mergeYtTracks(
          tracks
              .map(
                (t) => GeneratedTrack(
                  name: t.name,
                  artist: t.artist,
                  artworkUrl: t.artworkUrl,
                  videoId: t.videoId,
                ),
              )
              .toList(),
          ytFiltered,
        );
    String cover = '';
    for (final t in all) {
      if (t.artworkUrl.isNotEmpty) {
        cover = t.artworkUrl;
        break;
      }
    }
    // Unfiltered total including YouTube Music likes (for counts +
    // the empty state); asGenerated() is the query-filtered view.
    final mergedTotal = mergeYtTracks(
      all
          .map(
            (t) => GeneratedTrack(
              name: t.name,
              artist: t.artist,
              artworkUrl: t.artworkUrl,
              videoId: t.videoId,
            ),
          )
          .toList(),
      ytLiked,
    ).length;
    // Empty: ONE compact state only — simple text header, no artwork hero
    // plus a second giant icon.
    if (mergedTotal == 0) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: WaveDensity.contentMax,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('PLAYLIST',
                    style: WaveType.overline.copyWith(
                        fontSize: 10,
                        color: waveTextTertiary(context))),
                const SizedBox(height: 4),
                Text('Liked Songs',
                    style: WaveType.pageTitle
                        .copyWith(fontSize: 28)),
                const SizedBox(height: 4),
                Text('0 tracks',
                    style: WaveType.meta.copyWith(
                        color: waveTextTertiary(context))),
                const SizedBox(height: 8),
                const WaveEmpty(
                  icon: FluentIcons.heart,
                  title: 'No liked songs yet',
                  subtitle:
                      'Tap the heart on any track to save it here.',
                ),
              ],
            ),
          ),
        ],
      );
    }
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
                    overline: 'Playlist',
                    title: 'Liked Songs',
                    meta:
                        '$mergedTotal tracks${_q.isNotEmpty ? ' · ${asGenerated().length} match' : ''}',
                    artworkUrl: cover,
                    fallbackIcon: FluentIcons.heart_fill,
                    primaryActions: [
                      if (asGenerated().isNotEmpty)
                        WavePrimaryButton(
                          label: 'Play all',
                          icon: FluentIcons.play,
                          onPressed: () =>
                              playGenerated(
                            ref,
                            context,
                            asGenerated().first,
                            sourceLabel: 'Liked Songs',
                            queueAll: asGenerated(),
                          ),
                        ),
                      WaveGhostButton(
                        label: 'Shuffle',
                        icon: WaveIcons.shuffle,
                        onPressed: asGenerated().isEmpty
                            ? null
                            : () {
                                // Shuffle BEFORE picking first —
                                // first must come from the shuffled list.
                                final shuffled =
                                    asGenerated()..shuffle();
                                playGenerated(
                                  ref,
                                  context,
                                  shuffled.first,
                                  sourceLabel: 'Liked Songs',
                                  queueAll: shuffled,
                                );
                              },
                      ),
                    ],
                  ),
                  ),
                  const SizedBox(height: 12),
                  WaveFilterBar(
                    controller: _filter,
                    onChanged: (v) =>
                        setState(() => _q = v),
                    hint: 'Filter liked songs…',
                    countLabel:
                        '${asGenerated().length} tracks',
                    sortSlot: LWTooltip(
                      message: 'Sort (also sortable via table headers)',
                      child: DropDownButton(
                        title: Text(
                          _sort == 'default'
                              ? 'Default order'
                              : (_sort == 'title'
                                  ? 'Title A–Z'
                                  : 'Artist A–Z'),
                        ),
                        items: [
                          MenuFlyoutItem(
                            text:
                                const Text('Default order'),
                            onPressed: () => setState(
                              () => _sort = 'default',
                            ),
                          ),
                          MenuFlyoutItem(
                            text:
                                const Text('Title A–Z'),
                            onPressed: () => setState(
                              () => _sort = 'title',
                            ),
                          ),
                          MenuFlyoutItem(
                            text:
                                const Text('Artist A–Z'),
                            onPressed: () => setState(
                              () => _sort = 'artist',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ),
        if (asGenerated().isEmpty)
          const SliverToBoxAdapter(
            child: WaveEmpty(
              icon: FluentIcons.heart,
              title: 'No liked songs yet',
              subtitle:
                  'Tap the heart on any track to save it here.',
            ),
          )
        else
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: WaveDesktopTable<GeneratedTrack>(
                items: asGenerated(),
                keyOf: (t) => t.key,
                titleOf: (t) => t.name,
                subtitleOf: (t) => t.artist,
                albumOf: (_) => '',
                artworkOf: (t) => t.artworkUrl,
                playableOf: playableFromGenerated,
                durationOf: (t) => t.durationSeconds > 0
                    ? formatDuration(
                        Duration(seconds: t.durationSeconds))
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
                shrinkWrap: true,
                selectable: true,
                onPlay: (i) => playGenerated(
                  ref,
                  context,
                  asGenerated()[i],
                  sourceLabel: 'Liked Songs',
                  queueAll: asGenerated(),
                  startIndex: i,
                ),
              ),
            ),
          ),
        const SliverToBoxAdapter(
          child: SizedBox(height: 24),
        ),
      ],
      ),
    );
  }
}


