import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/track_actions.dart' show formatDuration, playGenerated;
import '../../core/storage/app_database.dart';
import '../../core/storage/prefs.dart';
import '../../features/player/playback_service.dart';
import '../../features/podcasts/podcast_models.dart';
import '../../features/podcasts/podcast_repository.dart';
import '../components/artwork.dart';
import '../components/buttons.dart';
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
    final visible = shelves
        .where((s) => s.shows.isNotEmpty || s.episodes.isNotEmpty)
        .toList();
    if (visible.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var s = 0; s < visible.length; s++) ...[
          if (s > 0) const SizedBox(height: 22),
          LWSectionHeader(
            overline: s == 0 ? 'Listen' : null,
            title: visible[s].title.isEmpty ? 'Podcasts' : visible[s].title,
            count: visible[s].shows.isNotEmpty
                ? visible[s].shows.length
                : visible[s].episodes.length,
            actionLabel: s == 0 ? 'See all' : null,
            onAction: s == 0 ? () => context.go('/podcasts') : null,
          ),
          const SizedBox(height: 10),
          if (visible[s].shows.isNotEmpty)
            WaveRail(
              height: 228,
              itemCount: visible[s].shows.length > 12
                  ? 12
                  : visible[s].shows.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, i) {
                final show = visible[s].shows[i];
                return SizedBox(
                  width: 160,
                  child: WaveMediaCard(
                    title: show.title,
                    subtitle:
                        show.publisher.isEmpty ? 'Podcast' : show.publisher,
                    artworkUrl: show.artworkUrl,
                    onTap: () => _openShow(context, show),
                  ),
                );
              },
            )
          else
            for (var i = 0; i < visible[s].episodes.take(4).length; i++)
              PodcastEpisodeRow(
                episode: visible[s].episodes[i],
                index: i,
                onPlay: () => playPodcastEpisodes(
                  ref,
                  context,
                  visible[s].episodes[i],
                  queue: visible[s].episodes,
                ),
              ),
        ],
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

class WavePodcastsPage extends ConsumerWidget {
  const WavePodcastsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
        return ListView(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          children: [
            const WaveCollectionHero(
              overline: 'Listen',
              title: 'Podcasts',
              meta: 'YouTube Music shows and episodes',
              fallbackIcon: WaveIcons.podcasts,
            ),
            const SizedBox(height: 16),
            if (visible.isEmpty)
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
                  WaveRail(
                    height: 228,
                    itemCount: shelf.shows.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 12),
                    itemBuilder: (context, i) {
                      final show = shelf.shows[i];
                      return SizedBox(
                        width: 160,
                        child: WaveMediaCard(
                          title: show.title,
                          subtitle: show.publisher.isEmpty
                              ? 'Podcast'
                              : show.publisher,
                          artworkUrl: show.artworkUrl,
                          onTap: () => _openShow(context, show),
                        ),
                      );
                    },
                  )
                else
                  for (var i = 0; i < shelf.episodes.length; i++)
                    PodcastEpisodeRow(
                      episode: shelf.episodes[i],
                      index: i,
                      onPlay: () => playPodcastEpisodes(
                        ref,
                        context,
                        shelf.episodes[i],
                        queue: shelf.episodes,
                      ),
                    ),
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
              WaveArtwork(
                url: episode.artworkUrl,
                videoId: episode.videoId,
                size: 44,
                label: episode.title,
                title: episode.title,
                artist: episode.showTitle,
                upgrade: false,
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
