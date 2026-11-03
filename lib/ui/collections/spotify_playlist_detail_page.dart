import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/track_actions.dart'
    show formatDuration, playGenerated, playableFromGenerated;
import '../../features/feed/feed_repository.dart' show GeneratedTrack;
import '../../features/library/playlists.dart';
import '../../features/player/playback_service.dart';
import '../../features/spotify/spotify_api.dart';
import '../components/buttons.dart' show LWTooltip, WaveGhostButton, WavePrimaryButton;
import '../components/desktop_table.dart';
import '../components/hero.dart';
import '../components/select.dart';
import '../components/states.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

/// Spotify playlist (or Liked Songs, id `liked`) detail: hero + filter +
/// track table. Read-only. Tracks play through the app's own resolver
/// (matched by title + artist), the same as imported playlists.
///
/// These likes live only here: the app's own Liked page never includes
/// Spotify likes.
class WaveSpotifyPlaylistDetailPage extends ConsumerStatefulWidget {
  final String playlistId;
  final String title;
  final String artworkUrl;
  const WaveSpotifyPlaylistDetailPage({
    super.key,
    required this.playlistId,
    this.title = '',
    this.artworkUrl = '',
  });

  @override
  ConsumerState<WaveSpotifyPlaylistDetailPage> createState() =>
      _WaveSpotifyPlaylistDetailPageState();
}

class _WaveSpotifyPlaylistDetailPageState
    extends ConsumerState<WaveSpotifyPlaylistDetailPage> {
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
    final async = ref.watch(spotifyPlaylistContentProvider(widget.playlistId));
    return async.when(
      loading: () => const WaveLoading(label: 'Loading playlist…'),
      error: (e, _) => WaveError(
        title: 'Could not load playlist',
        message: '$e',
        onRetry: () =>
            ref.invalidate(spotifyPlaylistContentProvider(widget.playlistId)),
      ),
      data: (res) {
        if (res == null || res.tracks.isEmpty) {
          return WaveEmpty(
            icon: WaveIcons.playlists,
            title: 'Playlist unavailable',
            subtitle:
                'It may be private or empty, or the Spotify session expired.',
            actionLabel: 'Back to playlists',
            onAction: () => context.go('/playlists'),
          );
        }
        return _Body(
          playlistId: widget.playlistId,
          res: res,
          heroTitle: widget.title.isNotEmpty ? widget.title : res.title,
          heroArt:
              widget.artworkUrl.isNotEmpty ? widget.artworkUrl : res.artworkUrl,
          filter: _filter,
          query: _q,
          onQuery: (v) => setState(() => _q = v),
          sort: _sort,
          onSort: (v) => setState(() => _sort = v),
        );
      },
    );
  }
}

class _Body extends ConsumerWidget {
  final String playlistId;
  final SpotifyPlaylistContent res;
  final String heroTitle;
  final String heroArt;
  final TextEditingController filter;
  final String query;
  final ValueChanged<String> onQuery;
  final String sort;
  final ValueChanged<String> onSort;
  const _Body({
    required this.playlistId,
    required this.res,
    required this.heroTitle,
    required this.heroArt,
    required this.filter,
    required this.query,
    required this.onQuery,
    required this.sort,
    required this.onSort,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tracks = res.tracks
        .where((t) => '${t.name} ${t.artist}'
            .toLowerCase()
            .contains(query.toLowerCase()))
        .toList();
    if (sort == 'title') {
      tracks.sort((a, b) => a.name.compareTo(b.name));
    } else if (sort == 'artist') {
      tracks.sort((a, b) => a.artist.compareTo(b.artist));
    }
    final playingKey = ref.watch(
      playbackServiceProvider.select((s) => s.current?.queueKey),
    );
    List<GeneratedTrack> asGenerated() => [
          for (final t in tracks)
            GeneratedTrack(
              name: t.name,
              artist: t.artist,
              album: t.album,
              artworkUrl: t.artworkUrl,
              durationSeconds: t.durationSeconds,
            ),
        ];

    var cover = heroArt;
    if (cover.isEmpty) {
      for (final t in res.tracks) {
        if (t.artworkUrl.isNotEmpty) {
          cover = t.artworkUrl;
          break;
        }
      }
    }

    return WaveEntranceGroup(
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
              child: ConstrainedBox(
                constraints:
                    const BoxConstraints(maxWidth: WaveDensity.contentMax),
                child: WaveEntrance(
                  rise: 10,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      WaveCollectionHero(
                        flightKind: 'spotifyplaylist',
                        flightId: playlistId,
                        overline: 'Spotify playlist',
                        title: heroTitle.isNotEmpty ? heroTitle : 'Playlist',
                        meta: '${res.tracks.length} tracks'
                            '${query.isNotEmpty ? ' · ${tracks.length} match' : ''}',
                        artworkUrl: cover,
                        fallbackIcon: WaveIcons.playlists,
                        primaryActions: [
                          if (tracks.isNotEmpty) ...[
                            WavePrimaryButton(
                              label: 'Play all',
                              icon: FluentIcons.play,
                              onPressed: () => playGenerated(
                                ref,
                                context,
                                asGenerated().first,
                                sourceLabel: heroTitle,
                                queueAll: asGenerated(),
                              ),
                            ),
                            WaveGhostButton(
                              label: 'Shuffle',
                              icon: WaveIcons.shuffle,
                              onPressed: () {
                                final shuffled = asGenerated()..shuffle();
                                playGenerated(
                                  ref,
                                  context,
                                  shuffled.first,
                                  sourceLabel: heroTitle,
                                  queueAll: shuffled,
                                );
                              },
                            ),
                            // A playlist copy only: never saved as, or
                            // merged into, the app's Liked Songs.
                            WaveGhostButton(
                              label: 'Save to library',
                              icon: FluentIcons.save,
                              onPressed: () async {
                                final saved = await ref
                                    .read(playlistRepositoryProvider.notifier)
                                    .saveGenerated(
                                  heroTitle.isEmpty
                                      ? 'Spotify playlist'
                                      : 'Spotify · $heroTitle',
                                  [
                                    for (final t in res.tracks)
                                      StoredTrack(
                                        name: t.name,
                                        artist: t.artist,
                                        album: t.album,
                                        artworkUrl: t.artworkUrl,
                                        durationSeconds: t.durationSeconds,
                                      ),
                                  ],
                                );
                                if (context.mounted) {
                                  context.go('/playlists/${saved.id}');
                                }
                              },
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 12),
                      WaveFilterBar(
                        controller: filter,
                        onChanged: onQuery,
                        hint: 'Filter in playlist…',
                        countLabel: '${tracks.length} tracks',
                        sortSlot: LWTooltip(
                          message: 'Sort (also sortable via table headers)',
                          child: WaveSelect<String>(
                            value: sort,
                            options: const [
                              WaveSelectOption(
                                  value: 'default', label: 'Default order'),
                              WaveSelectOption(
                                  value: 'title', label: 'Title A–Z'),
                              WaveSelectOption(
                                  value: 'artist', label: 'Artist A–Z'),
                            ],
                            onChanged: onSort,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (tracks.isEmpty)
            const SliverToBoxAdapter(
              child: WaveEmpty(
                icon: WaveIcons.playlists,
                title: 'No matches',
                subtitle: 'Try a different filter.',
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: WaveDesktopTable<GeneratedTrack>(
                items: asGenerated(),
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
                  asGenerated()[i],
                  sourceLabel: heroTitle,
                  queueAll: asGenerated(),
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
