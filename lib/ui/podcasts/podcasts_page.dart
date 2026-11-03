import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/track_actions.dart' show formatDuration, playGenerated;
import '../../core/storage/app_database.dart';
import '../../core/storage/prefs.dart';
import '../../features/player/playback_service.dart';
import '../../features/podcasts/podcast_models.dart';
import '../../features/podcasts/podcast_repository.dart';
import '../components/buttons.dart';
import '../components/image_aspect.dart';
import '../components/hero.dart';
import '../components/shelf.dart';
import '../components/states.dart';
import '../navigation/wave_nav.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

/// Home shelf. Hidden by the parent when the provider is empty or podcasts
/// are turned off — this widget still renders nothing in that case.
class PodcastHomeShelf extends ConsumerWidget {
  const PodcastHomeShelf({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shelves =
        ref.watch(podcastHomeProvider).valueOrNull ?? const <PodcastShelf>[];
    final shows = <PodcastShow>[];
    final seenShows = <String>{};
    final episodes = <PodcastEpisode>[];
    final seenEpisodes = <String>{};
    for (final shelf in shelves) {
      for (final show in shelf.shows) {
        if (seenShows.add(show.showId)) shows.add(show);
      }
      for (final episode in shelf.episodes) {
        if (seenEpisodes.add(episode.videoId)) episodes.add(episode);
      }
    }
    if (shows.isEmpty && episodes.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LWSectionHeader(
          overline: 'Listen',
          title: 'Podcasts',
          count: shows.isNotEmpty ? shows.length : episodes.length,
          actionLabel: 'See all',
          onAction: () => context.go('/podcasts'),
        ),
        const SizedBox(height: 10),
        if (shows.isNotEmpty)
          WaveRail(
            height: 228,
            itemCount: shows.length > 12 ? 12 : shows.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, i) {
              final show = shows[i];
              return SizedBox(
                width: 160,
                child: WaveMediaCard(
                  title: show.title,
                  subtitle: show.publisher.isEmpty ? 'Podcast' : show.publisher,
                  artworkUrl: show.artworkUrl,
                  onTap: () => _openShow(context, show),
                ),
              );
            },
          )
        else
          _episodeRail(
            context,
            ref,
            episodes.length > 12 ? episodes.sublist(0, 12) : episodes,
          ),
      ],
    );
  }
}

void _openShow(BuildContext context, PodcastShow show) {
  waveOpen(
    context,
    '/podcasts/${Uri.encodeComponent(show.showId)}'
    '?title=${Uri.encodeComponent(show.title)}',
  );
}

Future<void> playPodcastEpisodes(
  WidgetRef ref,
  BuildContext context,
  PodcastEpisode episode, {
  List<PodcastEpisode>? queue,
}) async {
  final repo = ref.read(podcastRepositoryProvider);
  final list = queue ?? [episode];
  for (final item in list) {
    repo.remember(item);
  }
  final tracks = list.map(trackFromEpisode).toList();
  var index = list.indexWhere((e) => e.videoId == episode.videoId);
  if (index < 0) index = 0;
  await playGenerated(
    ref,
    context,
    tracks[index],
    sourceLabel: episode.showTitle.isEmpty ? 'Podcasts' : episode.showTitle,
    queueAll: tracks,
    startIndex: index,
  );
}

/// 16:9 podcast card: native video-style cover, never squared.
class _WidePodcastCard extends StatefulWidget {
  final double aspect;
  final String title;
  final String subtitle;
  final String artworkUrl;
  final VoidCallback onTap;
  const _WidePodcastCard({
    this.aspect = 16 / 9,
    required this.title,
    required this.subtitle,
    required this.artworkUrl,
    required this.onTap,
  });

  @override
  State<_WidePodcastCard> createState() => _WidePodcastCardState();
}

class _WidePodcastCardState extends State<_WidePodcastCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedScale(
              scale: _hover ? 1.02 : 1.0,
              duration: const Duration(milliseconds: 140),
              child: AspectRatio(
                aspectRatio: widget.aspect,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(WaveRadius.artwork),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ColoredBox(
                        color: waveSurface(context),
                      ),
                      if (widget.artworkUrl.isNotEmpty)
                        CachedNetworkImage(
                          imageUrl: widget.artworkUrl,
                          fit: BoxFit.cover,
                          errorWidget: (_, _, _) => const SizedBox.shrink(),
                        ),
                      AnimatedOpacity(
                        duration: const Duration(milliseconds: 140),
                        opacity: _hover ? 1 : 0,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.35),
                          ),
                          child: Center(
                            child: Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: waveAccent(context),
                              ),
                              child: const Icon(
                                FluentIcons.play,
                                size: 16,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: WaveType.trackTitle,
            ),
            Text(
              widget.subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: WaveType.meta.copyWith(color: waveTextSecondary(context)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Horizontal rail of shows. [wide] = 16:9 cards (podcast page); the home
/// shelf keeps the square cards.
Widget _showRail(
  BuildContext context,
  List<PodcastShow> shows, {
  bool wide = false,
}) {
  return WaveRail(
    height: wide ? 196 : 228,
    itemCount: shows.length,
    separatorBuilder: (_, _) => const SizedBox(width: 12),
    itemBuilder: (context, i) {
      final show = shows[i];
      if (wide) {
        return SizedBox(
          width: 256,
          child: _WidePodcastCard(
            title: show.title,
            subtitle: show.publisher.isEmpty ? 'Podcast' : show.publisher,
            artworkUrl: show.artworkUrl,
            onTap: () => _openShow(context, show),
          ),
        );
      }
      return SizedBox(
        width: 160,
        child: WaveMediaCard(
          title: show.title,
          subtitle: show.publisher.isEmpty ? 'Podcast' : show.publisher,
          artworkUrl: show.artworkUrl,
          onTap: () => _openShow(context, show),
        ),
      );
    },
  );
}

/// Horizontal rail of episodes (cards, not a vertical list).
Widget _episodeRail(
  BuildContext context,
  WidgetRef ref,
  List<PodcastEpisode> episodes, {
  bool wide = false,
}) {
  return WaveRail(
    height: wide ? 196 : 228,
    itemCount: episodes.length,
    separatorBuilder: (_, _) => const SizedBox(width: 12),
    itemBuilder: (context, i) {
      final episode = episodes[i];
      if (wide) {
        // Each cover keeps its own shape: 16:9 stays 16:9, 1:1 stays 1:1.
        return ImageAspectBuilder(
          url: episode.artworkUrl,
          builder: (context, aspect) => SizedBox(
            width: 144 * aspect,
            child: _WidePodcastCard(
              aspect: aspect,
              title: episode.title,
              subtitle: episode.showTitle.isNotEmpty
                  ? episode.showTitle
                  : episode.publishedLabel,
              artworkUrl: episode.artworkUrl,
              onTap: () => playPodcastEpisodes(
                ref,
                context,
                episode,
                queue: episodes,
              ),
            ),
          ),
        );
      }
      return SizedBox(
        width: 160,
        child: WaveMediaCard(
          title: episode.title,
          subtitle: episode.showTitle.isNotEmpty
              ? episode.showTitle
              : episode.publishedLabel,
          artworkUrl: episode.artworkUrl,
          onTap: () => playPodcastEpisodes(
            ref,
            context,
            episode,
            queue: episodes,
          ),
        ),
      );
    },
  );
}

class WavePodcastsPage extends ConsumerStatefulWidget {
  const WavePodcastsPage({super.key});

  @override
  ConsumerState<WavePodcastsPage> createState() => _WavePodcastsPageState();
}

class _WavePodcastsPageState extends ConsumerState<WavePodcastsPage> {
  final _controller = TextEditingController();
  Timer? _debounce;
  String _query = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) setState(() => _query = value.trim());
    });
  }

  Widget _searchResults(BuildContext context) {
    final async = ref.watch(podcastSearchProvider(_query));
    return async.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: ProgressRing()),
      ),
      error: (e, _) => WaveError(
        title: 'Search failed',
        message: '$e',
        onRetry: () => ref.invalidate(podcastSearchProvider(_query)),
      ),
      data: (episodes) {
        if (episodes.isEmpty) {
          return WaveEmpty(
            icon: WaveIcons.podcasts,
            title: 'No results',
            subtitle: 'Nothing found for "$_query".',
          );
        }
        // Distinct shows found among the matching episodes.
        final seen = <String>{};
        final shows = <PodcastShow>[
          for (final e in episodes)
            if (e.showId.isNotEmpty && seen.add(e.showId))
              PodcastShow(
                showId: e.showId,
                title: e.showTitle.isEmpty ? e.title : e.showTitle,
                artworkUrl: e.artworkUrl,
              ),
        ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (shows.isNotEmpty) ...[
              LWSectionHeader(title: 'Shows'),
              const SizedBox(height: 10),
              _showRail(context, shows),
              const SizedBox(height: 22),
            ],
            LWSectionHeader(title: 'Episodes'),
            const SizedBox(height: 10),
            _episodeRail(context, ref, episodes, wide: true),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(prefsProvider).podcastsEnabled) {
      return WaveEmpty(
        icon: WaveIcons.podcasts,
        title: 'Podcasts are off',
        subtitle: 'Turn them on in Settings → Library.',
        actionLabel: 'Open settings',
        onAction: () => context.go('/settings?section=library'),
      );
    }
    final home = ref.watch(podcastHomeProvider);
    return home.when(
      loading: () => const WaveLoading(label: 'Loading podcasts…'),
      error: (e, _) => WaveError(
        title: 'Podcasts failed',
        message: '$e',
        onRetry: () => ref.invalidate(podcastHomeProvider),
      ),
      data: (shelves) {
        final visible = shelves
            .where((s) => s.shows.isNotEmpty || s.episodes.isNotEmpty)
            .toList();
        // Hero cover: first real artwork on the page (shows first), so
        // the header isn't an initials placeholder.
        var heroArt = '';
        for (final s in visible) {
          for (final show in s.shows) {
            if (show.artworkUrl.isNotEmpty) {
              heroArt = show.artworkUrl;
              break;
            }
          }
          if (heroArt.isNotEmpty) break;
        }
        if (heroArt.isEmpty) {
          for (final s in visible) {
            for (final e in s.episodes) {
              if (e.artworkUrl.isNotEmpty) {
                heroArt = e.artworkUrl;
                break;
              }
            }
            if (heroArt.isNotEmpty) break;
          }
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          children: [
            WaveCollectionHero(
              overline: 'Listen',
              title: 'Podcasts',
              meta: 'YouTube Music shows and episodes',
              artworkUrl: heroArt,
              fallbackIcon: WaveIcons.podcasts,
            ),
            const SizedBox(height: 16),
            TextBox(
              controller: _controller,
              placeholder: 'Search podcasts and episodes',
              prefix: const Padding(
                padding: EdgeInsets.only(left: 10),
                child: Icon(WaveIcons.search, size: 14),
              ),
              suffix: _controller.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(FluentIcons.clear, size: 12),
                      onPressed: () {
                        _controller.clear();
                        _debounce?.cancel();
                        setState(() => _query = '');
                      },
                    ),
              onChanged: (v) {
                setState(() {});
                _onChanged(v);
              },
            ),
            const SizedBox(height: 18),
            if (_query.isNotEmpty)
              _searchResults(context)
            else if (visible.isEmpty)
              const WaveEmpty(
                icon: WaveIcons.podcasts,
                title: 'No podcasts yet',
                subtitle: 'YouTube Music did not return any shows.',
              )
            else
              for (final shelf in visible) ...[
                LWSectionHeader(title: shelf.title),
                const SizedBox(height: 10),
                if (shelf.shows.isNotEmpty)
                  // Shows keep their square (1:1) cover; episodes are 16:9.
                  _showRail(context, shelf.shows)
                else
                  _episodeRail(context, ref, shelf.episodes, wide: true),
                const SizedBox(height: 22),
              ],
          ],
        );
      },
    );
  }
}

class WavePodcastShowPage extends ConsumerStatefulWidget {
  final String showId;
  final String fallbackTitle;
  const WavePodcastShowPage({
    super.key,
    required this.showId,
    this.fallbackTitle = '',
  });

  @override
  ConsumerState<WavePodcastShowPage> createState() =>
      _WavePodcastShowPageState();
}

class _WavePodcastShowPageState extends ConsumerState<WavePodcastShowPage> {
  final List<PodcastEpisode> _extra = [];
  String? _moreToken;
  bool _replacedToken = false;
  bool _loadingMore = false;

  @override
  void didUpdateWidget(covariant WavePodcastShowPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.showId != widget.showId) {
      _extra.clear();
      _moreToken = null;
      _replacedToken = false;
      _loadingMore = false;
    }
  }

  Future<void> _more(String? token) async {
    if (token == null || token.isEmpty || _loadingMore) return;
    setState(() => _loadingMore = true);
    final page = await ref
        .read(podcastRepositoryProvider)
        .more(widget.showId, token);
    if (!mounted) return;
    setState(() {
      _extra.addAll(page.episodes);
      _moreToken = page.continuation;
      _replacedToken = true;
      _loadingMore = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(prefsProvider).podcastsEnabled) {
      return WaveEmpty(
        icon: WaveIcons.podcasts,
        title: 'Podcasts are off',
        subtitle: 'Turn them on in Settings → Library.',
        actionLabel: 'Open settings',
        onAction: () => context.go('/settings?section=library'),
      );
    }
    ref.watch(playbackServiceProvider.select((s) => s.position.inSeconds));
    final async = ref.watch(podcastShowProvider(widget.showId));
    return async.when(
      loading: () => const WaveLoading(label: 'Loading show…'),
      error: (e, _) => WaveError(
        title: 'Could not load show',
        message: '$e',
        onRetry: () => ref.invalidate(podcastShowProvider(widget.showId)),
      ),
      data: (page) {
        if (page == null) {
          return WaveEmpty(
            icon: WaveIcons.podcasts,
            title: widget.fallbackTitle.isEmpty
                ? 'Show unavailable'
                : widget.fallbackTitle,
            subtitle: 'YouTube Music did not return this show.',
            actionLabel: 'Back to podcasts',
            onAction: () => context.go('/podcasts'),
          );
        }
        final token = _replacedToken ? _moreToken : page.continuation;
        final seen = <String>{};
        final episodes = <PodcastEpisode>[
          for (final episode in [...page.episodes, ..._extra])
            if (seen.add(episode.videoId)) episode,
        ];
        final progress = ref
            .read(podcastRepositoryProvider)
            .progressFor(episodes.map((e) => e.videoId));
        final playingId = ref.watch(
          playbackServiceProvider.select((s) => s.current?.videoId),
        );
        return ListView(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          children: [
            WaveCollectionHero(
              overline: 'Podcast',
              title: page.show.title,
              meta: [
                if (page.show.publisher.isNotEmpty) page.show.publisher,
                '${episodes.length} episodes',
              ].join(' · '),
              artworkUrl: page.show.artworkUrl,
              fallbackIcon: WaveIcons.podcasts,
              primaryActions: [
                if (episodes.isNotEmpty)
                  WavePrimaryButton(
                    label: 'Play',
                    icon: FluentIcons.play,
                    onPressed: () => playPodcastEpisodes(
                      ref,
                      context,
                      episodes.first,
                      queue: episodes,
                    ),
                  ),
              ],
            ),
            if (page.show.description.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                page.show.description,
                style: WaveType.body.copyWith(
                  color: waveTextSecondary(context),
                ),
              ),
            ],
            const SizedBox(height: 12),
            if (episodes.isEmpty)
              const WaveEmpty(
                icon: WaveIcons.podcasts,
                title: 'No episodes',
                subtitle: 'This show did not include any episodes.',
              )
            else
              for (var i = 0; i < episodes.length; i++)
                PodcastEpisodeRow(
                  episode: episodes[i],
                  index: i,
                  progress: progress[episodes[i].videoId],
                  playing: playingId == episodes[i].videoId,
                  onPlay: () => playPodcastEpisodes(
                    ref,
                    context,
                    episodes[i],
                    queue: episodes,
                  ),
                ),
            if ((token ?? '').isNotEmpty) ...[
              const SizedBox(height: 8),
              WaveGhostButton(
                label: _loadingMore ? 'Loading…' : 'Load more',
                onPressed: _loadingMore ? null : () => _more(token),
              ),
            ],
          ],
        );
      },
    );
  }
}

class PodcastEpisodeRow extends StatelessWidget {
  final PodcastEpisode episode;
  final int index;
  final PodcastProgressRow? progress;
  final bool playing;
  final VoidCallback onPlay;

  const PodcastEpisodeRow({
    super.key,
    required this.episode,
    required this.index,
    required this.onPlay,
    this.progress,
    this.playing = false,
  });

  @override
  Widget build(BuildContext context) {
    final duration = episode.durationMs <= 0
        ? ''
        : formatDuration(Duration(milliseconds: episode.durationMs));
    final meta = [
      if (episode.showTitle.isNotEmpty) episode.showTitle,
      if (episode.publishedLabel.isNotEmpty) episode.publishedLabel,
      if (duration.isNotEmpty) duration,
    ].join(' · ');
    final total = progress == null
        ? 0
        : (progress!.durationMs > 0
            ? progress!.durationMs
            : episode.durationMs);
    final fraction = progress == null || total <= 0 || progress!.completed
        ? 0.0
        : (progress!.positionMs / total).clamp(0.0, 1.0);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onPlay,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              SizedBox(
                width: 28,
                child: Text(
                  '${index + 1}',
                  style: WaveType.meta.copyWith(
                    color: playing
                        ? waveAccent(context)
                        : waveTextTertiary(context),
                  ),
                ),
              ),
              ImageAspectBuilder(
                url: episode.artworkUrl,
                builder: (context, aspect) => ClipRRect(
                  borderRadius: BorderRadius.circular(WaveRadius.artwork),
                  child: SizedBox(
                    width: 44 * aspect,
                    height: 44,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ColoredBox(color: waveHoverWash(context)),
                        if (episode.artworkUrl.isNotEmpty)
                          CachedNetworkImage(
                            imageUrl: episode.artworkUrl,
                            fit: BoxFit.cover,
                            errorWidget: (_, _, _) => const SizedBox.shrink(),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      episode.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: WaveType.trackTitle.copyWith(
                        color: playing ? waveAccent(context) : null,
                      ),
                    ),
                    if (meta.isNotEmpty)
                      Text(
                        meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: WaveType.meta.copyWith(
                          color: waveTextSecondary(context),
                        ),
                      ),
                    if (fraction > 0.02) ...[
                      const SizedBox(height: 4),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(99),
                        child: ProgressBar(
                          value: fraction * 100,
                          strokeWidth: 3,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
