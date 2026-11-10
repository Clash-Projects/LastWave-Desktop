import 'package:flutter/foundation.dart' show listEquals;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

import '../../app/track_actions.dart'
    show playGenerated, playableFromGenerated, relativeTime;
import '../../core/artwork/official_artwork_service.dart';
import '../../core/network/network_monitor.dart';
import '../../features/feed/feed_repository.dart';
import '../../features/feed/home_blend.dart';
import '../../features/feed/genre_source.dart' show genreChartProvider;
import '../../features/feed/genre_browse.dart' show genreTracksProvider;
import '../../features/feed/home_shelf_layout.dart';
import '../../features/home/home_providers.dart';
import '../../features/innertube/innertube_api.dart';
import '../../features/innertube/yt_library_providers.dart';
import '../../features/podcasts/podcast_models.dart';
import '../../features/search/shared_providers.dart';
import '../../features/podcasts/podcast_repository.dart';
import '../../features/player/playback_service.dart';
import '../components/artwork.dart';
import '../components/buttons.dart';
import '../components/artist_line.dart';
import '../components/menus.dart';
import '../components/shelf.dart';
import '../collections/yt_shelf_page.dart';
import '../components/states.dart';
import '../navigation/wave_nav.dart';
import '../podcasts/podcasts_page.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';
import 'discovery_sections.dart';

/// Rich editorial Home — every section has a distinct representation.
///
/// Songs = compact rows · Albums = 152px artwork grid · Mixes = 220px
/// editorial cards · Charts = ranked numeral rows · New releases = dense
/// 124px grid. Real feed data only; skeletons while loading, actions on
/// empty — never a blank "Loading music…" or a giant spinner.
class WaveHomePage extends ConsumerWidget {
  const WaveHomePage({super.key});

  String get _greeting {
    final h = DateTime.now().hour;
    if (h < 5) return 'Good night';
    if (h < 12) return 'Good morning';
    if (h < 18) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(feedProvider);
    // Watched at build top (never inside the `when` branches): the
    // empty-state copy is honest about connectivity only when the
    // device state is actually observed.
    final online = ref.watch(networkMonitorProvider);
    final viewport = MediaQuery.sizeOf(context).width;

    // Native FeedScreen uses a centered 920dp content rail on phones and tablets.
    final contentWidth = viewport < 920 ? viewport : 920.0;
    const side = 16.0;
    final quickCols =
        contentWidth < 600 ? 1 : contentWidth < 840 ? 2 : 3;

    final date = DateFormat('EEEE, MMMM d').format(DateTime.now());

    // One shared WinUI entrance timeline for the whole page: it starts
    // the moment feed data lands, so sections cascade in together and
    // lazily-built rows never replay the animation during scroll.
    return Align(
      alignment: Alignment.topCenter,
      child: SizedBox(
        width: contentWidth,
        child: WaveEntranceGroup(
          start: feed.hasValue,
          child: CustomScrollView(
            slivers: [
        SliverPadding(
          padding: const EdgeInsets.only(top: 12),
          sliver: SliverToBoxAdapter(
            child: WaveEntrance(
              local: true,
              child: _Header(
                greeting: _greeting,
                date: date,
                onRefresh: () {
                  ref.invalidate(feedProvider);
                  ref.invalidate(ytHomeShelvesProvider);
                },
              ),
            ),
          ),
        ),
        feed.when(
          loading: () => SliverPadding(
            padding: EdgeInsets.fromLTRB(side, 18, side, 32),
            sliver: const SliverToBoxAdapter(child: _HomeSkeleton()),
          ),
          error: (e, _) => SliverPadding(
            padding: EdgeInsets.fromLTRB(side, 18, side, 32),
            sliver: SliverToBoxAdapter(
              child: WaveError(
                title: 'Could not load your feed',
                message: '$e',
                onRetry: () => ref.invalidate(feedProvider),
              ),
            ),
          ),
          data: (data) {
            final connected = ref.watch(ytConnectionProvider).connected;
            final ytShelves = ref.watch(ytHomeShelvesProvider);
            if (connected && ytShelves.isLoading && !ytShelves.hasValue) {
              return SliverPadding(
                padding: EdgeInsets.fromLTRB(side, 18, side, 32),
                sliver: const SliverToBoxAdapter(child: _HomeSkeleton()),
              );
            }
            final blend = connected
                ? blendHomeFeed(
                    shelves: ytShelves.valueOrNull ?? const [],
                    feed: data,
                    excluded:
                        ref.watch(databaseProvider).loadExclusionKeys(),
                  )
                : null;
            if (blend != null && blend.hasYouTube) {
              return _blendedSlivers(
                  context, ref, data, blend, side, quickCols);
            }
            if (data.isEmpty) {
              // Honest empty state: the repository recorded which legs
              // failed; offline always wins, otherwise the recorded
              // reason picks the copy — a non-network cause never says
              // "offline" and never pushes Last.fm setup on users who
              // didn't ask for it.
              final reason = resolveEmptyReason(
                online: online,
                data: data,
              );
              final copy = switch (reason) {
                FeedEmptyReason.offline => (
                    title: "You're offline",
                    subtitle:
                        'Connect to load charts and picks.',
                    action: 'Retry',
                  ),
                FeedEmptyReason.lastfmError => (
                    title: "Couldn't load your picks",
                    subtitle:
                        'Last.fm returned an error. Check your API key or retry.',
                    action: 'Check Last.fm',
                  ),
                FeedEmptyReason.chartsError => (
                    title: 'Charts are unavailable right now',
                    subtitle:
                        'YouTube charts failed to load — retry in a bit.',
                    action: 'Retry',
                  ),
                FeedEmptyReason.allFailed => (
                    title: "Couldn't reach music services",
                    subtitle:
                        'Last.fm and charts both failed — check your connection and retry.',
                    action: 'Retry',
                  ),
                _ => (
                    title: 'Nothing to play yet',
                    subtitle:
                        'Like songs, play anything, or connect YouTube Music and Home will fill in.',
                    action: 'Discover',
                  ),
              };
              return SliverPadding(
                padding: EdgeInsets.fromLTRB(side, 18, side, 32),
                sliver: SliverToBoxAdapter(
                  child: WaveEmpty(
                    icon: FluentIcons.music_note,
                    title: copy.title,
                    subtitle: copy.subtitle,
                    actionLabel: copy.action,
                    onAction: () {
                      switch (reason) {
                        case FeedEmptyReason.lastfmError:
                          context.go(
                              '/settings?section=lastfm');
                        case FeedEmptyReason.noTaste:
                          context.go('/search');
                        default:
                          ref.invalidate(feedProvider);
                      }
                    },
                  ),
                ),
              );
            }
            return _feedSlivers(context, ref, data, side);
          },
        ),
            ],
          ),
        ),
      ),
    );
  }

  /// Fixed FeedScreen structure: Infinite Radio, then Quick Access.
  /// These surfaces are above the user's configurable recommendation order.
  List<Widget> _nativeFeedPrelude(
    BuildContext context,
    WidgetRef ref,
    List<GeneratedTrack> tracks,
  ) {
    final hasHero = tracks.isNotEmpty;
    return [
      if (hasHero)
        SliverToBoxAdapter(
          child: _InfiniteRadioHero(tracks: tracks),
        ),
      SliverToBoxAdapter(
        child: _NativeQuickAccess(hasHero: hasHero),
      ),
    ];
  }

  /// Home while YouTube Music is connected: YouTube's layout and shelves,
  /// ordered by Last.fm taste. See [blendHomeFeed].
  Widget _blendedSlivers(BuildContext context, WidgetRef ref, FeedData data,
      HomeBlend blend, double side, int quickCols) {
    final layout = ref.watch(homeShelfLayoutProvider);
    final sections = <String, List<Widget>>{};
    var slot = 0;

    List<Widget> header({
      required String title,
      String? overline,
      int? count,
      String? actionLabel,
      VoidCallback? onAction,
    }) =>
        [
          const SliverToBoxAdapter(child: SizedBox(height: 28)),
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: side),
            sliver: SliverToBoxAdapter(
              child: WaveEntrance(
                index: slot++,
                rise: 8,
                child: LWSectionHeader(
                  overline: overline,
                  title: title,
                  count: count,
                  actionLabel: actionLabel,
                  onAction: onAction,
                ),
              ),
            ),
          ),
        ];

    Widget songGrid(List<GeneratedTrack> tracks) => SliverPadding(
          padding: EdgeInsets.only(left: side, right: side, top: 10),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: quickCols,
              mainAxisSpacing: 4,
              crossAxisSpacing: 8,
              mainAxisExtent: 56,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, i) => WaveEntrance(
                index: i,
                rise: 10,
                child: _QuickTile(track: tracks[i]),
              ),
              childCount: tracks.length,
            ),
          ),
        );

    Widget rail(Widget child) => SliverPadding(
          padding: EdgeInsets.only(left: side, right: side, top: 10),
          sliver: SliverToBoxAdapter(child: child),
        );

    GeneratedTrack fromYt(YouTubeMusicTrack t) => GeneratedTrack(
          name: t.title,
          artist: t.artist,
          album: t.album,
          artworkUrl: t.artworkUrl,
          videoId: t.videoId,
          durationSeconds: t.durationSeconds,
        );

    List<Widget> shelfSlivers(YtHomeShelf shelf) {
      void seeAll() =>
          context.go('/ytshelf/${Uri.encodeComponent(shelf.title)}');
      final head = header(
        title: shelf.title,
        actionLabel: 'See all',
        onAction: seeAll,
      );
      if (shelf.isTrackShelf) {
        return [
          ...head,
          songGrid(shelf.tracks.take(quickCols * 3).map(fromYt).toList()),
        ];
      }
      if (shelf.isTrackCardShelf) {
        return [
          ...head,
          rail(_YtSongCardRow(
            tracks: shelf.trackCards.take(20).map(fromYt).toList(),
            sourceLabel: shelf.title,
          )),
        ];
      }
      return [
        ...head,
        rail(_YtShelfRow(entities: shelf.entities.take(20).toList())),
      ];
    }

    final personalMix = ref.watch(personalMixProvider).valueOrNull;
    final infiniteRadioTracks = personalMix != null &&
            personalMix.tracks.isNotEmpty
        ? <GeneratedTrack>[personalMix.seed, ...personalMix.tracks]
        : blend.quickPicks;
    sections[HomeShelfId.mixes] =
        _nativeFeedPrelude(context, ref, infiniteRadioTracks);
    sections[HomeShelfId.taste] = [
      SliverToBoxAdapter(child: _NativeTasteStrip()),
    ];
    if (blend.quickPicks.isNotEmpty) {
      sections[HomeShelfId.quickPicks] = [
        SliverToBoxAdapter(
          child: _NativeQuickPicksPanel(tracks: blend.quickPicks),
        ),
      ];
    }
    if (blend.listenAgain.isNotEmpty) {
      sections[HomeShelfId.continueListening] = [
        ...header(
          title: 'Listen again',
          actionLabel: 'See all',
          onAction: () => context.go('/history'),
        ),
        rail(_YtSongCardRow(
          tracks: blend.listenAgain,
          sourceLabel: 'Listen again',
        )),
      ];
    }
    sections[HomeShelfId.youtube] = [
      for (final shelf in blend.personal) ...shelfSlivers(shelf),
    ];
    // Named after a real seed or not shown: an unexplained row is just noise.
    if (data.becauseSeed.isNotEmpty && data.becauseYouListened.length >= 3) {
      sections[HomeShelfId.because] = [
        ...header(
          overline: 'From your Last.fm',
          title: 'Because you listened to ${data.becauseSeed}',
        ),
        rail(_YtSongCardRow(
          tracks: data.becauseYouListened.take(12).toList(),
          sourceLabel: 'Because you listened to ${data.becauseSeed}',
        )),
      ];
    }
    if (blend.artists.length >= 3) {
      sections[HomeShelfId.artists] = [
        ...header(
          title: 'Artists you love',
          actionLabel: 'See all',
          onAction: () => context.go('/artists'),
        ),
        rail(_ArtistShelf(tracks: blend.artists)),
      ];
    }
    sections[HomeShelfId.youtubeMore] = [
      for (final shelf in blend.general) ...shelfSlivers(shelf),
    ];
    final activities =
        ref.watch(friendsActivityProvider).valueOrNull ?? const [];
    if (activities.isNotEmpty) {
      sections[HomeShelfId.friends] = [
        ...header(
          title: 'Friends listening',
          actionLabel: 'See all',
          onAction: () => context.go('/friends'),
        ),
        rail(_FriendsStrip(activities: activities)),
      ];
    }
    if (ref.watch(podcastHomeProvider).valueOrNull?.any(
              (s) => s.shows.isNotEmpty || s.episodes.isNotEmpty,
            ) ==
        true) {
      sections[HomeShelfId.podcasts] = [
        const SliverToBoxAdapter(child: SizedBox(height: 28)),
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: side),
          sliver: const SliverToBoxAdapter(child: PodcastHomeShelf()),
        ),
      ];
    }

    // Untouched layout: the connected order. Edited: the user's order wins.
    final edited = !listEquals(layout.order, HomeShelfCatalog.defaults);
    final order = edited ? layout.order : HomeShelfCatalog.connected;
    final prelude = sections.remove(HomeShelfId.mixes) ?? const <Widget>[];
    return SliverMainAxisGroup(slivers: [
      ...prelude,
      for (final id in order)
        if (id != HomeShelfId.mixes && !layout.hidden.contains(id))
          ...?sections[id],
      const SliverToBoxAdapter(child: SizedBox(height: 28)),
    ]);
  }

  Widget _feedSlivers(BuildContext context, WidgetRef ref, FeedData data,
      double side) {
    final layout = ref.watch(homeShelfLayoutProvider);
    final sections = <String, List<Widget>>{};
    var sink = <Widget>[];
    void use(String id) {
      sink = sections.putIfAbsent(id, () => <Widget>[]);
    }

    void gap(double h) {
      sink.add(SliverToBoxAdapter(child: SizedBox(height: h)));
    }

    // Stagger slots for the page entrance cascade (one slot per section).
    var e = 0;
    int slot() => e++;

    final personalMix = ref.watch(personalMixProvider).valueOrNull;
    final infiniteRadioTracks = personalMix != null &&
            personalMix.tracks.isNotEmpty
        ? <GeneratedTrack>[personalMix.seed, ...personalMix.tracks]
        : data.quickPicks;
    use(HomeShelfId.mixes);
    sink.addAll(_nativeFeedPrelude(context, ref, infiniteRadioTracks));

    use(HomeShelfId.taste);
    sink.add(SliverToBoxAdapter(child: _NativeTasteStrip()));

    use(HomeShelfId.quickPicks);
    if (data.quickPicks.isNotEmpty) {
      sink.add(
        SliverToBoxAdapter(
          child: _NativeQuickPicksPanel(tracks: data.quickPicks),
        ),
      );
    }

    use(HomeShelfId.continueListening);
    if (data.jumpBackIn.isNotEmpty) {
      gap(26);
      final recent = data.jumpBackIn.take(6).toList();
      sink.add(SliverPadding(
        padding: EdgeInsets.only(left: side, right: side),
        sliver: SliverToBoxAdapter(
          child: WaveEntrance(
            index: slot(),
            rise: 8,
            child: LWSectionHeader(
              overline: 'History',
              title: 'Continue Listening',
              count: recent.length,
              actionLabel: 'See all',
              onAction: () => context.go('/history'),
            ),
          ),
        ),
      ));
      sink.add(SliverPadding(
        padding: EdgeInsets.only(top: 10),
        sliver: SliverToBoxAdapter(
          child: _CoverShelf(tracks: recent, source: 'Recently played', side: side),
        ),
      ));
    }

    use(HomeShelfId.because);
    if (data.becauseYouListened.isNotEmpty) {
      gap(26);
      final mixes = data.becauseYouListened.take(3).toList();
      final becauseKicker = data.becauseSeed.isNotEmpty
          ? 'Because you listened to ${data.becauseSeed}'
          : 'Generated';
      sink.add(SliverPadding(
        padding: EdgeInsets.only(left: side, right: side),
        sliver: SliverToBoxAdapter(
          child: WaveEntrance(
            index: slot(),
            rise: 8,
              child: LWSectionHeader(
                overline: becauseKicker,
                title: 'Made For You',
                count: mixes.length,
                actionLabel: 'Open Mix Lab',
                onAction: () => context.go('/mixes'),
            ),
          ),
        ),
      ));
      sink.add(SliverPadding(
        padding: EdgeInsets.only(top: 10),
        sliver: SliverToBoxAdapter(
          child: _MixShelf(tracks: mixes, side: side),
        ),
      ));
    }

    use(HomeShelfId.albums);
    if (data.heavyRotation.isNotEmpty) {
      gap(26);
      final albums = data.heavyRotation.take(6).toList();
      sink.add(SliverPadding(
        padding: EdgeInsets.only(left: side, right: side),
        sliver: SliverToBoxAdapter(
          child: WaveEntrance(
            index: slot(),
            rise: 8,
            child: LWSectionHeader(
              overline: 'Rotation',
              title: 'Albums For You',
              count: albums.length,
              actionLabel: 'See all',
              onAction: () => context.go('/albums'),
            ),
          ),
        ),
      ));
      sink.add(SliverPadding(
        padding: EdgeInsets.only(top: 10),
        sliver: SliverToBoxAdapter(
          child: _AlbumShelf(tracks: albums, source: 'For you', side: side),
        ),
      ));
    }

    use(HomeShelfId.artists);
    // Artists For You — distinct billed artists (collabs split so
    // "Drake, Future & Metro Boomin" becomes three portrait tiles,
    // never a single tile showing an album sleeve).
    {
      final seen = <String>{};
      final artists = <GeneratedTrack>[];
      for (final t in [
        ...data.heavyRotation,
        ...data.charts,
        ...data.quickPicks
      ]) {
        for (final name
            in OfficialArtworkService.splitArtistCredits(t.artist)) {
          final key = name.toLowerCase();
          if (key.isEmpty || seen.contains(key)) continue;
          seen.add(key);
          artists.add(GeneratedTrack(
            name: name,
            artist: name,
            artworkUrl: '',
            videoId: t.videoId,
          ));
          if (artists.length >= 6) break;
        }
        if (artists.length >= 6) break;
      }
      if (artists.isNotEmpty) {
        gap(26);
        sink.add(SliverPadding(
          padding: EdgeInsets.only(left: side, right: side),
          sliver: SliverToBoxAdapter(
            child: WaveEntrance(
              index: slot(),
              rise: 8,
              child: LWSectionHeader(
                overline: 'Artists',
                title: 'Artists For You',
                count: artists.length,
                actionLabel: 'See all',
                onAction: () => context.go('/artists'),
              ),
            ),
          ),
        ));
        sink.add(SliverPadding(
          padding: EdgeInsets.only(left: side, right: side, top: 10),
          sliver: SliverToBoxAdapter(
            child: _ArtistShelf(tracks: artists),
          ),
        ));
      }
    }

    use(HomeShelfId.friends);
    // Friends Listening — real friend activity (friend → latest
    // scrobble with relative time). Hidden entirely when there is
    // nothing to show; never placeholder names or faked presence.
    {
      final activities =
          ref.watch(friendsActivityProvider).valueOrNull ??
              const [];
      if (activities.isNotEmpty) {
        gap(26);
        sink.add(SliverPadding(
          padding: EdgeInsets.only(left: side, right: side),
          sliver: SliverToBoxAdapter(
            child: WaveEntrance(
              index: slot(),
              rise: 8,
              child: LWSectionHeader(
                overline: 'Social',
                title: 'Friends Listening',
                count: activities.length,
                actionLabel: 'See all',
                onAction: () => context.go('/friends'),
              ),
            ),
          ),
        ));
        sink.add(SliverPadding(
          padding: EdgeInsets.only(left: side, right: side, top: 10),
          sliver: SliverToBoxAdapter(
            child: WaveEntrance(
              index: slot(),
              rise: 10,
              child: _FriendsStrip(activities: activities),
            ),
          ),
        ));
      }
    }

    use(HomeShelfId.charts);
    if (data.charts.isNotEmpty) {
      gap(26);
      sink.add(SliverPadding(
        padding: EdgeInsets.only(left: side, right: side),
        sliver: SliverToBoxAdapter(
          child: WaveEntrance(
            index: slot(),
            child: HomeSpotlightHero(track: data.charts.first),
          ),
        ),
      ));
      gap(26);
      final charts = data.charts.take(5).toList();
      sink.add(SliverPadding(
        padding: EdgeInsets.only(left: side, right: side),
        sliver: SliverToBoxAdapter(
          child: WaveEntrance(
            index: slot(),
            rise: 8,
            child: LWSectionHeader(
              overline: 'Charts',
              title: 'Trending Now',
              count: charts.length,
            ),
          ),
        ),
      ));
      sink.add(SliverPadding(
        padding: EdgeInsets.only(left: side, right: side, top: 6),
        sliver: SuperSliverList.builder(
          itemCount: charts.length,
          itemBuilder: (context, i) => WaveEntrance(
            index: i,
            rise: 10,
            child: _ChartRow(
                track: charts[i], rank: i + 1, queueAll: charts, index: i),
          ),
        ),
      ));
    }

    use(HomeShelfId.fresh);
    if (data.freshFinds.isNotEmpty) {
      gap(26);
      final fresh = data.freshFinds.take(5).toList();
      sink.add(SliverPadding(
        padding: EdgeInsets.only(left: side, right: side),
        sliver: SliverToBoxAdapter(
          child: WaveEntrance(
            index: slot(),
            rise: 8,
            child: LWSectionHeader(
              overline: 'Discovery',
              title: 'Fresh Finds',
              count: fresh.length,
            ),
          ),
        ),
      ));
      sink.add(SliverPadding(
        padding: EdgeInsets.only(left: side, right: side, top: 6),
        sliver: SuperSliverList.builder(
          itemCount: fresh.length,
          itemBuilder: (context, i) => WaveEntrance(
            index: i,
            rise: 10,
            child: _FreshRow(track: fresh[i]),
          ),
        ),
      ));
    }

    // use(HomeShelfId.releases);
    // gap(26);
    // sink.add(SliverPadding(
    //   padding: EdgeInsets.only(left: side, right: side),
    //   sliver: SliverToBoxAdapter(
    //     child: WaveEntrance(
    //       index: slot(),
    //       rise: 10,
    //       child: const HomeNewReleasesSection(),
    //     ),
    //   ),
    // ));

    // use(HomeShelfId.popular);
    // gap(26);
    // sink.add(SliverPadding(
    //   padding: EdgeInsets.only(left: side, right: side),
    //   sliver: SliverToBoxAdapter(
    //     child: WaveEntrance(
    //       index: slot(),
    //       rise: 10,
    //       child: const HomePopularShelvesSection(),
    //     ),
    //   ),
    // ));

    use(HomeShelfId.podcasts);
    final podcastShelves =
        ref.watch(podcastHomeProvider).valueOrNull ?? const <PodcastShelf>[];
    if (podcastShelves.any(
        (s) => s.shows.isNotEmpty || s.episodes.isNotEmpty)) {
      gap(26);
      sink.add(SliverPadding(
        padding: EdgeInsets.only(left: side, right: side),
        sliver: SliverToBoxAdapter(
          child: WaveEntrance(
            index: slot(),
            rise: 10,
            child: const PodcastHomeShelf(),
          ),
        ),
      ));
      gap(26);
    }
    final prelude = sections.remove(HomeShelfId.mixes) ?? const <Widget>[];
    final slivers = <Widget>[
      ...prelude,
      for (final id in layout.order)
        if (id != HomeShelfId.mixes && !layout.hidden.contains(id))
          ...?sections[id],
      const SliverToBoxAdapter(child: SizedBox(height: 6)),
    ];
    return SliverMainAxisGroup(slivers: slivers);
  }
}

/// Native TasteStrip adapted from LastWave-Native FeedTiles.kt.
class _NativeTasteStrip extends ConsumerStatefulWidget {
  const _NativeTasteStrip();

  @override
  ConsumerState<_NativeTasteStrip> createState() => _NativeTasteStripState();
}

class _NativeTasteStripState extends ConsumerState<_NativeTasteStrip> {
  String? _launching;
  static const _fallbackGenres = [
    'Rock', 'Indie', 'Pop', 'Electronic', 'Hip-Hop', 'R&B',
    'Synthwave', 'Alternative',
  ];

  Future<void> _startRadio(String genre) async {
    if (_launching != null) return;
    setState(() => _launching = genre);
    try {
      final tracks = await ref.read(genreTracksProvider(genre).future);
      if (!mounted) return;
      if (tracks.isEmpty) {
        context.go('/genre/${Uri.encodeComponent(genre)}?name=${Uri.encodeComponent(genre)}');
        return;
      }
      await ref.read(playbackServiceProvider.notifier).playQueue(
        tracks.map(playableFromGenerated).toList(), 0,
        sourceLabel: '$genre Radio', endlessRadio: true,
      );
    } catch (_) {
      if (mounted) {
        context.go('/genre/${Uri.encodeComponent(genre)}?name=${Uri.encodeComponent(genre)}');
      }
    } finally {
      if (mounted) setState(() => _launching = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final chart = ref.watch(genreChartProvider('overall'));
    final loaded = chart.valueOrNull?.bars.map((genre) => genre.name).toList()
        ?? const <String>[];
    final genres = loaded.isNotEmpty ? loaded : _fallbackGenres;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 3),
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: waveSurfaceRaised(context).withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(28),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('My genres', style: WaveType.sectionTitle.copyWith(
                  fontSize: 20, fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                )),
                const SizedBox(height: 2),
                Text('Tap a vibe to start instant radio',
                  style: WaveType.meta.copyWith(
                    fontSize: 12,
                    color: waveTextSecondary(context).withValues(alpha: 0.8),
                  )),
              ],
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 38,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: genres.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final genre = genres[index];
                final launching = _launching == genre;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _launching == null ? () => _startRadio(genre) : null,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                    decoration: BoxDecoration(
                      color: waveSurfaceRaised(context).withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: waveDivider(context).withValues(alpha: 0.18),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(width: 8, height: 8, decoration: BoxDecoration(
                          color: waveAccent(context), shape: BoxShape.circle,
                        )),
                        const SizedBox(width: 7),
                        Text(genre, style: WaveType.trackTitle.copyWith(
                          fontSize: 13, fontWeight: FontWeight.w700,
                        )),
                        if (launching) ...[
                          const SizedBox(width: 7),
                          Icon(FluentIcons.refresh, size: 14, color: waveAccent(context)),
                        ],
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
  }
}

/// Native QuickPicksRows: three compact tracks stacked per horizontal column.
class _NativeQuickPicksPanel extends ConsumerWidget {
  final List<GeneratedTrack> tracks;
  const _NativeQuickPicksPanel({required this.tracks});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (tracks.isEmpty) return const SizedBox.shrink();
    final width = MediaQuery.sizeOf(context).width;
    final fraction = width < 600 ? 0.88 : width < 840 ? 0.48 : 0.32;
    final currentKey = ref.watch(
      playbackServiceProvider.select((state) => state.current?.queueKey),
    );
    final columns = (tracks.length + 2) ~/ 3;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 3),
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: waveSurfaceRaised(context).withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(28),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Quick picks', style: WaveType.sectionTitle.copyWith(
                  fontSize: 20, fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                )),
                const SizedBox(height: 2),
                Text('Trending songs worth playing now',
                  style: WaveType.meta.copyWith(
                    fontSize: 12,
                    color: waveTextSecondary(context).withValues(alpha: 0.8),
                  )),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 212,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: columns,
              separatorBuilder: (_, _) => const SizedBox(width: 14),
              itemBuilder: (context, columnIndex) {
                final start = columnIndex * 3;
                final end = (start + 3).clamp(0, tracks.length).toInt();
                return SizedBox(
                  width: width * fraction,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var index = start; index < end; index++)
                        Padding(
                          padding: EdgeInsets.only(bottom: index == end - 1 ? 0 : 10),
                          child: _NativeQuickPickRow(
                            track: tracks[index], index: index, queue: tracks,
                            isCurrent: currentKey == tracks[index].key,
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _NativeQuickPickRow extends ConsumerWidget {
  final GeneratedTrack track;
  final int index;
  final List<GeneratedTrack> queue;
  final bool isCurrent;

  const _NativeQuickPickRow({
    required this.track, required this.index, required this.queue,
    required this.isCurrent,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playing = ref.watch(
      playbackServiceProvider.select((state) => state.isPlaying),
    );
    final accent = waveAccent(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => playGenerated(
        ref, context, track, sourceLabel: 'Quick picks',
        queueAll: queue, startIndex: index,
      ),
      child: Container(
        height: 64,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isCurrent ? accent.withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Stack(
              children: [
                WaveArtwork(
                  url: track.artworkUrl, videoId: track.videoId, size: 48,
                  radius: 12, title: track.name, artist: track.artist,
                  label: track.name,
                ),
                if (isCurrent && playing)
                  Positioned(
                    right: 2, bottom: 2,
                    child: Container(
                      width: 20, height: 16,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.72),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      alignment: Alignment.center,
                      child: const Icon(WaveIcons.music, size: 12, color: Colors.white),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(track.name, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: WaveType.trackTitle.copyWith(
                      fontSize: 15.5, fontWeight: FontWeight.w600,
                      color: isCurrent ? accent : null,
                    )),
                  const SizedBox(height: 3),
                  Text(track.artist, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: WaveType.meta.copyWith(
                      fontSize: 13,
                      color: waveTextSecondary(context).withValues(alpha: 0.8),
                    )),
                ],
              ),
            ),
            const SizedBox(width: 4),
            WaveOverflowButton(
              tooltip: 'Track actions',
              items: waveTrackMenuItems(
                context: context, ref: ref, title: track.name,
                artist: track.artist, artworkUrl: track.artworkUrl,
                videoId: track.videoId, album: track.album,
                durationSeconds: track.durationSeconds,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Native FeedScreen's expressive greeting header: greeting and uppercase date only.
class _Header extends StatelessWidget {
  final String greeting;
  final String date;
  final VoidCallback onRefresh;

  const _Header({
    required this.greeting,
    required this.date,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  greeting,
                  style: WaveType.pageTitle.copyWith(
                    fontSize: 32,
                    height: 38 / 32,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  date.toUpperCase(),
                  style: WaveType.meta.copyWith(
                    fontSize: 10,
                    letterSpacing: 1.3,
                    color: waveTextSecondary(context).withValues(alpha: 0.85),
                  ),
                ),
              ],
            ),
          ),
          WaveIconButton(
            tooltip: 'Refresh home feed',
            icon: const Icon(FluentIcons.refresh, size: 14),
            onPressed: onRefresh,
          ),
        ],
      ),
    );
  }
}

/// Artwork-backed 208dp Infinite Radio hero adapted from Native FeedTiles.kt.
class _InfiniteRadioHero extends ConsumerWidget {
  final List<GeneratedTrack> tracks;

  const _InfiniteRadioHero({required this.tracks});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artwork = tracks.firstWhere(
      (track) => track.artworkUrl.isNotEmpty,
      orElse: () => tracks.first,
    ).artworkUrl;
    final colors = [
      waveAccent(context).withValues(alpha: 0.22),
      waveSurfaceRaised(context).withValues(alpha: 0.55),
      waveSurfaceRaised(context),
    ];

    return Container(
      height: 208,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 3),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: waveSurfaceRaised(context).withValues(alpha: 0.5),
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(28),
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (artwork.isNotEmpty)
            Opacity(
              opacity: 0.32,
              child: CachedNetworkImage(
                imageUrl: artwork,
                fit: BoxFit.cover,
                errorWidget: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: colors,
                stops: const [0, 0.52, 1],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: waveAccent(context).withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        WaveIcons.mixes,
                        size: 12,
                        color: waveAccent(context),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        'MADE FOR YOU',
                        style: WaveType.overline.copyWith(
                          fontSize: 9,
                          letterSpacing: 1.1,
                          fontWeight: FontWeight.w800,
                          color: waveTextPrimary(context),
                        ),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Infinite Radio',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: WaveType.pageTitle.copyWith(
                        fontSize: 24,
                        letterSpacing: -0.4,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'An endless station shaped by your listening',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: WaveType.meta.copyWith(
                        color: waveTextSecondary(context),
                      ),
                    ),
                    const SizedBox(height: 10),
                    WavePlayPill(
                      onTap: () => ref
                          .read(playbackServiceProvider.notifier)
                          .playQueue(
                            tracks.map(playableFromGenerated).toList(),
                            0,
                            sourceLabel: 'Infinite Radio',
                            endlessRadio: true,
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

/// Native QuickTilesGrid translated to a horizontal, independently scrollable rail.
class _NativeQuickAccess extends StatelessWidget {
  final bool hasHero;

  const _NativeQuickAccess({required this.hasHero});

  @override
  Widget build(BuildContext context) {
    final topRadius = hasHero ? 0.0 : 28.0;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 3),
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: waveSurfaceRaised(context).withValues(alpha: 0.5),
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(topRadius),
          topRight: Radius.circular(topRadius),
          bottomLeft: const Radius.circular(28),
          bottomRight: const Radius.circular(28),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Quick access',
              style: WaveType.sectionTitle.copyWith(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.4,
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 194,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: const [
                _NativeQuickAccessTile(
                  title: 'Liked Songs',
                  subtitle: 'Your favorites',
                  route: '/liked',
                  icon: WaveIcons.liked,
                  tint: WaveColors.danger,
                ),
                SizedBox(width: 10),
                _NativeQuickAccessTile(
                  title: 'Mix Lab',
                  subtitle: 'Made for you',
                  route: '/mixes',
                  icon: WaveIcons.mixes,
                  tint: WaveColors.defaultAccent,
                ),
                SizedBox(width: 10),
                _NativeQuickAccessTile(
                  title: 'New Releases',
                  subtitle: 'Fresh drops',
                  route: '/new-releases',
                  icon: WaveIcons.albums,
                  tint: WaveColors.success,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NativeQuickAccessTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final String route;
  final IconData icon;
  final Color tint;

  const _NativeQuickAccessTile({
    required this.title,
    required this.subtitle,
    required this.route,
    required this.icon,
    required this.tint,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => context.go(route),
      child: Container(
        width: 136,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: waveSurface(context),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: waveDivider(context).withValues(alpha: 0.18),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 116,
              height: 116,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    tint.withValues(alpha: 0.22),
                    tint.withValues(alpha: 0.52),
                  ],
                ),
                borderRadius: BorderRadius.circular(14),
              ),
              alignment: Alignment.center,
              child: Icon(
                icon,
                size: 36,
                color: waveTextPrimary(context),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: WaveType.trackTitle.copyWith(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                height: 1.2,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: WaveType.meta.copyWith(
                fontSize: 11,
                color: waveTextSecondary(context).withValues(alpha: 0.8),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Horizontal card rail for a YouTube Music home carousel.
///
/// Cards navigate rather than play: the entity is a container (album,
/// playlist, radio) whose tracks are only known after another browse,
/// so tapping opens its detail page - the same route the equivalent
/// shelf on music.youtube.com takes.
class _YtShelfRow extends StatelessWidget {
  final List<YouTubeMusicEntity> entities;

  const _YtShelfRow({required this.entities});

  @override
  Widget build(BuildContext context) {
    return WaveRail(
      height: 216,
      itemCount: entities.length,
      separatorBuilder: (_, _) => const SizedBox(width: 12),
      itemBuilder: (context, i) {
        final e = entities[i];
        return SizedBox(
          width: 160,
          child: WaveMediaCard(
            title: e.name,
            subtitle: e.subtitle,
            titleFallback: e.name,
            artworkUrl: e.artworkUrl,
            onTap: () => openYtEntity(context, e),
          ),
        );
      },
    );
  }
}

/// Horizontal card rail for song cards from a YouTube Music home
/// carousel (Listen again style).
///
/// Unlike [_YtShelfRow] containers, these cards are directly playable:
/// tap (or the hover play button) starts a radio of the song - the
/// single track plus endless similar when it ends, exactly like
/// [_FreshRow]. The card's own context menu carries Play, Go to album
/// and the rest.
class _YtSongCardRow extends ConsumerWidget {
  final List<GeneratedTrack> tracks;
  final String sourceLabel;
  const _YtSongCardRow({
    required this.tracks,
    required this.sourceLabel,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void play(int i) => playGenerated(
          ref,
          context,
          tracks[i],
          sourceLabel: sourceLabel,
        );
    return WaveRail(
      height: 216,
      itemCount: tracks.length,
      separatorBuilder: (_, _) => const SizedBox(width: 12),
      itemBuilder: (context, i) {
        final t = tracks[i];
        return SizedBox(
          width: 160,
          child: WaveMediaCard(
            title: t.name,
            subtitle: t.artist,
            titleFallback: t.name,
            artist: t.artist,
            videoId: t.videoId,
            artworkUrl: t.artworkUrl,
            onTap: () => play(i),
            onPlay: () => play(i),
          ),
        );
      },
    );
  }
}

class _QuickTile extends ConsumerStatefulWidget {
  final GeneratedTrack track;
  const _QuickTile({
    required this.track,
  });
  @override
  ConsumerState<_QuickTile> createState() => _QuickTileState();
}

class _QuickTileState extends ConsumerState<_QuickTile> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);
    final playing = ref.watch(
      playbackServiceProvider.select((s) => s.current?.queueKey),
    ) == widget.track.key;

    final tile = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      // Grid tiles play just the tapped song — radio picks what
      // follows. Queuing the rest of the grid played unrelated
      // ranking neighbours instead.
      child: GestureDetector(
        onTap: () => playGenerated(ref, context, widget.track,
            sourceLabel: 'Quick picks'),
        onDoubleTap: () => playGenerated(ref, context, widget.track,
            sourceLabel: 'Quick picks'),
        child: Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          decoration: BoxDecoration(
            color: playing
                ? accent.withValues(alpha: 0.12)
                : _hover
                    ? (dark ? Colors.white : Colors.black)
                        .withValues(alpha: 0.05)
                    : Colors.transparent,
            borderRadius: WaveRadius.artworkRadius,
          ),
          child: Row(
            children: [
              Stack(
                children: [
                  WaveArtwork(
                    url: widget.track.artworkUrl,
                    videoId: widget.track.videoId,
                    size: 48,
                    radius: WaveRadius.artwork,
                    title: widget.track.name,
                    artist: widget.track.artist,
                    label: widget.track.name,
                  ),
                  if (_hover || playing)
                    Positioned.fill(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: WaveRadius.artworkRadius,
                        ),
                        child: Icon(
                          playing
                              ? WaveIcons.pause
                              : WaveIcons.play,
                          size: 16,
                          color: Colors.white,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.track.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: WaveType.trackTitle.copyWith(
                            fontSize: 12.5,
                            color: playing ? accent : null)),
                    Text(widget.track.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: WaveType.meta.copyWith(fontSize: 11.5)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return WaveContextMenu(
      items: () => waveTrackMenuItems(
        context: context,
        ref: ref,
        title: widget.track.name,
        artist: widget.track.artist,
        artworkUrl: widget.track.artworkUrl,
        videoId: widget.track.videoId,
      ),
      child: tile,
    );
  }
}

/// Continue Listening: 140px covers with timestamp meta.
class _CoverShelf extends StatelessWidget {
  final List<GeneratedTrack> tracks;
  final String source;
  final double side;
  const _CoverShelf({
    required this.tracks,
    required this.source,
    required this.side,
  });

  @override
  Widget build(BuildContext context) {
    return WaveRail(
      height: 208,
      padding: EdgeInsets.symmetric(horizontal: side),
      itemCount: tracks.length,
      separatorBuilder: (_, _) => const SizedBox(width: 14),
      itemBuilder: (context, i) => WaveEntrance(
        index: i,
        rise: 10,
        child: _CoverCard(
          track: tracks[i],
          source: source,
        ),
      ),
    );
  }
}

class _CoverCard extends ConsumerStatefulWidget {
  final GeneratedTrack track;
  final String source;
  const _CoverCard({
    required this.track,
    required this.source,
  });
  @override
  ConsumerState<_CoverCard> createState() => _CoverCardState();
}

class _CoverCardState extends ConsumerState<_CoverCard> {
  bool _hover = false;
  bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    void play() => playGenerated(ref, context, widget.track,
        sourceLabel: widget.source);
    return WaveContextMenu(
      items: () => waveTrackMenuItems(
        context: context,
        ref: ref,
        title: widget.track.name,
        artist: widget.track.artist,
        artworkUrl: widget.track.artworkUrl,
        videoId: widget.track.videoId,
      ),
      child: MouseRegion(
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
          onTap: play,
          child: SizedBox(
            width: 152,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AnimatedScale(
                  scale: _pressed ? 0.97 : (_hover ? 1.03 : 1.0),
                  duration: waveMotion(context, WaveMotion.fast),
                  curve: Curves.easeOutCubic,
                  child: AnimatedContainer(
                    duration: waveMotion(context, WaveMotion.normal),
                    curve: Curves.easeOutCubic,
                    decoration: BoxDecoration(
                      borderRadius: WaveRadius.artworkRadius,
                      boxShadow: [
                        if (_hover) ...WaveElevation.lift(dark),
                      ],
                    ),
                    child: Stack(
                      children: [
                        WaveArtwork(
                          url: widget.track.artworkUrl,
                          size: 152,
                          radius: WaveRadius.artwork,
                          title: widget.track.name,
                          artist: widget.track.artist,
                          label: widget.track.name,
                        ),
                        Positioned.fill(
                          child: AnimatedOpacity(
                            duration: waveMotion(context, WaveMotion.fast),
                            opacity: _hover ? 1 : 0,
                            child: Container(
                              decoration: BoxDecoration(
                                borderRadius:
                                    WaveRadius.artworkRadius,
                                color: Colors.black.withValues(alpha: 0.55),
                              ),
                              child: Center(
                                child: AnimatedScale(
                                  scale: _hover ? 1.0 : 0.70,
                                  duration: waveMotion(context, WaveMotion.fast),
                                  curve: Curves.easeOutBack,
                                  child: GestureDetector(
                                    onTap: play,
                                    child: Container(
                                      width: 44,
                                      height: 44,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: waveAccent(context),
                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.black
                                                .withValues(
                                                    alpha: 0.4),
                                            blurRadius: 12,
                                          ),
                                        ],
                                      ),
                                      child: Icon(
                                          WaveIcons.play,
                                          size: 18,
                                          color: waveOnAccent(context)),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(widget.track.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: WaveType.trackTitle.copyWith(fontSize: 12)),
                WaveArtistLine(
                    artist: widget.track.artist,
                    style: WaveType.meta.copyWith(fontSize: 11)),
                Text('Recently played',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: WaveType.meta.copyWith(
                      fontSize: 10.5,
                      color: waveTextTertiary(context),
                    )),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Made For You: 220px editorial mix cards — overlay treatment, distinct
/// from plain album cards.
class _MixShelf extends StatelessWidget {
  final List<GeneratedTrack> tracks;
  final double side;
  const _MixShelf({required this.tracks, required this.side});

  static const _titles = ['Daily Mix 1', 'Daily Mix 2', 'Discovery Mix'];
  static const _blurs = [
    'Your heavy rotation, sequenced',
    'Recent obsessions, extended',
    'Branches off your taste',
  ];

  @override
  Widget build(BuildContext context) {
    return WaveRail(
      height: 296,
      padding: EdgeInsets.symmetric(horizontal: side),
      itemCount: tracks.length,
      separatorBuilder: (_, _) => const SizedBox(width: 14),
      itemBuilder: (context, i) {
        final t = tracks[i];
        return WaveEntrance(
          index: i,
          rise: 10,
          child: _MixCard(
            track: t,
            title: _titles[i % _titles.length],
            blurb: _blurs[i % _blurs.length],
            badge: 'MIX 0${i + 1}',
          ),
        );
      },
    );
  }
}

class _MixCard extends ConsumerStatefulWidget {
  final GeneratedTrack track;
  final String title;
  final String blurb;
  final String badge;
  const _MixCard({
    required this.track,
    required this.title,
    required this.blurb,
    required this.badge,
  });
  @override
  ConsumerState<_MixCard> createState() => _MixCardState();
}

class _MixCardState extends ConsumerState<_MixCard> {
  bool _hover = false;
  bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);
    void play() => playGenerated(ref, context, widget.track,
        sourceLabel: widget.title);
    return WaveContextMenu(
      items: () => waveTrackMenuItems(
        context: context,
        ref: ref,
        title: widget.track.name,
        artist: widget.track.artist,
        artworkUrl: widget.track.artworkUrl,
        videoId: widget.track.videoId,
      ),
      child: MouseRegion(
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
          onTap: play,
          child: SizedBox(
            width: 220,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AnimatedScale(
                  scale: _pressed ? 0.97 : (_hover ? 1.03 : 1.0),
                  duration: waveMotion(context, WaveMotion.fast),
                  curve: Curves.easeOutCubic,
                  child: AnimatedContainer(
                    duration: waveMotion(context, WaveMotion.normal),
                    curve: Curves.easeOutCubic,
                    decoration: BoxDecoration(
                      borderRadius: WaveRadius.artworkRadius,
                      boxShadow: [
                        if (_hover) ...WaveElevation.lift(dark),
                      ],
                    ),
                    child: Stack(
                      children: [
                        WaveArtwork(
                          url: widget.track.artworkUrl,
                          videoId: widget.track.videoId,
                          size: 220,
                          radius: WaveRadius.artwork,
                          title: widget.track.name,
                          artist: widget.track.artist,
                          label: widget.track.name,
                        ),
                        Positioned.fill(
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: WaveRadius.artworkRadius,
                              color: Colors.black.withValues(alpha: 0.72),
                            ),
                          ),
                        ),
                        Positioned(
                          left: 12,
                          right: 12,
                          bottom: 10,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.badge,
                                style: WaveType.overline.copyWith(
                                  fontSize: 9.5,
                                  color: Colors.white.withValues(alpha: 0.75),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                widget.title,
                                style: WaveType.trackTitle.copyWith(
                                  fontSize: 16,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Positioned.fill(
                          child: AnimatedOpacity(
                            opacity: _hover ? 1 : 0,
                            duration: waveMotion(context, WaveMotion.fast),
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.55),
                                borderRadius: WaveRadius.artworkRadius,
                              ),
                              child: Center(
                                child: AnimatedScale(
                                  scale: _hover ? 1.0 : 0.70,
                                  duration: waveMotion(context, WaveMotion.fast),
                                  curve: Curves.easeOutBack,
                                  child: GestureDetector(
                                    onTap: play,
                                    child: Container(
                                      width: 44,
                                      height: 44,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: accent,
                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.black.withValues(
                                              alpha: 0.4,
                                            ),
                                            blurRadius: 12,
                                          ),
                                        ],
                                      ),
                                      child: Icon(
                                        WaveIcons.play,
                                        size: 18,
                                        color: onAccentFor(accent),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              Text(widget.blurb,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: WaveType.meta.copyWith(
                    color: dark
                        ? WaveColors.textSecondary
                        : WaveColors.lightTextSecondary,
                  )),
              Text('Featuring ${widget.track.artist}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: WaveType.meta.copyWith(
                    fontSize: 11,
                    color: waveTextTertiary(context),
                  )),
            ],
          ),
        ),
      ),
      ),
    );
  }
}

/// Albums For You: 152px artwork grid with hover quick-play + more.
class _AlbumShelf extends StatelessWidget {
  final List<GeneratedTrack> tracks;
  final String source;
  final double side;
  const _AlbumShelf({
    required this.tracks,
    required this.source,
    required this.side,
  });

  @override
  Widget build(BuildContext context) {
    return WaveRail(
      height: 214,
      padding: EdgeInsets.symmetric(horizontal: side),
      itemCount: tracks.length,
      separatorBuilder: (_, _) => const SizedBox(width: 14),
      itemBuilder: (context, i) => WaveEntrance(
        index: i,
        rise: 10,
        child: _AlbumCard(
          track: tracks[i],
          source: source,
        ),
      ),
    );
  }
}

class _AlbumCard extends ConsumerStatefulWidget {
  final GeneratedTrack track;
  final String source;
  const _AlbumCard({
    required this.track,
    required this.source,
  });
  @override
  ConsumerState<_AlbumCard> createState() => _AlbumCardState();
}

class _AlbumCardState extends ConsumerState<_AlbumCard> {
  bool _hover = false;
  bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    void play() => playGenerated(ref, context, widget.track,
        sourceLabel: widget.source);
    final card = MouseRegion(
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
        onTap: play,
        child: SizedBox(
          width: 152,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AnimatedScale(
                scale: _pressed ? 0.97 : (_hover ? 1.03 : 1.0),
                duration: waveMotion(context, WaveMotion.fast),
                curve: Curves.easeOutCubic,
                child: AnimatedContainer(
                  duration: waveMotion(context, WaveMotion.normal),
                  curve: Curves.easeOutCubic,
                  decoration: BoxDecoration(
                    borderRadius: WaveRadius.artworkRadius,
                    boxShadow: [
                      if (_hover) ...WaveElevation.lift(dark),
                    ],
                  ),
                  child: Stack(
                    children: [
                      WaveArtwork(
                        url: widget.track.artworkUrl,
                        videoId: widget.track.videoId,
                        size: 152,
                        radius: WaveRadius.artwork,
                        title: widget.track.name,
                        artist: widget.track.artist,
                        label: widget.track.name,
                      ),
                      Positioned.fill(
                        child: AnimatedOpacity(
                          opacity: _hover ? 1 : 0,
                          duration: waveMotion(context, WaveMotion.fast),
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.55),
                              borderRadius: WaveRadius.artworkRadius,
                            ),
                            child: Center(
                              child: AnimatedScale(
                                scale: _hover ? 1.0 : 0.70,
                                duration: waveMotion(context, WaveMotion.fast),
                                curve: Curves.easeOutBack,
                                child: GestureDetector(
                                  onTap: play,
                                  child: Container(
                                    width: 44,
                                    height: 44,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: waveAccent(context),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withValues(
                                            alpha: 0.4,
                                          ),
                                          blurRadius: 12,
                                        ),
                                      ],
                                    ),
                                    child: Icon(
                                      WaveIcons.play,
                                      size: 18,
                                      color: waveOnAccent(context),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (_hover)
                        Positioned(
                          right: 6,
                          top: 6,
                          child: WaveOverflowButton(
                            tooltip: 'More',
                            items: waveTrackMenuItems(
                              context: context,
                              ref: ref,
                              title: widget.track.name,
                              artist: widget.track.artist,
                              artworkUrl: widget.track.artworkUrl,
                              videoId: widget.track.videoId,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(widget.track.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: WaveType.trackTitle.copyWith(fontSize: 12.5)),
              WaveArtistLine(
                  artist: widget.track.artist,
                  style: WaveType.meta.copyWith(fontSize: 11.5)),
            ],
          ),
        ),
      ),
    );
    return WaveContextMenu(
      items: () => waveTrackMenuItems(
        context: context,
        ref: ref,
        title: widget.track.name,
        artist: widget.track.artist,
        artworkUrl: widget.track.artworkUrl,
        videoId: widget.track.videoId,
      ),
      child: card,
    );
  }
}

/// Trending chart treatment: 20px ranked numeral + 42px art rows.
class _ChartRow extends ConsumerWidget {
  final GeneratedTrack track;
  final int rank;
  final List<GeneratedTrack> queueAll;
  final int index;
  const _ChartRow({
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
        context: context,
        ref: ref,
        title: track.name,
        artist: track.artist,
        artworkUrl: track.artworkUrl,
        videoId: track.videoId,
      ),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
        onTap: () => playGenerated(ref, context, track,
            sourceLabel: 'Trending',
            queueAll: queueAll,
            startIndex: index),
        child: Container(
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
                      color: rank == 1
                          ? accent
                          : (dark
                              ? WaveColors.textTertiary
                              : WaveColors.lightTextTertiary),
                    )),
              ),
              WaveArtwork(
                url: track.artworkUrl,
                videoId: track.videoId,
                size: 42,
                radius: WaveRadius.artwork,
                title: track.name,
                artist: track.artist,
                label: track.name,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(track.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: WaveType.trackTitle
                            .copyWith(fontSize: 13)),
                    WaveArtistLine(
                      artist: track.artist,
                      style: WaveType.meta,
                      extraTrailingSpans: [
                        if (track.listeners.isNotEmpty)
                          TextSpan(
                            text: ' · ${track.listeners}',
                            style: WaveType.meta,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      )),
    );
  }
}

/// Fresh Finds: 40px compact rows.
class _FreshRow extends ConsumerStatefulWidget {
  final GeneratedTrack track;
  const _FreshRow({required this.track});

  @override
  ConsumerState<_FreshRow> createState() => _FreshRowState();
}

class _FreshRowState extends ConsumerState<_FreshRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final track = widget.track;
    final sourceLabel = 'Fresh finds';
    final playing = ref.watch(
          playbackServiceProvider.select((s) => s.current?.queueKey),
        ) ==
        track.key;
    void play() => playGenerated(ref, context, track,
        sourceLabel: sourceLabel);
    return WaveContextMenu(
      items: () => waveTrackMenuItems(
        context: context,
        ref: ref,
        title: track.name,
        artist: track.artist,
        artworkUrl: track.artworkUrl,
        videoId: track.videoId,
      ),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: play,
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            color: Colors.transparent,
            child: Row(
              children: [
                Stack(
                  children: [
                    WaveArtwork(
                      url: track.artworkUrl,
                      videoId: track.videoId,
                      size: 40,
                      radius: WaveRadius.artwork,
                      title: track.name,
                      artist: track.artist,
                      label: track.name,
                    ),
                    Positioned.fill(
                      child: AnimatedOpacity(
                        opacity: _hover && !playing ? 1 : 0,
                        duration: waveMotion(context, WaveMotion.fast),
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.black
                                .withValues(alpha: 0.55),
                            borderRadius:
                                WaveRadius.artworkRadius,
                          ),
                          child: GestureDetector(
                            onTap: play,
                            child: const Icon(
                                WaveIcons.play,
                                size: 16,
                                color: Colors.white),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(track.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: WaveType.trackTitle.copyWith(
                              fontSize: 13,
                              color: playing
                                  ? waveAccent(context)
                                  : null)),
                      WaveArtistLine(
                        artist: track.artist,
                        style: WaveType.meta,
                      ),
                    ],
                  ),
                ),
                if (playing)
                  Icon(WaveIcons.queue,
                      size: 14, color: waveAccent(context)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Artists For You: 120px circular artist tiles with hover ring.
class _ArtistShelf extends StatelessWidget {
  final List<GeneratedTrack> tracks;
  const _ArtistShelf({required this.tracks});
  @override
  Widget build(BuildContext context) {
    return WaveRail(
      height: 168,
      itemCount: tracks.length,
      separatorBuilder: (_, _) => const SizedBox(width: 16),
      itemBuilder: (context, i) {
        final t = tracks[i];
        return WaveEntrance(index: i, rise: 10, child: _ArtistTile(track: t));
      },
    );
  }
}

class _ArtistTile extends StatefulWidget {
  final GeneratedTrack track;
  const _ArtistTile({required this.track});
  @override
  State<_ArtistTile> createState() => _ArtistTileState();
}

class _ArtistTileState extends State<_ArtistTile> {
  /// Cover edge. The resting radius is half of it, which is a circle; the
  /// hover radius is [WaveRadius.floating] — a rounded square, one rung
  /// below a full circle (12 read as too square at this size).
  static const double _size = 112;

  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    // Hover reads as the shape relaxing: circle → rounded square (56 → 20
    // on a 112px cover), plus the app's standard ×1.03 lift. No accent
    // ring — accent means "selected/playing" everywhere else in the app.
    final radius = BorderRadius.circular(
      _hover ? WaveRadius.floating : _size / 2,
    );
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
        onTap: () => waveOpen(
            context, '/artist/${Uri.encodeComponent(widget.track.artist)}'),
        child: SizedBox(
          width: 120,
          child: Column(
            children: [
              AnimatedScale(
                scale: _pressed ? 0.97 : (_hover ? 1.03 : 1.0),
                duration: waveMotion(context, WaveMotion.fast),
                curve: Curves.easeOutCubic,
                child: AnimatedContainer(
                  duration: waveMotion(context, WaveMotion.normal),
                  curve: Curves.easeOutCubic,
                  // The clip is what animates the shape, so the artwork
                  // itself renders square (radius 0) and lets this own it.
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    boxShadow: [
                      if (_hover) ...WaveElevation.lift(dark),
                    ],
                  ),
                  // Hairline as a *foreground* decoration: a plain
                  // `border` would inset the cover by 1px (Container pads
                  // by the border width), and this keeps the ring exactly
                  // on the clip edge for both shapes.
                  foregroundDecoration: BoxDecoration(
                    borderRadius: radius,
                    border: Border.all(color: waveDivider(context)),
                  ),
                  child: WaveArtwork(
                    url: widget.track.artworkUrl,
                    size: _size,
                    radius: WaveRadius.structural,
                    kind: ArtworkKind.artist,
                    label: widget.track.artist,
                    title: widget.track.artist,
                    artist: widget.track.artist,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(widget.track.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: WaveType.trackTitle
                      .copyWith(fontSize: 12.5)),
              Text('Artist',
                  style: WaveType.meta.copyWith(
                      fontSize: 11,
                      color: waveTextTertiary(context))),
            ],
          ),
        ),
      ),
    );
  }
}

/// Friends Listening: compact 56px activity rows with avatar dot.
class _FriendsStrip extends ConsumerWidget {
  final List<FriendActivity> activities;
  const _FriendsStrip({required this.activities});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        for (var i = 0; i < activities.length; i++)
          _FriendRow(activity: activities[i]),
      ],
    );
  }
}

class _FriendRow extends ConsumerWidget {
  final FriendActivity activity;
  const _FriendRow({required this.activity});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = activity.track;
    final when = t.timestampMillis == null
        ? ''
        : relativeTime(DateTime.fromMillisecondsSinceEpoch(
            t.timestampMillis!));
    final avatar = activity.avatarUrl.isNotEmpty
        ? activity.avatarUrl
        : t.artworkUrl;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
        onTap: () => playGenerated(
          ref,
          context,
          GeneratedTrack(
            name: t.name,
            artist: t.artist,
            artworkUrl: t.artworkUrl,
          ),
          sourceLabel: 'Friends',
        ),
        child: Row(
          children: [
            WaveArtwork.circle(
              url: avatar,
              size: 44,
              label: activity.friend,
              title: activity.friend,
              upgrade: false,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  Text('${activity.friend} · ${t.name}',
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
            if (when.isNotEmpty)
              Text(when,
                  style: WaveType.meta.copyWith(
                      fontSize: 11,
                      color:
                          waveTextTertiary(context))),
          ],
        ),
      )),
    );
  }
}

class _HomeSkeleton extends StatelessWidget {
  const _HomeSkeleton();
  @override
  Widget build(BuildContext context) {
    final bar = waveDivider(context).withValues(alpha: 0.5);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
            height: 240,
            decoration: BoxDecoration(
                color: bar,
                borderRadius: WaveRadius.floatingRadius)),
        const SizedBox(height: 26),
        Container(
            width: 180,
            height: 14,
            decoration: BoxDecoration(
                color: bar,
                borderRadius: WaveRadius.tinyRadius)),
        const SizedBox(height: 10),
        for (var i = 0; i < 6; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                        color: bar,
                        borderRadius: WaveRadius.artworkRadius)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                          height: 11,
                          width: double.infinity,
                          decoration: BoxDecoration(
                              color: bar,
                              borderRadius:
                                  WaveRadius.tinyRadius)),
                      const SizedBox(height: 6),
                      Container(
                          height: 10,
                          width: 140,
                          decoration: BoxDecoration(
                              color: bar,
                              borderRadius:
                                  WaveRadius.tinyRadius)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 26),
        Container(
            height: 140,
            decoration: BoxDecoration(
                color: bar,
                borderRadius: WaveRadius.artworkRadius)),
      ],
    );
  }
}



