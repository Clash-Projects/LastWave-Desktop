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
import '../../features/home/home_providers.dart';
import '../../features/innertube/innertube_api.dart';
import '../../features/innertube/yt_library_providers.dart';
import '../../features/lastfm/auth_repository.dart';
import '../../features/player/playback_service.dart';
import '../components/ambient.dart';
import '../components/artwork.dart';
import '../components/buttons.dart';
import '../components/artist_line.dart';
import '../components/menus.dart';
import '../components/shelf.dart';
import '../collections/yt_shelf_page.dart';
import '../components/states.dart';
import '../navigation/wave_nav.dart';
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
    if (h < 5) return 'Up late';
    if (h < 12) return 'Good morning';
    if (h < 18) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(feedProvider);
    final auth = ref.watch(authRepositoryProvider);
    // Watched at build top (never inside the `when` branches): the
    // empty-state copy is honest about connectivity only when the
    // device state is actually observed.
    final online = ref.watch(networkMonitorProvider);
    final viewport = MediaQuery.sizeOf(context).width;

    // Responsive shell: <900 single col, 900–1300 two col, 1300+ three col,
    // content capped at 1280 and centered.
    final pad = viewport < 900 ? 16.0 : viewport < 1300 ? 24.0 : 28.0;
    final side =
        ((viewport - WaveDensity.contentMax) / 2).clamp(0, double.infinity) +
            pad;
    final quickCols = viewport < 900 ? 1 : viewport < 1300 ? 2 : 3;

    final username = auth.status == AuthStatus.signedIn &&
            auth.username.isNotEmpty
        ? auth.username
        : '';
    final date = DateFormat('EEEE, MMM d').format(DateTime.now());

    // One shared WinUI entrance timeline for the whole page: it starts
    // the moment feed data lands, so sections cascade in together and
    // lazily-built rows never replay the animation during scroll.
    return WaveEntranceGroup(
      start: feed.hasValue,
      child: CustomScrollView(
        slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(side, 22, side, 0),
          sliver: SliverToBoxAdapter(
            child: WaveEntrance(
              local: true,
              child: _Header(
                greeting: _greeting,
                username: username,
                date: date,
                signedIn: auth.status == AuthStatus.signedIn,
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
            return _feedSlivers(context, ref, data, side, quickCols);
          },
        ),
        ],
      ),
    );
  }

  Widget _feedSlivers(BuildContext context, WidgetRef ref, FeedData data,
      double side, int quickCols) {
    final slivers = <Widget>[];
    void gap(double h) {
      slivers.add(SliverToBoxAdapter(child: SizedBox(height: h)));
    }

    // Stagger slots for the page entrance cascade (one slot per section).
    var e = 0;
    int slot() => e++;

    // Editorial hero: large personal pick (35–45% artwork) + 2–4 compact
    // companions on the right. Structure, not one giant banner.
    //
    // YouTube Music personal mix wins when available: hero = mix seed,
    // Play queues the whole radio list (coherent Up Next at last) —
    // otherwise the Last.fm chart-top fallback below.
    GeneratedTrack? hero;
    List<GeneratedTrack> companions = const [];
    List<GeneratedTrack> heroQueue = const [];
    String heroKicker = 'FOR YOU · FEATURED MIX';
    final mix = ref.watch(personalMixProvider).valueOrNull;
    if (mix != null && mix.tracks.isNotEmpty) {
      hero = mix.seed;
      heroQueue = [mix.seed, ...mix.tracks];
      companions = mix.tracks.take(3).toList();
      heroKicker = 'FOR YOU · YOUTUBE MUSIC MIX';
    } else if (data.heavyRotation.isNotEmpty) {
      hero = data.heavyRotation.first;
      companions = [
        ...data.quickPicks.take(2),
        ...data.charts.take(2),
      ].take(3).toList();
    } else if (data.quickPicks.isNotEmpty) {
      hero = data.quickPicks.first;
      companions = [
        ...data.quickPicks.skip(1).take(2),
        ...data.charts.take(2),
      ].take(3).toList();
    } else if (data.charts.isNotEmpty) {
      hero = data.charts.first;
      companions = data.charts.skip(1).take(3).toList();
    }
    if (hero != null) {
      gap(18);
      final heroTrack = hero;
      slivers.add(SliverPadding(
        padding: EdgeInsets.only(left: side, right: side),
        sliver: SliverToBoxAdapter(
          child: WaveEntrance(
            index: slot(),
            child: _FeaturedHero(
              track: heroTrack,
              upNext: companions,
              kicker: heroKicker,
              queueAll: heroQueue,
            ),
          ),
        ),
      ));
    }

    // YouTube Music's own home shelves, straight from the account. The
    // feed above is taste-scored (Last.fm when configured, otherwise
    // YT + on-device signals) - these are the editorial shelves
    // music.youtube.com itself would show, which the scored feed does
    // not carry. Empty (section omitted) when signed out or on failure.
    final ytShelves = ref.watch(ytHomeShelvesProvider).valueOrNull ?? const [];
    for (final shelf in ytShelves) {
      if (!shelf.isRenderable || shelf.title.isEmpty) continue;
      // A shelf is a taste, not a library: cap what one section pulls onto the
      // page at six, like every other Home shelf. The header counts the whole
      // shelf and See all opens the rest, so the rail stays a summary without
      // the number going stale.
      const cap = 6;
      // The shelf's playable tracks, if it has any — a shelf of albums or
      // artists has nothing to queue, so it keeps the bare count.
      final shelfTracks = <GeneratedTrack>[
        if (shelf.isTrackShelf)
          for (final t in shelf.tracks)
            GeneratedTrack(
              name: t.title,
              artist: t.artist,
              album: t.album,
              artworkUrl: t.artworkUrl,
              videoId: t.videoId,
              durationSeconds: t.durationSeconds,
            )
        else if (shelf.isTrackCardShelf)
          for (final t in shelf.trackCards)
            GeneratedTrack(
              name: t.title,
              artist: t.artist,
              album: t.album,
              artworkUrl: t.artworkUrl,
              videoId: t.videoId,
              durationSeconds: t.durationSeconds,
            ),
      ].take(cap).toList();
      final shelfEntities = shelf.entities.take(cap).toList();
      gap(26);
      slivers.add(SliverPadding(
        padding: EdgeInsets.only(left: side, right: side),
        sliver: SliverToBoxAdapter(
          child: WaveEntrance(
            index: slot(),
            rise: 8,
            child: _SectionHead(
              kicker: 'YouTube Music',
              title: shelf.title,
              // The rail is capped; the header counts the whole shelf, and
              // See all is where the rest of it lives.
              count: shelf.isTrackShelf
                  ? shelf.tracks.length
                  : shelf.isTrackCardShelf
                      ? shelf.trackCards.length
                      : shelf.entities.length,
              actionLabel: 'See all',
              actionPath: '/ytshelf/${Uri.encodeComponent(shelf.title)}',
            ),
          ),
        ),
      ));
      if (shelf.isTrackShelf) {
        slivers.add(SliverPadding(
          padding: EdgeInsets.only(left: side, right: side, top: 6),
          sliver: SuperSliverList.builder(
            itemCount: shelfTracks.length,
            itemBuilder: (context, i) => WaveEntrance(
              index: i,
              rise: 10,
              child: _FreshRow(
                track: shelfTracks[i],
                sourceLabel: shelf.title,
              ),
            ),
          ),
        ));
      } else if (shelf.trackCards.isNotEmpty) {
        // Song cards (Listen again style): these are playable tracks,
        // not containers - tapping plays, like every other song
        // surface. The card menu (Play, Go to album, …) comes from
        // WaveMediaCard itself once artist + videoId are set.
        slivers.add(SliverPadding(
          padding: EdgeInsets.only(left: side, right: side, top: 10),
          sliver: SliverToBoxAdapter(
            child: _YtSongCardRow(
              tracks: shelfTracks,
              sourceLabel: shelf.title,
            ),
          ),
        ));
      } else {
        slivers.add(SliverPadding(
          padding: EdgeInsets.only(left: side, right: side, top: 10),
          sliver: SliverToBoxAdapter(
            child: _YtShelfRow(entities: shelfEntities),
          ),
        ));
      }
    }

    if (data.quickPicks.isNotEmpty) {
      gap(26);
      final picks = data.quickPicks.take(6).toList();
      slivers.add(SliverPadding(
        padding: EdgeInsets.only(left: side, right: side),
        sliver: SliverToBoxAdapter(
          child: WaveEntrance(
            index: slot(),
            rise: 8,
            child: _SectionHead(
              kicker: 'Jump back in',
              title: 'Quick Picks',
              count: picks.length,
            ),
          ),
        ),
      ));
      slivers.add(SliverPadding(
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
              child: _QuickTile(track: picks[i]),
            ),
            childCount: picks.length,
          ),
        ),
      ));
    }

    if (data.jumpBackIn.isNotEmpty) {
      gap(26);
      final recent = data.jumpBackIn.take(6).toList();
      slivers.add(SliverPadding(
        padding: EdgeInsets.only(left: side, right: side),
        sliver: SliverToBoxAdapter(
          child: WaveEntrance(
            index: slot(),
            rise: 8,
            child: _SectionHead(
              kicker: 'History',
              title: 'Continue Listening',
              count: recent.length,
              actionLabel: 'See all',
              actionPath: '/history',
            ),
          ),
        ),
      ));
      slivers.add(SliverPadding(
        padding: EdgeInsets.only(top: 10),
        sliver: SliverToBoxAdapter(
          child: _CoverShelf(tracks: recent, source: 'Recently played', side: side),
        ),
      ));
    }

    if (data.becauseYouListened.isNotEmpty) {
      gap(26);
      final mixes = data.becauseYouListened.take(3).toList();
      final becauseKicker = data.becauseSeed.isNotEmpty
          ? 'Because you listened to ${data.becauseSeed}'
          : 'Generated';
      slivers.add(SliverPadding(
        padding: EdgeInsets.only(left: side, right: side),
        sliver: SliverToBoxAdapter(
          child: WaveEntrance(
            index: slot(),
            rise: 8,
              child: _SectionHead(
                kicker: becauseKicker,
                title: 'Made For You',
                count: mixes.length,
              actionLabel: 'Open Mix Lab',
              actionPath: '/mixes',
            ),
          ),
        ),
      ));
      slivers.add(SliverPadding(
        padding: EdgeInsets.only(top: 10),
        sliver: SliverToBoxAdapter(
          child: _MixShelf(tracks: mixes, side: side),
        ),
      ));
    }

    if (data.heavyRotation.isNotEmpty) {
      gap(26);
      final albums = data.heavyRotation.take(6).toList();
      slivers.add(SliverPadding(
        padding: EdgeInsets.only(left: side, right: side),
        sliver: SliverToBoxAdapter(
          child: WaveEntrance(
            index: slot(),
            rise: 8,
            child: _SectionHead(
              kicker: 'Rotation',
              title: 'Albums For You',
              count: albums.length,
              actionLabel: 'See all',
              actionPath: '/albums',
            ),
          ),
        ),
      ));
      slivers.add(SliverPadding(
        padding: EdgeInsets.only(top: 10),
        sliver: SliverToBoxAdapter(
          child: _AlbumShelf(tracks: albums, source: 'For you', side: side),
        ),
      ));
    }

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
        slivers.add(SliverPadding(
          padding: EdgeInsets.only(left: side, right: side),
          sliver: SliverToBoxAdapter(
            child: WaveEntrance(
              index: slot(),
              rise: 8,
              child: _SectionHead(
                kicker: 'Artists',
                title: 'Artists For You',
                count: artists.length,
                actionLabel: 'See all',
                actionPath: '/artists',
              ),
            ),
          ),
        ));
        slivers.add(SliverPadding(
          padding: EdgeInsets.only(top: 10),
          sliver: SliverToBoxAdapter(
            child: _ArtistShelf(tracks: artists, side: side),
          ),
        ));
      }
    }

    // Friends Listening — real friend activity (friend → latest
    // scrobble with relative time). Hidden entirely when there is
    // nothing to show; never placeholder names or faked presence.
    {
      final activities =
          ref.watch(friendsActivityProvider).valueOrNull ??
              const [];
      if (activities.isNotEmpty) {
        gap(26);
        slivers.add(SliverPadding(
          padding: EdgeInsets.only(left: side, right: side),
          sliver: SliverToBoxAdapter(
            child: WaveEntrance(
              index: slot(),
              rise: 8,
              child: _SectionHead(
                kicker: 'Social',
                title: 'Friends Listening',
                count: activities.length,
                actionLabel: 'See all',
                actionPath: '/friends',
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
              child: _FriendsStrip(activities: activities),
            ),
          ),
        ));
      }
    }

    if (data.charts.isNotEmpty) {
      gap(26);
      slivers.add(SliverPadding(
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
      slivers.add(SliverPadding(
        padding: EdgeInsets.only(left: side, right: side),
        sliver: SliverToBoxAdapter(
          child: WaveEntrance(
            index: slot(),
            rise: 8,
            child: _SectionHead(
              kicker: 'Charts',
              title: 'Trending Now',
              count: charts.length,
            ),
          ),
        ),
      ));
      slivers.add(SliverPadding(
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

    if (data.freshFinds.isNotEmpty) {
      gap(26);
      final fresh = data.freshFinds.take(5).toList();
      slivers.add(SliverPadding(
        padding: EdgeInsets.only(left: side, right: side),
        sliver: SliverToBoxAdapter(
          child: WaveEntrance(
            index: slot(),
            rise: 8,
            child: _SectionHead(
              kicker: 'Discovery',
              title: 'Fresh Finds',
              count: fresh.length,
            ),
          ),
        ),
      ));
      slivers.add(SliverPadding(
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

    gap(26);
    slivers.add(SliverPadding(
      padding: EdgeInsets.only(left: side, right: side),
      sliver: SliverToBoxAdapter(
        child: WaveEntrance(
          index: slot(),
          rise: 10,
          child: const HomeNewReleasesSection(),
        ),
      ),
    ));

    gap(26);
    slivers.add(SliverPadding(
      padding: EdgeInsets.only(left: side, right: side),
      sliver: SliverToBoxAdapter(
        child: WaveEntrance(
          index: slot(),
          rise: 10,
          child: const HomePopularShelvesSection(),
        ),
      ),
    ));

    gap(26);
    // Bottom breathing room (previously came with the releases block).
    slivers.add(
      const SliverToBoxAdapter(child: SizedBox(height: 6)),
    );
    return SliverMainAxisGroup(slivers: slivers);
  }
}

/// Greeting header: 24px time-aware greeting + For {username} + date.
class _Header extends StatelessWidget {
  final String greeting;
  final String username;
  final String date;
  final bool signedIn;
  const _Header({
    required this.greeting,
    required this.username,
    required this.date,
    required this.signedIn,
  });

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                username.isNotEmpty ? '$greeting, $username' : greeting,
                style: WaveType.pageTitle.copyWith(fontSize: 24),
              ),
              const SizedBox(height: 2),
              Text(
                username.isNotEmpty
                    ? 'For $username · $date · picked from your taste'
                    : '$date · picked for you · connect Last.fm for more',
                style: WaveType.meta.copyWith(
                  color: dark
                      ? WaveColors.textSecondary
                      : WaveColors.lightTextSecondary,
                ),
              ),
            ],
          ),
        ),
        if (!signedIn)
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
            onTap: () => context.go('/settings?section=lastfm'),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: dark ? Colors.white : Colors.black,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                'Connect',
                style: WaveType.label.copyWith(
                  color: dark ? Colors.black : Colors.white,
                  fontSize: 12,
                ),
              ),
            ),
          )),
      ],
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

class _SectionHead extends StatelessWidget {
  final String kicker;
  final String title;
  final int? count;
  final String? actionLabel;
  final String? actionPath;
  const _SectionHead({
    required this.kicker,
    required this.title,
    this.count,
    this.actionLabel,
    this.actionPath,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
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
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(title, style: WaveType.sectionTitle),
                  if (count != null) ...[
                    const SizedBox(width: 6),
                    Text(
                      '$count',
                      style: WaveType.meta.copyWith(
                        color: waveTextTertiary(context),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
        if (actionLabel != null && actionPath != null)
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
            onTap: () => context.go(actionPath!),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  actionLabel!,
                  style: WaveType.label.copyWith(
                    fontSize: 11.5,
                    color: waveTextTertiary(context),
                  ),
                ),
                const SizedBox(width: 2),
                Icon(
                  WaveIcons.chevronRight,
                  size: 13,
                  color: waveTextTertiary(context),
                ),
              ],
            ),
          )),
      ],
    );
  }
}

/// Editorial hero: LEFT large personal pick (artwork 35–45% + metadata +
/// Play/Radio) + RIGHT 2–4 compact companions. The cover lights its own
/// halo, never a colour flood — real artwork always.
class _FeaturedHero extends ConsumerWidget {
  final GeneratedTrack track;
  final List<GeneratedTrack> upNext;

  /// Kicker override for sourced heroes (e.g. the YouTube Music mix).
  final String kicker;

  /// Full queue behind Play. Empty = legacy single-track behaviour.
  /// Non-empty = Play starts this list at [track].
  final List<GeneratedTrack> queueAll;
  const _FeaturedHero({
    required this.track,
    this.upNext = const [],
    this.kicker = 'FOR YOU · FEATURED MIX',
    this.queueAll = const [],
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = waveIsDark(context);
    final width = MediaQuery.sizeOf(context).width;
    final narrow = width < 860;
    final tint = ref.watch(artworkPaletteProvider(track.artworkUrl));
    final palette = tint.valueOrNull;
    // The glow is the cover's most vivid tone, not its dominant one: dominant
    // is dark for most artwork, which is why a fill seeded from it vanished
    // into the page.
    final glow = dark
        ? (palette?.vibrant ?? ArtworkPalette.fallback.vibrant)
        : (palette?.lightVibrant ?? ArtworkPalette.fallback.lightVibrant);
    // The panel is structure only. Any tint anchored to its edges leaves a
    // straight line of colour wherever the box ends — that was the stain.
    final panel = dark
        ? Colors.white.withValues(alpha: 0.035)
        : Colors.black.withValues(alpha: 0.025);
    final artSize = narrow ? 132.0 : 176.0;
    final halo = artSize + 150;

    final left = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: artSize,
          height: artSize,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // Halo: bigger than the cell and allowed to paint outside it, so
              // the light spills past the panel instead of stopping at an edge.
              Positioned(
                left: -(halo - artSize) / 2,
                top: -(halo - artSize) / 2,
                width: halo,
                height: halo,
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: palette == null ? 0 : 1,
                    duration: waveMotion(context, WaveMotion.slow),
                    curve: WaveMotion.standard,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          stops: const [0, 0.55, 1],
                          colors: [
                            glow.withValues(alpha: 0.34),
                            glow.withValues(alpha: 0.12),
                            glow.withValues(alpha: 0),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: WaveRadius.artworkRadius,
                    boxShadow: WaveElevation.artwork(dark),
                  ),
                  child: WaveArtwork(
                    url: track.artworkUrl,
                    videoId: track.videoId,
                    size: artSize,
                    radius: WaveRadius.artwork,
                    title: track.name,
                    artist: track.artist,
                    label: track.name,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 20),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                kicker,
                style: WaveType.overline.copyWith(
                  fontSize: 10,
                  color: dark
                      ? WaveColors.textTertiary
                      : WaveColors.lightTextTertiary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                track.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: WaveType.pageTitle
                    .copyWith(fontSize: narrow ? 20 : 26),
              ),
              const SizedBox(height: 4),
              Text(
                track.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: WaveType.body.copyWith(
                  fontSize: 14,
                  color: dark
                      ? WaveColors.textSecondary
                      : WaveColors.lightTextSecondary,
                ),
              ),
              if (track.listeners.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    track.listeners,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: WaveType.meta.copyWith(
                      color: waveTextTertiary(context),
                    ),
                  ),
                ),
              const SizedBox(height: 14),
              Row(
                children: [
                  WavePlayPill(
                    onTap: () {
                      if (queueAll.isEmpty) {
                        playGenerated(ref, context, track,
                            sourceLabel: 'For you');
                        return;
                      }
                      var at = queueAll.indexWhere(
                          (t) => t.key == track.key);
                      if (at < 0) at = 0;
                      playGenerated(ref, context, queueAll[at],
                          sourceLabel: 'For you',
                          queueAll: queueAll,
                          startIndex: at);
                    },
                  ),
                  const SizedBox(width: 12),
                  _RadioPill(
                    onTap: () async {
                      await ref
                          .read(playbackServiceProvider.notifier)
                          .playQueue(
                              [playableFromGenerated(track)], 0,
                              sourceLabel: 'For you radio',
                              endlessRadio: true);
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );

    if (narrow || upNext.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: panel,
          borderRadius: WaveRadius.floatingRadius,
        ),
        child: left,
      );
    }

    // Wide: 58% featured + divider + 42% up-next stack.
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: panel,
        borderRadius: WaveRadius.floatingRadius,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(flex: 58, child: left),
          Container(
            width: 1,
            height: 180,
            margin: const EdgeInsets.symmetric(horizontal: 20),
            color: (dark ? Colors.white : Colors.black)
                .withValues(alpha: 0.08),
          ),
          Expanded(
            flex: 42,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Not "up next": the queue panel already means the queue by
                // that name. These three come after Play, not after this song.
                Text(
                  'MORE FOR YOU',
                  style: WaveType.overline.copyWith(
                    fontSize: 9.5,
                    color: waveTextTertiary(context),
                  ),
                ),
                const SizedBox(height: 8),
                for (var i = 0; i < upNext.length; i++)
                  _HeroCompanion(
                    track: upNext[i],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact 56px companion row inside the hero — art + title/artist +
/// hover play. Keeps the hero music-dense instead of banner-empty.
class _HeroCompanion extends ConsumerStatefulWidget {
  final GeneratedTrack track;
  const _HeroCompanion({
    required this.track,
  });
  @override
  ConsumerState<_HeroCompanion> createState() => _HeroCompanionState();
}

class _HeroCompanionState extends ConsumerState<_HeroCompanion> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: () => playGenerated(ref, context, widget.track,
            sourceLabel: 'For you · more'),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 6),
          decoration: BoxDecoration(
            color: _hover
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
                    size: 44,
                    radius: WaveRadius.artwork,
                    title: widget.track.name,
                    artist: widget.track.artist,
                    label: widget.track.name,
                  ),
                  if (_hover)
                    Positioned.fill(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: WaveRadius.artworkRadius,
                        ),
                        child: const Icon(WaveIcons.play,
                            size: 15, color: Colors.white),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(widget.track.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: WaveType.trackTitle
                            .copyWith(fontSize: 12.5)),
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
  }
}

/// Outlined companion to [WavePlayPill]: same pill geometry, hairline border
/// instead of an accent fill, so the hero's two actions read as one pair
/// (primary accent + secondary outline) rather than a pill and bare text.
class _RadioPill extends StatefulWidget {
  final VoidCallback onTap;
  const _RadioPill({required this.onTap});
  @override
  State<_RadioPill> createState() => _RadioPillState();
}

class _RadioPillState extends State<_RadioPill> {
  bool _hover = false;
  bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    final fg = waveTextSecondary(context);
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
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: waveMotion(context, WaveMotion.fast),
          padding:
              const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
          decoration: BoxDecoration(
            color: _pressed
                ? wavePressedWash(context)
                : _hover
                    ? waveHoverWash(context)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: waveDivider(context)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(WaveIcons.radio, size: 14, color: fg),
              const SizedBox(width: 8),
              Text('Radio', style: WaveType.label.copyWith(color: fg)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Quick Picks tile: 56px, 48px art, hover play, playing wash.
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
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.transparent,
                                    Colors.black
                                        .withValues(alpha: 0.55),
                                  ],
                                ),
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
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.transparent,
                                  Colors.black.withValues(alpha: 0.72),
                                ],
                                stops: const [0.45, 1.0],
                              ),
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
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.transparent,
                                    Colors.black.withValues(alpha: 0.55),
                                  ],
                                ),
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
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.transparent,
                                  Colors.black.withValues(alpha: 0.55),
                                ],
                              ),
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
  final String sourceLabel;
  const _FreshRow({
    required this.track,
    this.sourceLabel = 'Fresh finds',
  });

  @override
  ConsumerState<_FreshRow> createState() => _FreshRowState();
}

class _FreshRowState extends ConsumerState<_FreshRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final track = widget.track;
    final sourceLabel = widget.sourceLabel;
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
  final double side;
  const _ArtistShelf({required this.tracks, required this.side});
  @override
  Widget build(BuildContext context) {
    return WaveRail(
      height: 168,
      padding: EdgeInsets.symmetric(horizontal: side),
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



