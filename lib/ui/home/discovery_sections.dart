import 'package:cached_network_image/cached_network_image.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:palette_generator/palette_generator.dart';

import '../../app/track_actions.dart' show playGenerated;
import '../../core/audio/artist_parser.dart';
import '../../features/feed/feed_repository.dart';
import '../../features/home/home_providers.dart';
import '../../features/innertube/innertube_api.dart';
import '../components/artwork.dart';
import '../components/buttons.dart';
import '../components/hero.dart';
import '../components/select.dart';
import '../components/shelf.dart';
import '../navigation/wave_nav.dart';
import '../theme/tokens.dart';

final _discoveryTintProvider =
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

class DiscoverySectionHead extends StatelessWidget {
  final String kicker;
  final String title;
  final String? subtitle;

  const DiscoverySectionHead({
    super.key,
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

/// 200px CHART SPOTLIGHT banner: featured track with tint wash and one-click play.
class HomeSpotlightHero extends ConsumerWidget {
  final GeneratedTrack track;
  const HomeSpotlightHero({super.key, required this.track});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = waveIsDark(context);
    final narrow = MediaQuery.sizeOf(context).width < 720;
    final tint =
        ref.watch(_discoveryTintProvider(track.artworkUrl)).valueOrNull;
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
        borderRadius: WaveRadius.floatingRadius,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          WaveArtwork(
            url: track.artworkUrl,
            size: artSize,
            radius: WaveRadius.artwork,
            title: track.name,
            artist: track.artist,
          ),
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
                const SizedBox(height: 14),
                WavePlayPill(
                  label: 'Play Spotlight',
                  onTap: () => playGenerated(ref, context, track,
                      sourceLabel: 'Chart Spotlight'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// New releases explorer: self-contained filter bar + sort dropdown over live browse.
class HomeNewReleasesSection extends ConsumerStatefulWidget {
  const HomeNewReleasesSection({super.key});

  @override
  ConsumerState<HomeNewReleasesSection> createState() =>
      _HomeNewReleasesSectionState();
}

class _HomeNewReleasesSectionState
    extends ConsumerState<HomeNewReleasesSection> {
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
    final albumsAsync = ref.watch(newAlbumsProvider);
    final feed = ref.watch(feedProvider).valueOrNull;
    final affinities = feed?.tasteAffinities ?? const {};

    return albumsAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (list) {
        if (list.isEmpty) return const SizedBox.shrink();
        final q = _q.trim().toLowerCase();
        var items = q.isEmpty
            ? list.toList()
            : list
                .where((a) =>
                    '${a.name} ${a.artist} ${a.subtitle}'
                        .toLowerCase()
                        .contains(q))
                .toList();
        if (_sort == 'featured') {
          items = rankNewReleases(items, affinities);
        }
        if (_sort == 'az') {
          items.sort((a, b) =>
              a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        } else if (_sort == 'artist') {
          items.sort((a, b) {
            final aa =
                a.artist.isNotEmpty ? a.artist : a.subtitle;
            final bb =
                b.artist.isNotEmpty ? b.artist : b.subtitle;
            return aa.toLowerCase().compareTo(bb.toLowerCase());
          });
        }
        final shown = items.take(12).toList();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const DiscoverySectionHead(
              kicker: 'Catalogue',
              title: 'New Releases',
              subtitle: 'Fresh records from the new-releases feed.',
            ),
            const SizedBox(height: 10),
            WaveFilterBar(
              controller: _filter,
              onChanged: (v) => setState(() => _q = v),
              hint: 'Filter new releases…',
              countLabel: '${shown.length} of ${list.length}',
              sortSlot: WaveSelect<String>(
                value: _sort,
                options: const [
                  WaveSelectOption(value: 'featured', label: 'Featured'),
                  WaveSelectOption(value: 'az', label: 'Title A–Z'),
                  WaveSelectOption(value: 'artist', label: 'Artist A–Z'),
                ],
                onChanged: (v) =>
                    setState(() => _sort = v),
              ),
            ),
            const SizedBox(height: 10),
            if (shown.isEmpty)
              Text('No releases match “$_q”.',
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
                    return ReleaseCard(album: a);
                  },
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Popular albums & popular artists shelves ported from Discovery.
class HomePopularShelvesSection extends ConsumerWidget {
  const HomePopularShelvesSection({super.key});

  List<({String name, String artwork, int rank})> _topArtists(FeedData? feed) {
    final order = <String>[];
    final art = <String, String>{};
    final names = <String, String>{};
    final counts = <String, int>{};
    final pool = <GeneratedTrack>[
      ...?feed?.charts,
      ...?feed?.heavyRotation,
      ...?feed?.quickPicks,
    ];
    for (final t in pool) {
      for (final single in splitArtistCredits(t.artist)) {
        final key = single.trim();
        if (key.isEmpty) continue;
        final low = key.toLowerCase();
        counts[low] = (counts[low] ?? 0) + 1;
        art.putIfAbsent(low, () => t.artworkUrl);
        if (!order.contains(low)) order.add(low);
        names.putIfAbsent(low, () => key);
      }
    }
    final ranked = order.toList()
      ..sort((a, b) => (counts[b] ?? 0).compareTo(counts[a] ?? 0));
    return ranked.take(12).toList().asMap().entries.map((e) {
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
    final feed = ref.watch(feedProvider).valueOrNull;
    final albums = ref.watch(newAlbumsProvider).valueOrNull ?? const [];
    final artists = _topArtists(feed);

    final affinities = feed?.tasteAffinities ?? const {};
    final ranked = rankNewReleases(albums, affinities);
    final extraAlbums =
        ranked.length > 10 ? ranked.skip(10).take(8).toList() : const <YouTubeMusicEntity>[];

    if (artists.isEmpty && extraAlbums.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (extraAlbums.isNotEmpty) ...[
          const DiscoverySectionHead(
            kicker: 'Catalogue',
            title: 'Popular Albums',
            subtitle: 'New releases matched to your taste.',
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 192,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: extraAlbums.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, i) =>
                  ReleaseCard(album: extraAlbums[i]),
            ),
          ),
          const SizedBox(height: 26),
        ],
        if (artists.isNotEmpty) ...[
          const DiscoverySectionHead(
            kicker: 'Voices',
            title: 'Popular Artists',
            subtitle: 'Most present across charts and rotation.',
          ),
          const SizedBox(height: 10),
          WaveRail(
            height: 178,
            itemCount: artists.length,
            separatorBuilder: (_, _) => const SizedBox(width: 16),
            itemBuilder: (context, i) =>
                ArtistRailCard(artist: artists[i]),
          ),
        ],
      ],
    );
  }
}

/// 136px album card shared by New Releases and Popular Albums rails.
class ReleaseCard extends StatelessWidget {
  final YouTubeMusicEntity album;
  const ReleaseCard({super.key, required this.album});

  @override
  Widget build(BuildContext context) {
    final artist =
        album.artist.isNotEmpty ? album.artist : album.subtitle;
    return WavePressable(
      onTap: () {
        if (album.browseId.isNotEmpty) {
          waveOpen(
              context,
              waveAlbumLocation(
                browseId: album.browseId,
                title: album.name,
                artist: artist,
                artworkUrl: album.artworkUrl,
              ));
        }
      },
      child: SizedBox(
        width: 136,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            WaveArtwork(
              url: album.artworkUrl,
              size: 136,
              radius: WaveRadius.artwork,
              title: album.name,
              artist: artist,
              kind: ArtworkKind.album,
            ),
            const SizedBox(height: 6),
            Text(
              album.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: WaveType.trackTitle.copyWith(fontSize: 12.5),
            ),
            Text(
              artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: WaveType.meta.copyWith(fontSize: 11.5),
            ),
          ],
        ),
      ),
    );
  }
}

/// Ranked artist tile for Popular Artists rail with circular rest shape and squircle hover lift.
class ArtistRailCard extends StatefulWidget {
  final ({String name, String artwork, int rank}) artist;
  const ArtistRailCard({super.key, required this.artist});

  @override
  State<ArtistRailCard> createState() => _ArtistRailCardState();
}

class _ArtistRailCardState extends State<ArtistRailCard> {
  static const double _size = 120;
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final radius = BorderRadius.circular(
      _hover ? WaveRadius.floating : _size / 2,
    );
    final a = widget.artist;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _pressed = false;
      }),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: () =>
            waveOpen(context, '/artist/${Uri.encodeComponent(a.name)}'),
        child: SizedBox(
          width: _size,
          child: Column(
            children: [
              AnimatedScale(
                scale: _pressed ? 0.97 : (_hover ? 1.03 : 1.0),
                duration: waveMotion(context, WaveMotion.fast),
                curve: Curves.easeOutCubic,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    AnimatedContainer(
                      duration: waveMotion(context, WaveMotion.normal),
                      curve: Curves.easeOutCubic,
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        borderRadius: radius,
                        boxShadow: [
                          if (_hover) ...WaveElevation.lift(dark),
                        ],
                      ),
                      foregroundDecoration: BoxDecoration(
                        borderRadius: radius,
                        border: Border.all(color: waveDivider(context)),
                      ),
                      child: WaveArtwork(
                        url: a.artwork,
                        size: _size,
                        radius: WaveRadius.structural,
                        kind: ArtworkKind.artist,
                        label: a.name,
                        title: a.name,
                        artist: a.name,
                      ),
                    ),
                    Positioned(
                      left: 0,
                      top: 0,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.7),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '${a.rank}',
                          style: WaveType.label.copyWith(
                            fontSize: 11,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                a.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: WaveType.trackTitle.copyWith(fontSize: 12.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
