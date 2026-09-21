import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/track_actions.dart'
    show formatDuration, playGenerated, playableFromGenerated;
import '../../features/downloads/download_manager.dart';
import '../../features/feed/feed_repository.dart';
import '../../features/innertube/innertube_api.dart';
import '../../features/innertube/yt_library_providers.dart';
import '../../features/player/playback_service.dart';
import '../components/buttons.dart'
    show LWTooltip, WaveGhostButton, WavePrimaryButton;
import '../components/desktop_table.dart';
import '../components/hero.dart';
import '../components/menus.dart' show fastFlyoutTransition;
import '../components/states.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

/// YouTube Music playlist detail: artwork hero + filter + track table.
///
/// Read-only mirror of [WavePlaylistDetailPage] for account playlists —
/// no pin/rename/delete/remove. [title]/[artworkUrl] are instant-hero
/// hints from the shelf; tracks load via [ytPlaylistDetailProvider].
class WaveYtPlaylistDetailPage extends ConsumerStatefulWidget {
  final String playlistId;
  final String title;
  final String artworkUrl;
  const WaveYtPlaylistDetailPage({
    super.key,
    required this.playlistId,
    this.title = '',
    this.artworkUrl = '',
  });

  @override
  ConsumerState<WaveYtPlaylistDetailPage> createState() =>
      _WaveYtPlaylistDetailPageState();
}

class _WaveYtPlaylistDetailPageState
    extends ConsumerState<WaveYtPlaylistDetailPage> {
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
    final async =
        ref.watch(ytPlaylistDetailProvider(widget.playlistId));
    return async.when(
      loading: () => const WaveLoading(
        label: 'Loading playlist…',
      ),
      error: (e, _) => WaveError(
        title: 'Could not load playlist',
        message: '$e',
        onRetry: () => ref
            .invalidate(ytPlaylistDetailProvider(widget.playlistId)),
      ),
      data: (res) {
        if (res == null || res.tracks.isEmpty) {
          return WaveEmpty(
            icon: FluentIcons.list_mirrored,
            title: 'Playlist unavailable',
            subtitle:
                'It may be private, deleted, or offline.',
            actionLabel: 'Back to playlists',
            onAction: () => context.go('/playlists'),
          );
        }
        return _Body(
          res: res,
          heroTitle: widget.title.isNotEmpty
              ? widget.title
              : res.title,
          heroArt: widget.artworkUrl.isNotEmpty
              ? widget.artworkUrl
              : res.artworkUrl,
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
  final YouTubePlaylistResult res;
  final String heroTitle;
  final String heroArt;
  final TextEditingController filter;
  final String query;
  final ValueChanged<String> onQuery;
  final String sort;
  final ValueChanged<String> onSort;
  const _Body({
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
    var tracks = res.tracks
        .where(
          (t) => '${t.title} ${t.artist}'
              .toLowerCase()
              .contains(query.toLowerCase()),
        )
        .toList();
    if (sort == 'title') {
      tracks.sort((a, b) => a.title.compareTo(b.title));
    } else if (sort == 'artist') {
      tracks.sort((a, b) => a.artist.compareTo(b.artist));
    }
    final playingKey = ref.watch(
      playbackServiceProvider.select((s) => s.current?.queueKey),
    );
    List<GeneratedTrack> asGenerated() => tracks
        .map(
          (t) => GeneratedTrack(
            name: t.title,
            artist: t.artist,
            artworkUrl: t.artworkUrl,
            videoId: t.videoId,
            durationSeconds: t.durationSeconds,
          ),
        )
        .toList();

    String cover = heroArt;
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
              padding:
                  const EdgeInsets.fromLTRB(24, 20, 24, 0),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: WaveDensity.contentMax,
                ),
                child: WaveEntrance(
                  rise: 10,
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      WaveCollectionHero(
                        overline: 'YouTube Music playlist',
                        title: heroTitle.isNotEmpty
                            ? heroTitle
                            : 'Playlist',
                        meta:
                            '${res.tracks.length} tracks${query.isNotEmpty ? ' · ${tracks.length} match' : ''}',
                        artworkUrl: cover,
                        fallbackIcon:
                            FluentIcons.list_mirrored,
                        primaryActions: [
                          if (tracks.isNotEmpty) ...[
                            WavePrimaryButton(
                              label: 'Play all',
                              icon: FluentIcons.play,
                              onPressed: () =>
                                  playGenerated(
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
                                final shuffled =
                                    asGenerated()
                                      ..shuffle();
                                playGenerated(
                                  ref,
                                  context,
                                  shuffled.first,
                                  sourceLabel: heroTitle,
                                  queueAll: shuffled,
                                );
                              },
                            ),
                            WaveGhostButton(
                              label: 'Download',
                              icon: FluentIcons.download,
                              onPressed: () {
                                final manager = ref.read(
                                    downloadManagerProvider
                                        .notifier);
                                for (final t
                                    in asGenerated()) {
                                  manager.downloadTrack(
                                    title: t.name,
                                    artist: t.artist,
                                    artworkUrl:
                                        t.artworkUrl,
                                  );
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
                        countLabel:
                            '${tracks.length} tracks',
                        sortSlot: LWTooltip(
                          message:
                              'Sort (also sortable via table headers)',
                          child: DropDownButton(
                            transitionBuilder: fastFlyoutTransition,
                            title: Text(
                              sort == 'default'
                                  ? 'Default order'
                                  : (sort == 'title'
                                      ? 'Title A–Z'
                                      : 'Artist A–Z'),
                            ),
                            items: [
                              MenuFlyoutItem(
                                text: const Text(
                                    'Default order'),
                                onPressed: () =>
                                    onSort('default'),
                              ),
                              MenuFlyoutItem(
                                text: const Text(
                                    'Title A–Z'),
                                onPressed: () =>
                                    onSort('title'),
                              ),
                              MenuFlyoutItem(
                                text: const Text(
                                    'Artist A–Z'),
                                onPressed: () =>
                                    onSort('artist'),
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
          ),
          if (tracks.isEmpty)
            const SliverToBoxAdapter(
              child: WaveEmpty(
                icon: FluentIcons.list_mirrored,
                title: 'No matches',
                subtitle: 'Try a different filter.',
              ),
            )
          else
            SliverToBoxAdapter(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16),
                child: WaveDesktopTable<GeneratedTrack>(
                  items: asGenerated(),
                  keyOf: (t) => t.key,
                  titleOf: (t) => t.name,
                  subtitleOf: (t) => t.artist,
                  albumOf: (_) => '',
                  artworkOf: (t) => t.artworkUrl,
                  playableOf: playableFromGenerated,
                  durationOf: (t) => t.durationSeconds > 0
                      ? formatDuration(Duration(
                          seconds: t.durationSeconds))
                      : '',
                  durationSortOf: (t) => t.durationSeconds,
                  titleSortOf: (t) => t.name.toLowerCase(),
                  artistSortOf: (t) => t.artist.toLowerCase(),
                  isCurrent: (t) => playingKey == t.key,
                  isPlaying: (t) {
                    final playing = ref.watch(
                      playbackServiceProvider
                          .select((p) => p.isPlaying),
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
                    sourceLabel: heroTitle,
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
