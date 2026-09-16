import 'package:cached_network_image/cached_network_image.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:palette_generator/palette_generator.dart';

import '../../app/track_actions.dart' show playGenerated;
import '../../features/feed/feed_repository.dart';
import '../../features/home/home_providers.dart';
import '../../features/innertube/innertube_api.dart';
import '../components/artwork.dart';
import '../components/hero.dart';
import '../components/menus.dart';
import '../components/states.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

final _discoverTintProvider =
    FutureProvider.autoDispose.family<Color?, String>((ref, url) async {
  if (url.isEmpty) return null;
  ref.keepAlive();
  try {
    final provider = CachedNetworkImageProvider(url,
        maxWidth: 128, maxHeight: 128);
    final palette = await PaletteGenerator.fromImageProvider(
      provider,
      size: const Size(64, 64),
      maximumColorCount: 8,
    );
    return palette.dominantColor?.color;
  } catch (_) {
    return null;
  }
});

const _genres = <({String name, IconData icon, Color tint, String blurb})>[
  (name: 'Pop', icon: FluentIcons.favorite_star, tint: Color(0xFFE08BB8), blurb: 'Hooks on repeat'),
  (name: 'Hip-Hop', icon: FluentIcons.microphone, tint: Color(0xFFE0A030), blurb: 'Bars & bounce'),
  (name: 'Rock', icon: FluentIcons.music_note, tint: Color(0xFFE0506A), blurb: 'Loud guitars'),
  (name: 'R&B', icon: FluentIcons.heart, tint: Color(0xFF9B7BE3), blurb: 'Slow burns'),
  (name: 'Electronic', icon: FluentIcons.speed_high, tint: Color(0xFF4FC3E8), blurb: 'Late-night pulse'),
  (name: 'Jazz', icon: FluentIcons.music_in_collection, tint: Color(0xFF7BE3A8), blurb: 'Blue notes'),
  (name: 'Classical', icon: FluentIcons.library, tint: Color(0xFFA8A6A0), blurb: 'Quiet grandeur'),
  (name: 'Indie', icon: FluentIcons.album, tint: Color(0xFF7BC8A8), blurb: 'Left of centre'),
];

/// Discover — editorial charts + moods explorer.
///
/// Distinct from Home on purpose: the hero is a 200px CHART SPOTLIGHT
/// band, trending is an 8-row ranked grid (not cards), genres are
/// artwork-backed typographic tiles (2 large + 6 small — never flat
/// 64px boxes), and new releases get a real filter/sort bar plus
/// popular-album and popular-artist shelves. All artwork and listings
/// come from the live feed; sections collapse instead of leaving gaps.
class WaveDiscoverPage extends ConsumerStatefulWidget {
  const WaveDiscoverPage({super.key});
  @override
  ConsumerState<WaveDiscoverPage> createState() =>
      _WaveDiscoverPageState();
}

class _WaveDiscoverPageState extends ConsumerState<WaveDiscoverPage> {
  final _filter = TextEditingController();
  String _q = '';
  String _sort = 'featured';

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final feed = ref.watch(feedProvider);
    final albums = ref.watch(newAlbumsProvider);
    final viewport = MediaQuery.sizeOf(context).width;

    final pad = viewport < 900 ? 16.0 : viewport < 1300 ? 24.0 : 28.0;
    final side =
        ((viewport - WaveDensity.contentMax) / 2).clamp(0, double.infinity) +
            pad;
    final trendCols = viewport < 900 ? 1 : 2;

    // One shared WinUI entrance timeline for the page: it starts when
    // the feed (or the albums feed) lands, so sections cascade together
    // and lazily-built rows never replay during scroll.
    return WaveEntranceGroup(
      start: feed.hasValue || albums.hasValue,
      child: CustomScrollView(
        slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(side, 22, side, 0),
          sliver: SliverToBoxAdapter(
            child: WaveEntrance(
              local: true,
              rise: 10,
              child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'EXPLORE',
                  style: WaveType.overline.copyWith(
                    fontSize: 10,
                    color: waveTextTertiary(context),
                  ),
                ),
                const SizedBox(height: 2),
                Text('Discover',
                    style:
                        WaveType.pageTitle.copyWith(fontSize: 24)),
                const SizedBox(height: 2),
                Text('Charts, moods and fresh records.',
                    style: WaveType.meta.copyWith(
                        color: waveTextSecondary(context))),
              ],
            ),
            ),
          ),
        ),
        feed.when(
          loading: () => SliverPadding(
            padding: EdgeInsets.fromLTRB(side, 18, side, 32),
            sliver: const SliverToBoxAdapter(
                child: _DiscoverSkeleton()),
          ),
          error: (e, _) => SliverPadding(
            padding: EdgeInsets.fromLTRB(side, 18, side, 32),
            sliver: SliverToBoxAdapter(
              child: WaveError(
                title: 'Could not load Discover',
                message: '$e',
                onRetry: () => ref.invalidate(feedProvider),
              ),
            ),
          ),
          data: (d) {
            if (d.charts.isEmpty &&
                d.heavyRotation.isEmpty &&
                d.quickPicks.isEmpty) {
              return SliverPadding(
                padding: EdgeInsets.fromLTRB(side, 18, side, 32),
                sliver: SliverToBoxAdapter(
                  child: WaveEmpty(
                    icon: WaveIcons.discover,
                    title: 'Nothing to explore',
                    subtitle:
                        'Charts are unavailable. Check your connection and retry.',
                    actionLabel: 'Retry',
                    onAction: () {
                      ref.invalidate(feedProvider);
                      ref.invalidate(newAlbumsProvider);
                    },
                  ),
                ),
              );
            }
            return _discoverSlivers(d, side, trendCols);
          },
        ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(side, 0, side, 32),
          sliver: SliverToBoxAdapter(
            child: _NewReleasesExplorer(
              albumsAsync: albums,
              filter: _filter,
              query: _q,
              sort: _sort,
              onQuery: (v) => setState(() => _q = v),
              onSort: (v) => setState(() => _sort = v ?? 'featured'),
            ),
          ),
        ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(side, 0, side, 32),
          sliver: SliverToBoxAdapter(
            child: _PopularShelves(
              feed: feed.valueOrNull,
              albums: albums.valueOrNull ?? const [],
            ),
          ),
        ),
        ],
      ),
    );
  }

  Widget _discoverSlivers(FeedData d, double side, int trendCols) {
    final slivers = <Widget>[];
    void gap(double h) {
      slivers.add(SliverToBoxAdapter(child: SizedBox(height: h)));
    }

    // Stagger slots for the page entrance cascade (one per section).
    var e = 0;
    int slot() => e++;

    if (d.charts.isNotEmpty) {
      gap(18);
      slivers.add(SliverPadding(
        padding: EdgeInsets.only(left: side, right: side),
        sliver: SliverToBoxAdapter(
          child: WaveEntrance(
            index: slot(),
            child: _SpotlightHero(track: d.charts.first),
          ),
        ),
      ));
    }

    final trending = d.charts.take(8).toList();
    if (trending.isNotEmpty) {
      gap(26);
      slivers.add(SliverPadding(
        padding: EdgeInsets.only(left: side, right: side),
        sliver: SliverToBoxAdapter(
          child: WaveEntrance(
            index: slot(),
            rise: 8,
            child: const _DiscoverHead(
            kicker: 'Charts',
            title: 'Trending Now',
            subtitle: 'Ranked by the charts feed right now.',
          ),
          ),
        ),
      ));
      slivers.add(SliverPadding(
        padding: EdgeInsets.only(left: side, right: side, top: 10),
        sliver: SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: trendCols,
            mainAxisSpacing: 2,
            crossAxisSpacing: 16,
            mainAxisExtent: 58,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, i) => WaveEntrance(
              index: i,
              rise: 10,
              child: _TrendCell(
                track: trending[i],
                rank: i + 1,
                queueAll: trending,
                index: i,
              ),
            ),
            childCount: trending.length,
          ),
        ),
      ));
    }

    gap(26);
    slivers.add(SliverPadding(
      padding: EdgeInsets.only(left: side, right: side),
      sliver: SliverToBoxAdapter(
        child: WaveEntrance(
          index: slot(),
          rise: 8,
          child: const _DiscoverHead(
          kicker: 'Moods',
          title: 'Genres & Moods',
          subtitle:
              'Artwork from what is charting — tap a tile to search it.',
        ),
        ),
      ),
    ));
    slivers.add(SliverPadding(
      padding: EdgeInsets.only(left: side, right: side, top: 10),
      sliver: SliverToBoxAdapter(
        child: WaveEntrance(
          index: slot(),
          rise: 10,
          child: _GenreMosaic(charts: d.charts),
        ),
      ),
    ));

    return SliverMainAxisGroup(slivers: slivers);
  }
}

class _DiscoverHead extends StatelessWidget {
  final String kicker;
  final String title;
  final String? subtitle;
  const _DiscoverHead({
    required this.kicker,
    required this.title,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          kicker.toUpperCase(),
          style: WaveType.overline.copyWith(
            fontSize: 10,
            color: waveTextTertiary(context),
          ),
        ),
        const SizedBox(height: 2),
        Text(title, style: WaveType.sectionTitle),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(
            subtitle!,
            style: WaveType.meta.copyWith(
              color: waveTextSecondary(context),
            ),
          ),
        ],
      ],
    );
  }
}

/// 200px CHART SPOTLIGHT band: 26px title + Play. Tint wash ≤12%.
class _SpotlightHero extends ConsumerWidget {
  final GeneratedTrack track;
  const _SpotlightHero({required this.track});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = waveIsDark(context);
    final narrow = MediaQuery.sizeOf(context).width < 720;
    final tint =
        ref.watch(_discoverTintProvider(track.artworkUrl)).valueOrNull;
    final wash = tint != null
        ? tint.withValues(alpha: 0.12)
        : (dark
            ? Colors.white.withValues(alpha: 0.04)
            : Colors.black.withValues(alpha: 0.03));
    final artSize = narrow ? 110.0 : 140.0;

    return Container(
      height: 200,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: wash,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          WaveArtwork(
              url: track.artworkUrl,
              size: artSize,
              radius: 6,
              title: track.name,
              artist: track.artist),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(FluentIcons.flashlight,
                        size: 11, color: waveTextTertiary(context)),
                    const SizedBox(width: 6),
                    Text(
                      'CHART SPOTLIGHT',
                      style: WaveType.overline.copyWith(
                        fontSize: 10,
                        color: waveTextTertiary(context),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  track.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: WaveType.pageTitle.copyWith(fontSize: 26),
                ),
                const SizedBox(height: 2),
                Text(
                  track.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: WaveType.body.copyWith(
                    color: waveTextSecondary(context),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    GestureDetector(
                      onTap: () => playGenerated(ref, context, track,
                          sourceLabel: 'Discover spotlight'),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 9),
                        decoration: BoxDecoration(
                          color: dark ? Colors.white : Colors.black,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(WaveIcons.play,
                                size: 13,
                                color: dark
                                    ? Colors.black
                                    : Colors.white),
                            const SizedBox(width: 7),
                            Text('Play',
                                style: WaveType.label.copyWith(
                                    color: dark
                                        ? Colors.black
                                        : Colors.white)),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    GestureDetector(
                      onTap: () => playGenerated(ref, context, track,
                          sourceLabel: 'Discover spotlight',
                          queueAll: [track]),
                      child: Text(
                        'Queue charts',
                        style: WaveType.label.copyWith(
                          fontSize: 11.5,
                          color: waveTextTertiary(context),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Trending as ranked numeral rows in a responsive grid — deliberately
/// not the album cards Home uses.
class _TrendCell extends ConsumerWidget {
  final GeneratedTrack track;
  final int rank;
  final List<GeneratedTrack> queueAll;
  final int index;
  const _TrendCell({
    required this.track,
    required this.rank,
    required this.queueAll,
    required this.index,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);
    return WaveContextMenu(
      items: () => waveTrackMenuItems(
        ref: ref,
        title: track.name,
        artist: track.artist,
        artworkUrl: track.artworkUrl,
        videoId: track.videoId,
      ),
      child: GestureDetector(
        onTap: () => playGenerated(ref, context, track,
            sourceLabel: 'Trending',
            queueAll: queueAll,
            startIndex: index),
        child: Container(
          height: 58,
          padding:
              const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
          color: Colors.transparent,
          child: Row(
            children: [
              SizedBox(
                width: 30,
                child: Text('$rank',
                    style: WaveType.numeral.copyWith(
                      fontSize: 20,
                      color: rank <= 3
                          ? accent
                          : (dark
                              ? WaveColors.textTertiary
                              : WaveColors.lightTextTertiary),
                    )),
              ),
              WaveArtwork(
                  url: track.artworkUrl,
                  size: 42,
                  radius: 6,
                  title: track.name,
                  artist: track.artist),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(track.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: WaveType.trackTitle
                            .copyWith(fontSize: 13)),
                    Text(track.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: WaveType.meta),
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

/// Genre mosaic: 2 large + 6 small artwork-backed tiles with
/// typography overlay. Backgrounds are live chart artwork.
class _GenreMosaic extends StatelessWidget {
  final List<GeneratedTrack> charts;
  const _GenreMosaic({required this.charts});

  String _bg(int i) =>
      charts.isEmpty ? '' : charts[i % charts.length].artworkUrl;

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context).width;
    final smallCols = viewport < 900 ? 2 : 3;
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _GenreTile(
                name: _genres[0].name,
                icon: _genres[0].icon,
                blurb: _genres[0].blurb,
                tint: _genres[0].tint,
                artworkUrl: _bg(0),
                large: true,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _GenreTile(
                name: _genres[1].name,
                icon: _genres[1].icon,
                blurb: _genres[1].blurb,
                tint: _genres[1].tint,
                artworkUrl: _bg(1),
                large: true,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        LayoutBuilder(builder: (context, c) {
          final rows =
              (_genres.length - 2 + smallCols - 1) ~/ smallCols;
          return Column(
            children: List.generate(rows, (r) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: List.generate(smallCols, (ci) {
                    final gi = 2 + r * smallCols + ci;
                    if (gi >= _genres.length) {
                      return const Expanded(child: SizedBox());
                    }
                    final g = _genres[gi];
                    return Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(
                            right: ci == smallCols - 1 ? 0 : 10),
                        child: _GenreTile(
                          name: g.name,
                          icon: g.icon,
                          blurb: g.blurb,
                          tint: g.tint,
                          artworkUrl: _bg(gi),
                          large: false,
                        ),
                      ),
                    );
                  }),
                ),
              );
            }),
          );
        }),
      ],
    );
  }
}

class _GenreTile extends StatefulWidget {
  final String name;
  final IconData icon;
  final String blurb;
  final Color tint;
  final String artworkUrl;
  final bool large;
  const _GenreTile({
    required this.name,
    required this.icon,
    required this.blurb,
    required this.tint,
    required this.artworkUrl,
    required this.large,
  });
  @override
  State<_GenreTile> createState() => _GenreTileState();
}

class _GenreTileState extends State<_GenreTile> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final height = widget.large ? 148.0 : 104.0;
    // Sharp 4–8px geometry · hover tonal change + ≤1.01 scale + arrow.
    return GestureDetector(
      onTap: () =>
          context.go('/search?q=${Uri.encodeComponent(widget.name)}'),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: AnimatedScale(
          scale: _hover ? 1.01 : 1.0,
          duration: WaveMotion.fast,
          curve: Curves.easeOutCubic,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Container(
              height: height,
              color: _hover
                  ? WaveColors.surfaceOverlay
                  : WaveColors.surface,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (widget.artworkUrl.isNotEmpty)
                    CachedNetworkImage(
                      imageUrl: widget.artworkUrl,
                      memCacheWidth: 400,
                      memCacheHeight: 300,
                      maxWidthDiskCache: 512,
                      maxHeightDiskCache: 512,
                      fit: BoxFit.cover,
                      fadeInDuration:
                          const Duration(milliseconds: 110),
                      placeholder: (context, _) => Container(
                          color: WaveColors.surfaceRaised),
                      errorWidget: (context, _, _) => Container(
                          color: WaveColors.surfaceRaised),
                    ),
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.25),
                          Colors.black.withValues(
                              alpha: _hover ? 0.84 : 0.78),
                        ],
                      ),
                    ),
                  ),
                  Container(
                      color: widget.tint.withValues(
                          alpha: _hover ? 0.16 : 0.12)),
                  Positioned(
                    left: widget.large ? 16 : 12,
                    right: widget.large ? 16 : 12,
                    bottom: widget.large ? 14 : 10,
                    top: widget.large ? 14 : 10,
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Row(
                          children: [
                            Icon(widget.icon,
                                size: widget.large ? 20 : 16,
                                color: Colors.white
                                    .withValues(alpha: 0.9)),
                            const Spacer(),
                            AnimatedOpacity(
                              duration: WaveMotion.fast,
                              opacity: _hover ? 1 : 0,
                              child: AnimatedSlide(
                                duration: WaveMotion.fast,
                                offset: _hover
                                    ? Offset.zero
                                    : const Offset(-0.25, 0),
                                child: Container(
                                  width: 26,
                                  height: 26,
                                  decoration: const BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Colors.white,
                                  ),
                                  child: const Icon(
                                    FluentIcons.chevron_right,
                                    size: 13,
                                    color: Colors.black,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        SizedBox(
                            height: widget.large ? 8 : 6),
                        Text(
                          widget.name,
                          style: (widget.large
                                  ? WaveType.pageTitle
                                  : WaveType.trackTitle)
                              .copyWith(
                            fontSize:
                                widget.large ? 20 : 14,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.blurb,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: WaveType.meta.copyWith(
                            fontSize:
                                widget.large ? 12 : 11,
                            color: Colors.white
                                .withValues(alpha: 0.7),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// New releases explorer: real filter + sort over the live browse.
class _NewReleasesExplorer extends StatelessWidget {
  final AsyncValue<List<YouTubeMusicEntity>> albumsAsync;
  final TextEditingController filter;
  final String query;
  final String sort;
  final ValueChanged<String> onQuery;
  final ValueChanged<String?> onSort;
  const _NewReleasesExplorer({
    required this.albumsAsync,
    required this.filter,
    required this.query,
    required this.sort,
    required this.onQuery,
    required this.onSort,
  });

  @override
  Widget build(BuildContext context) {
    return albumsAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (list) {
        if (list.isEmpty) return const SizedBox.shrink();
        final q = query.trim().toLowerCase();
        var items = q.isEmpty
            ? list.toList()
            : list
                .where((a) =>
                    '${a.name} ${a.artist} ${a.subtitle}'
                        .toLowerCase()
                        .contains(q))
                .toList();
        if (sort == 'az') {
          items.sort((a, b) =>
              a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        } else if (sort == 'artist') {
          items.sort((a, b) {
            final aa =
                a.artist.isNotEmpty ? a.artist : a.subtitle;
            final bb =
                b.artist.isNotEmpty ? b.artist : b.subtitle;
            return aa.toLowerCase().compareTo(bb.toLowerCase());
          });
        }
        final shown = items.take(10).toList();
        // Own provider timeline — animate locally when this section lands.
        return WaveEntrance(
          local: true,
          rise: 10,
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 26),
            const _DiscoverHead(
              kicker: 'Catalogue',
              title: 'New Releases',
              subtitle: 'Fresh records from the new-releases feed.',
            ),
            const SizedBox(height: 10),
            WaveFilterBar(
              controller: filter,
              onChanged: onQuery,
              hint: 'Filter new releases…',
              countLabel: '${shown.length} of ${list.length}',
              sortSlot: ComboBox<String>(
                value: sort,
                items: const [
                  ComboBoxItem(
                      value: 'featured',
                      child: Text('Featured')),
                  ComboBoxItem(
                      value: 'az', child: Text('Title A–Z')),
                  ComboBoxItem(
                      value: 'artist',
                      child: Text('Artist A–Z')),
                ],
                onChanged: onSort,
              ),
            ),
            const SizedBox(height: 10),
            if (shown.isEmpty)
              Text('No releases match “$query”.',
                  style: WaveType.meta.copyWith(
                      color: waveTextSecondary(context)))
            else
              SizedBox(
                height: 192,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: shown.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(width: 12),
                  itemBuilder: (context, i) {
                    final a = shown[i];
                    return GestureDetector(
                      onTap: () {
                        if (a.browseId.isNotEmpty) {
                          context.go(
                              '/album/${Uri.encodeComponent(a.browseId)}');
                        }
                      },
                      child: SizedBox(
                        width: 136,
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            WaveArtwork(
                                url: a.artworkUrl,
                                size: 136,
                                radius: 6,
                                title: a.name,
                                artist: a.artist.isNotEmpty
                                    ? a.artist
                                    : a.subtitle,
                                kind: ArtworkKind.album),
                            const SizedBox(height: 6),
                            Text(a.name,
                                maxLines: 1,
                                overflow:
                                    TextOverflow.ellipsis,
                                style: WaveType.trackTitle
                                    .copyWith(
                                        fontSize: 12.5)),
                            Text(
                                a.artist.isNotEmpty
                                    ? a.artist
                                    : a.subtitle,
                                maxLines: 1,
                                overflow:
                                    TextOverflow.ellipsis,
                                style: WaveType.meta.copyWith(
                                    fontSize: 11.5)),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
          ),
        );
      },
    );
  }
}

/// Popular albums + popular artists shelves derived from live data.
class _PopularShelves extends ConsumerWidget {
  final FeedData? feed;
  final List<YouTubeMusicEntity> albums;
  const _PopularShelves({required this.feed, required this.albums});

  List<({String name, String artwork, int rank})> _topArtists() {
    final order = <String>[];
    final art = <String, String>{};
    final counts = <String, int>{};
    final pool = <GeneratedTrack>[
      ...?feed?.charts,
      ...?feed?.heavyRotation,
      ...?feed?.quickPicks,
    ];
    for (final t in pool) {
      final key = t.artist.trim();
      if (key.isEmpty) continue;
      final low = key.toLowerCase();
      counts[low] = (counts[low] ?? 0) + 1;
      art.putIfAbsent(low, () => t.artworkUrl);
      if (!order.contains(low)) order.add(low);
    }
    final ranked = order.toList()
      ..sort((a, b) => (counts[b] ?? 0).compareTo(counts[a] ?? 0));
    final names = <String, String>{};
    for (final t in pool) {
      names.putIfAbsent(t.artist.toLowerCase(), () => t.artist);
    }
    return ranked.take(8).toList().asMap().entries.map((e) {
      final low = e.value;
      return (
        name: names[low] ?? low,
        artwork: art[low] ?? '',
        rank: e.key + 1,
      );
    }).toList();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artists = _topArtists();
    final extraAlbums =
        albums.length > 10 ? albums.skip(10).take(6).toList() : const <YouTubeMusicEntity>[];
    final rotation = feed?.heavyRotation.take(6).toList() ?? const [];
    if (artists.isEmpty && extraAlbums.isEmpty && rotation.isEmpty) {
      return const SizedBox.shrink();
    }
    // Stagger slots for the shelf cascade (one per section head).
    var e = 0;
    int slot() => e++;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (extraAlbums.isNotEmpty) ...[
          const SizedBox(height: 26),
          WaveEntrance(
            index: slot(),
            rise: 8,
            child: const _DiscoverHead(
            kicker: 'Catalogue',
            title: 'Popular Albums',
            subtitle: 'More from the new-releases feed.',
          ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 192,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: extraAlbums.length,
              separatorBuilder: (_, _) =>
                  const SizedBox(width: 12),
              itemBuilder: (context, i) {
                final a = extraAlbums[i];
                return WaveEntrance(
                  index: i,
                  rise: 10,
                  child: GestureDetector(
                  onTap: () {
                    if (a.browseId.isNotEmpty) {
                      context.go(
                          '/album/${Uri.encodeComponent(a.browseId)}');
                    }
                  },
                  child: SizedBox(
                    width: 136,
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        WaveArtwork(
                            url: a.artworkUrl,
                            size: 136,
                            radius: 6,
                            title: a.name,
                            artist: a.artist.isNotEmpty
                                ? a.artist
                                : a.subtitle,
                            kind: ArtworkKind.album),
                        const SizedBox(height: 6),
                        Text(a.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: WaveType.trackTitle
                                .copyWith(fontSize: 12.5)),
                        Text(
                            a.artist.isNotEmpty
                                ? a.artist
                                : a.subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: WaveType.meta
                                .copyWith(fontSize: 11.5)),
                      ],
                    ),
                  ),
                ),
                );
              },
            ),
          ),
        ],
        if (rotation.isNotEmpty) ...[
          const SizedBox(height: 26),
          WaveEntrance(
            index: slot(),
            rise: 8,
            child: const _DiscoverHead(
            kicker: 'Rotation',
            title: 'Popular Right Now',
            subtitle: 'Heavy rotation from your taste blend.',
          ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 214,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: rotation.length,
              separatorBuilder: (_, _) =>
                  const SizedBox(width: 14),
              itemBuilder: (context, i) {
                final t = rotation[i];
                return WaveEntrance(
                  index: i,
                  rise: 10,
                  child: GestureDetector(
                  onTap: () => playGenerated(ref, context, t,
                      sourceLabel: 'Popular right now',
                      queueAll: rotation,
                      startIndex: i),
                  child: SizedBox(
                    width: 152,
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        WaveArtwork(
                            url: t.artworkUrl,
                            size: 152,
                            radius: 6,
                            title: t.name,
                            artist: t.artist),
                        const SizedBox(height: 6),
                        Text(t.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: WaveType.trackTitle
                                .copyWith(fontSize: 12.5)),
                        Text(t.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: WaveType.meta
                                .copyWith(fontSize: 11.5)),
                      ],
                    ),
                  ),
                ),
                );
              },
            ),
          ),
        ],
        if (artists.isNotEmpty) ...[
          const SizedBox(height: 26),
          WaveEntrance(
            index: slot(),
            rise: 8,
            child: const _DiscoverHead(
            kicker: 'Voices',
            title: 'Popular Artists',
            subtitle: 'Most present across charts and rotation.',
          ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 178,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: artists.length,
              separatorBuilder: (_, _) =>
                  const SizedBox(width: 16),
              itemBuilder: (context, i) {
                final a = artists[i];
                return WaveEntrance(
                  index: i,
                  rise: 10,
                  child: GestureDetector(
                  onTap: () => context.go(
                      '/artist/${Uri.encodeComponent(a.name)}'),
                  child: SizedBox(
                    width: 120,
                    child: Column(
                      children: [
                        Stack(
                          children: [
                            WaveArtwork.circle(
                                url: a.artwork,
                                size: 120,
                                label: a.name,
                                title: a.name,
                                artist: a.name),
                            Positioned(
                              left: 0,
                              top: 0,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 3),
                                decoration: BoxDecoration(
                                  color: Colors.black
                                      .withValues(alpha: 0.7),
                                  borderRadius:
                                      BorderRadius.circular(
                                          999),
                                ),
                                child: Text('${a.rank}',
                                    style: WaveType.label
                                        .copyWith(
                                      fontSize: 11,
                                      color: Colors.white,
                                    )),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(a.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: WaveType.trackTitle
                                .copyWith(fontSize: 12.5)),
                      ],
                    ),
                  ),
                ),
                );
              },
            ),
          ),
        ],
      ],
    );
  }
}

class _DiscoverSkeleton extends StatelessWidget {
  const _DiscoverSkeleton();
  @override
  Widget build(BuildContext context) {
    final bar = waveDivider(context).withValues(alpha: 0.5);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
            height: 200,
            decoration: BoxDecoration(
                color: bar,
                borderRadius: BorderRadius.circular(10))),
        const SizedBox(height: 26),
        Container(
            width: 180,
            height: 14,
            decoration: BoxDecoration(
                color: bar,
                borderRadius: BorderRadius.circular(4))),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
                child: Container(
                    height: 148,
                    decoration: BoxDecoration(
                        color: bar,
                        borderRadius:
                            BorderRadius.circular(10)))),
            const SizedBox(width: 10),
            Expanded(
                child: Container(
                    height: 148,
                    decoration: BoxDecoration(
                        color: bar,
                        borderRadius:
                            BorderRadius.circular(10)))),
          ],
        ),
        const SizedBox(height: 10),
        for (var i = 0; i < 4; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Container(
                height: 44,
                decoration: BoxDecoration(
                    color: bar,
                    borderRadius: BorderRadius.circular(6))),
          ),
      ],
    );
  }
}



