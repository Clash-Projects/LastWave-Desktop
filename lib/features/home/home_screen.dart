import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/track_actions.dart';
import '../../design_system/components.dart';
import '../../design_system/icons.dart';
import '../../design_system/tokens.dart';
import '../../features/lastfm/auth_repository.dart';
import '../../widgets/artwork.dart';
import '../../widgets/cards.dart';
import '../../widgets/skeletons.dart';
import '../../widgets/toast.dart';
import '../../widgets/track_tile.dart';
import '../common/entity_sheets.dart';
import '../feed/feed_repository.dart';
import '../innertube/innertube_api.dart';
import '../library/playlists.dart';
import '../player/playback_service.dart';
import 'home_providers.dart';

/// Editorial home: spotlight ledger + quick-access tiles + distinct
/// discovery ledgers (rail / ledger / numbered chart).
///
/// Replaces greeting-left/artwork-right hero + uniform boxed rails.
/// Hierarchy varies by section: spotlight (272 art + ledger), quick
/// picks (compact tiles), heavy rotation (rail), fresh finds (ledger
/// rows), because (2-col tiles), trending (numbered), new releases
/// (rail). Real recommendation data preserved.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(feedProvider);
    final authenticated = ref
            .watch(authRepositoryProvider)
            .status ==
        AuthStatus.signedIn;
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(feedProvider);
        ref.invalidate(newAlbumsProvider);
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
            LwSpacing.xl, LwSpacing.lg, LwSpacing.xl, 96),
        children: [
          EdPage(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                _Spotlight(feed: feed),
                const SizedBox(height: LwSpacing.lg),
                if (!authenticated) ...[
                  _ConnectLedger(),
                  const SizedBox(height: LwSpacing.lg),
                ],
                feed.when(
                  loading: () => const _FeedSkeleton(),
                  error: (e, _) => _FeedError(
                    message: '$e',
                    onRetry: () {
                      ref.invalidate(feedProvider);
                    },
                  ),
                  data: (data) =>
                      _FeedBody(data: data),
                ),
                const _AlbumRail(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Spotlight ledger: artwork left (272), metadata ledger right.
/// Inverse of old hero (text-left/art-right 196 overlay card).
class _Spotlight extends ConsumerWidget {
  final AsyncValue<FeedData> feed;
  const _Spotlight({required this.feed});

  String get _greeting {
    final h = DateTime.now().hour;
    if (h < 5) return 'Up late';
    if (h < 12) return 'Good morning';
    if (h < 18) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final data = feed.valueOrNull;
    final hero = data == null
        ? null
        : (data.heavyRotation.isNotEmpty
            ? data.heavyRotation.first
            : (data.quickPicks.isNotEmpty
                ? data.quickPicks.first
                : null));
    if (hero == null) {
      return Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          EdKicker(_greeting),
          const SizedBox(height: 4),
          const Text('Your music',
              style: LwType.display),
        ],
      );
    }
    final narrow =
        MediaQuery.sizeOf(context).width < 860;
    if (narrow) {
      return Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          EdKicker('Spotlight · $_greeting'),
          const SizedBox(height: LwSpacing.xs),
          Row(
            children: [
              Artwork(
                  url: hero.artworkUrl,
                  size: 112,
                  radius: LwRadius.lg),
              const SizedBox(width: LwSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    Text(hero.name,
                        maxLines: 2,
                        overflow:
                            TextOverflow.ellipsis,
                        style: LwType.headline
                            .copyWith(fontSize: 18)),
                    Text(hero.artist,
                        style: LwType.body.copyWith(
                            color: dark
                                ? LwColors.textSecondary
                                : LwColors
                                    .lightTextSecondary)),
                    const SizedBox(
                        height: LwSpacing.xs),
                    Row(
                      children: [
                        LwButton(
                          onPressed: () =>
                              playGenerated(
                                  ref,
                                  context,
                                  hero,
                                  sourceLabel:
                                      'Home spotlight'),
                          leading: const Icon(
                              LucideIcons.play,
                              size: 14),
                          child: const Text('Play'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      );
    }
    return Row(
      crossAxisAlignment:
          CrossAxisAlignment.start,
      children: [
        Artwork(
            url: hero.artworkUrl,
            size: LwDensity.featureArt,
            radius: LwRadius.lg),
        const SizedBox(width: LwSpacing.xl),
        Expanded(
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              EdKicker('Spotlight · $_greeting'),
              const SizedBox(height: LwSpacing.xs),
              Text(hero.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: LwType.display),
              const SizedBox(height: 4),
              Text(hero.artist,
                  style: LwType.headline.copyWith(
                      fontWeight: FontWeight.w500,
                      color: dark
                          ? LwColors.textSecondary
                          : LwColors
                              .lightTextSecondary)),
              const SizedBox(height: LwSpacing.xs),
              Text(
                'From heavy rotation · charts · fresh releases.',
                style: LwType.body.copyWith(
                    color: dark
                        ? LwColors.textSecondary
                        : LwColors
                            .lightTextSecondary),
              ),
              const SizedBox(height: LwSpacing.md),
              Row(
                children: [
                  LwButton(
                    onPressed: () => playGenerated(
                        ref, context, hero,
                        sourceLabel:
                            'Home spotlight'),
                    leading: const Icon(
                        LucideIcons.play,
                        size: 14),
                    child:
                        const Text('Play spotlight'),
                  ),
                  const SizedBox(
                      width: LwSpacing.xs),
                  LwButton.outline(
                    onPressed: () =>
                        context.go('/mixes'),
                    child: const Text('Open Mix Lab'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ConnectLedger extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: LwSpacing.md,
          vertical: LwSpacing.sm),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
              color: Theme.of(context)
                  .colorScheme
                  .primary,
              width: 2),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                const Text('Connect Last.fm',
                    style: LwType.title),
                Text(
                    'Taste profile, mixes and full discovery.',
                    style: LwType.caption.copyWith(
                        color: dark
                            ? LwColors.textSecondary
                            : LwColors
                                .lightTextSecondary)),
              ],
            ),
          ),
          LwButton(
            onPressed: () => context.go('/welcome'),
            child: const Text('Connect'),
          ),
        ],
      ),
    );
  }
}

class _FeedBody extends ConsumerWidget {
  final FeedData data;
  const _FeedBody({required this.data});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (data.isEmpty) {
      return const _FeedError(
        message: 'Nothing to show yet.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (data.quickPicks.isNotEmpty) ...[
          const EdSectionHeader(
            kicker: 'Quick',
            title: 'Jump back in',
          ),
          const SizedBox(height: LwSpacing.xs),
          _QuickLedger(tracks: data.quickPicks),
          const SizedBox(height: LwSpacing.xl),
        ],
        if (data.heavyRotation.isNotEmpty)
          _RailSection(
            kicker: 'Rotation',
            title: 'Heavy rotation',
            tracks: data.heavyRotation,
          ),
        if (data.freshFinds.isNotEmpty) ...[
          const EdSectionHeader(
            kicker: 'Discovery',
            title: 'Fresh finds',
            lede: 'Ledger rows — scan and play.',
          ),
          const SizedBox(height: LwSpacing.xs),
          const EdLedgerHeader(metaLabel: ''),
          ...data.freshFinds
              .take(6)
              .toList()
              .asMap()
              .entries
              .map((e) => _FeedTrackRow(
                  track: e.value,
                  index: e.key + 1,
                  queueAll: data.freshFinds)),
          const SizedBox(height: LwSpacing.xl),
        ],
        if (data.becauseYouListened.isNotEmpty) ...[
          const EdSectionHeader(
            kicker: 'For you',
            title: 'Because you listened',
          ),
          const SizedBox(height: LwSpacing.xs),
          _BecauseGrid(
              tracks: data.becauseYouListened),
          const SizedBox(height: LwSpacing.xl),
        ],
        if (data.charts.isNotEmpty)
          _ChartSection(tracks: data.charts),
      ],
    );
  }
}

class _FeedTrackRow extends ConsumerWidget {
  final GeneratedTrack track;
  final List<GeneratedTrack>? queueAll;
  final int index;
  const _FeedTrackRow({
    required this.track,
    this.queueAll,
    this.index = 0,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playing = ref.watch(playbackServiceProvider.select(
        (s) => s.current?.queueKey == track.key && s.isPlaying));
    final likedKeys = ref
        .watch(playlistRepositoryProvider.notifier)
        .likedKeys();
    return TrackTile(
      index: queueAll != null ? index : null,
      title: track.name,
      subtitle: track.artist,
      artworkUrl: track.artworkUrl,
      playing: playing,
      showLike: true,
      isLiked: likedKeys.contains(track.key),
      onToggleLike: () => toggleLike(
        ref,
        context,
        title: track.name,
        artist: track.artist,
        artworkUrl: track.artworkUrl,
        videoId: track.videoId,
      ),
      onTap: () => playGenerated(ref, context, track,
          sourceLabel: 'Home',
          queueAll: queueAll ?? [track],
          startIndex: queueAll == null ? 0 : index - 1),
      menu: trackMenuItems(
        ref: ref,
        title: track.name,
        artist: track.artist,
        artworkUrl: track.artworkUrl,
        videoId: track.videoId,
      ),
    );
  }
}

class _QuickLedger extends ConsumerWidget {
  final List<GeneratedTrack> tracks;
  const _QuickLedger({required this.tracks});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playingKey = ref.watch(playbackServiceProvider
        .select((s) => s.current?.queueKey));
    final items = tracks.take(6).toList();
    return LayoutBuilder(
      builder: (context, constraints) {
        final cols = constraints.maxWidth > 760 ? 3 : 2;
        final rows = (items.length / cols).ceil();
        return Column(
          children: List.generate(rows, (r) {
            return Row(
              children: List.generate(cols, (c) {
                final i = r * cols + c;
                if (i >= items.length) {
                  return const Expanded(
                      child: SizedBox());
                }
                final t = items[i];
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(
                        right: 8, bottom: 8),
                    child: QuickPickTile(
                      title: t.name,
                      subtitle: t.artist,
                      artworkUrl: t.artworkUrl,
                      playing:
                          playingKey == t.key,
                      onTap: () => playGenerated(
                          ref, context, t,
                          sourceLabel:
                              'Quick picks',
                          queueAll: items,
                          startIndex: i),
                      menu: trackMenuItems(
                        ref: ref,
                        title: t.name,
                        artist: t.artist,
                        artworkUrl: t.artworkUrl,
                        videoId: t.videoId,
                      ),
                    ),
                  ),
                );
              }),
            );
          }),
        );
      },
    );
  }
}

class _RailSection extends ConsumerWidget {
  final String kicker;
  final String title;
  final List<GeneratedTrack> tracks;
  const _RailSection(
      {required this.kicker,
      required this.title,
      required this.tracks});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        EdSectionHeader(
          kicker: kicker,
          title: title,
          actionLabel: 'Play all',
          onAction: () {
            if (tracks.isNotEmpty) {
              playGenerated(ref, context, tracks.first,
                  sourceLabel: title,
                  queueAll: tracks,
                  startIndex: 0);
            }
          },
        ),
        const SizedBox(height: LwSpacing.xs),
        SizedBox(
          height: 228,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: tracks.length,
            separatorBuilder: (_, _) =>
                const SizedBox(width: LwSpacing.md),
            itemBuilder: (context, i) {
              final t = tracks[i];
              return MediaCard(
                title: t.name,
                subtitle: t.artist,
                artworkUrl: t.artworkUrl,
                width: 168,
                staggerIndex: i,
                onTap: () => playGenerated(ref, context, t,
                    sourceLabel: title,
                    queueAll: tracks,
                    startIndex: i),
                menu: trackMenuItems(
                  ref: ref,
                  title: t.name,
                  artist: t.artist,
                  artworkUrl: t.artworkUrl,
                  videoId: t.videoId,
                ),
              );
            },
          ),
        ),
        const SizedBox(height: LwSpacing.xl),
      ],
    );
  }
}

class _BecauseGrid extends ConsumerWidget {
  final List<GeneratedTrack> tracks;
  const _BecauseGrid({required this.tracks});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playingKey = ref.watch(playbackServiceProvider
        .select((s) => s.current?.queueKey));
    final items = tracks.take(6).toList();
    return Column(
      children: [
        for (var i = 0;
            i < items.length;
            i += 2)
          Row(
            children: [
              for (var j = i;
                  j < i + 2 && j < items.length;
                  j++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(
                        right: 8, bottom: 4),
                    child: TrackTile(
                      title: items[j].name,
                      subtitle: items[j].artist,
                      artworkUrl:
                          items[j].artworkUrl,
                      playing: playingKey ==
                          items[j].key,
                      showLike: false,
                      onTap: () => playGenerated(
                          ref, context, items[j],
                          sourceLabel:
                              'Because you listened',
                          queueAll: items,
                          startIndex: j),
                      menu: trackMenuItems(
                        ref: ref,
                        title: items[j].name,
                        artist: items[j].artist,
                        artworkUrl:
                            items[j].artworkUrl,
                        videoId:
                            items[j].videoId,
                      ),
                    ),
                  ),
                ),
              if (items.length.isOdd &&
                  i + 2 > items.length)
                const Expanded(child: SizedBox()),
            ],
          ),
      ],
    );
  }
}

class _ChartSection extends ConsumerWidget {
  final List<GeneratedTrack> tracks;
  const _ChartSection({required this.tracks});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final items = tracks.take(5).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        EdSectionHeader(
          kicker: 'Charts',
          title: 'Trending now',
          actionLabel: 'Play all',
          onAction: () => playGenerated(
              ref, context, items.first,
              sourceLabel: 'Trending',
              queueAll: items),
        ),
        const SizedBox(height: LwSpacing.xs),
        ...items.asMap().entries.map((e) {
          final t = e.value;
          return InkWell(
            onTap: () => playGenerated(ref, context, t,
                sourceLabel: 'Trending',
                queueAll: items,
                startIndex: e.key),
            borderRadius:
                BorderRadius.circular(LwRadius.sm),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: LwSpacing.sm,
                  vertical: LwSpacing.xs),
              child: Row(
                children: [
                  SizedBox(
                    width: 36,
                    child: Text('${e.key + 1}',
                        style: LwType.numeral.copyWith(
                            color: e.key == 0
                                ? Theme.of(context)
                                    .colorScheme
                                    .primary
                                : (dark
                                    ? LwColors
                                        .textTertiary
                                    : LwColors
                                        .lightTextTertiary))),
                  ),
                  Artwork(
                      url: t.artworkUrl, size: 44),
                  const SizedBox(
                      width: LwSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        Text(t.name,
                            maxLines: 1,
                            overflow: TextOverflow
                                .ellipsis,
                            style: LwType.title),
                        Text(t.artist,
                            maxLines: 1,
                            overflow: TextOverflow
                                .ellipsis,
                            style: LwType.caption.copyWith(
                                color: dark
                                    ? LwColors
                                        .textSecondary
                                    : LwColors
                                        .lightTextSecondary)),
                      ],
                    ),
                  ),
                  LwFlyoutMenu(
                    tooltip: 'More',
                    icon: const Icon(
                        LucideIcons.moreHorizontal,
                        size: 15),
                    items: trackMenuItems(
                      ref: ref,
                      title: t.name,
                      artist: t.artist,
                      artworkUrl: t.artworkUrl,
                      videoId: t.videoId,
                    )
                        .map((m) => LwMenuItem(
                            label: m.label,
                            icon: m.icon,
                            onSelected:
                                m.onSelected))
                        .toList(),
                  ),
                ],
              ),
            ),
          );
        }),
        const SizedBox(height: LwSpacing.xl),
      ],
    );
  }
}

class _AlbumRail extends ConsumerWidget {
  const _AlbumRail();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albums = ref.watch(newAlbumsProvider);
    return albums.when(
      loading: () => const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          EdSectionHeader(
              kicker: 'Catalogue',
              title: 'New releases'),
          SizedBox(height: LwSpacing.xs),
          SkeletonRail(),
          SizedBox(height: LwSpacing.lg),
        ],
      ),
      error: (_, _) => const SizedBox.shrink(),
      data: (list) {
        if (list.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const EdSectionHeader(
                kicker: 'Catalogue',
                title: 'New releases'),
            const SizedBox(height: LwSpacing.xs),
            SizedBox(
              height: 228,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: list.length,
                separatorBuilder: (_, _) =>
                    const SizedBox(width: LwSpacing.md),
                itemBuilder: (context, i) {
                  final a = list[i];
                  final parts =
                      InnerTubeMusicApi.splitSubtitle(
                          a.subtitle);
                  final artist = parts.length > 1
                      ? parts[1]
                      : a.artist;
                  return MediaCard(
                    title: a.name,
                    subtitle: artist,
                    artworkUrl: a.artworkUrl,
                    width: 168,
                    staggerIndex: i,
                    onTap: () => showAlbumSheet(
                      context,
                      ref,
                      albumTitle: a.name,
                      artist: artist,
                      browseId: a.browseId,
                      artworkUrl: a.artworkUrl,
                    ),
                    onPlay: () =>
                        _playAlbum(context, ref, a),
                  );
                },
              ),
            ),
            const SizedBox(height: LwSpacing.lg),
          ],
        );
      },
    );
  }

  Future<void> _playAlbum(BuildContext context, WidgetRef ref,
      YouTubeMusicEntity album) async {
    final tracks = await ref
        .read(feedRepositoryProvider)
        .albumTracks(album);
    if (tracks.isEmpty) {
      if (context.mounted) {
        showToast(context, 'Could not load this album.');
      }
      return;
    }
    if (!context.mounted) return;
    await playGenerated(
      ref,
      context,
      tracks.first,
      sourceLabel: album.name,
      queueAll: tracks,
    );
  }
}

class _FeedSkeleton extends StatelessWidget {
  const _FeedSkeleton();
  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SkeletonFeature(),
        SizedBox(height: LwSpacing.xl),
        SkeletonBox(width: 140, height: 20),
        SizedBox(height: LwSpacing.sm),
        SkeletonRow(count: 3),
        SizedBox(height: LwSpacing.lg),
        SkeletonBox(width: 160, height: 20),
        SizedBox(height: LwSpacing.sm),
        SkeletonRail(),
      ],
    );
  }
}

class _FeedError extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;
  const _FeedError({required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding:
          const EdgeInsets.symmetric(vertical: LwSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Feed unavailable',
              style: LwType.headline),
          const SizedBox(height: 4),
          Text(message,
              style: LwType.caption.copyWith(
                  color: dark
                      ? LwColors.textSecondary
                      : LwColors.lightTextSecondary)),
          if (onRetry != null) ...[
            const SizedBox(height: LwSpacing.sm),
            LwButton.outline(
              onPressed: onRetry,
              child: const Text('Retry'),
            ),
          ],
        ],
      ),
    );
  }
}
