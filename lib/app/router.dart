import 'package:fluent_ui/fluent_ui.dart';
import 'package:go_router/go_router.dart';

import 'auth_gate.dart';

import '../ui/app_shell/app_shell.dart';
import '../ui/app_shell/branch_switcher.dart';
import '../ui/auth/welcome_page.dart';
import '../ui/collections/album_detail_page.dart';
import '../ui/collections/albums_page.dart';
import '../ui/collections/artist_detail_page.dart';
import '../ui/collections/artists_page.dart';
import '../ui/library/library_page.dart';
import '../ui/collections/history_page.dart';
import '../ui/collections/liked_page.dart';
import '../ui/collections/playlist_detail_page.dart';
import '../ui/collections/playlists_page.dart';
import '../ui/collections/genre_detail_page.dart';
import '../ui/collections/spotify_playlist_detail_page.dart';
import '../ui/collections/yt_playlist_detail_page.dart';
import '../ui/collections/yt_shelf_page.dart';
import '../ui/podcasts/podcasts_page.dart';
import '../ui/stats/stats_page.dart';
import '../ui/home/home_layout_page.dart';
import '../ui/home/home_page.dart';
import '../ui/jam/jam_page.dart';
import '../ui/misc/support_pages.dart';
import '../ui/navigation/flight.dart';
import '../ui/navigation/route_origin.dart';
import '../ui/now_playing/now_playing_page.dart';
import '../ui/search/search_page.dart';
import '../ui/settings/settings_page.dart';
import '../ui/theme/tokens.dart';

/// High-refresh-rate navigation transition: crisp 110ms crossfade without
/// matrix translation overhead for immediate, zero-jank page changes.
Page<void> _page(Widget child) => _fadePage(
      child,
      duration: WaveMotion.fast,
      curve: Curves.easeOutCubic,
    );

/// Both durations are explicit because go_router defaults the reverse to 300ms.
Page<void> _fadePage(
  Widget child, {
  required Duration duration,
  required Curve curve,
  Duration? reverseDuration,
  LocalKey? key,
}) {
  return CustomTransitionPage(
    key: key,
    child: child,
    transitionsBuilder:
        (context, animation, secondaryAnimation, child) {
      final reduced = waveReduceMotion(context);
      return FadeTransition(
        opacity: reduced
            ? const AlwaysStoppedAnimation<double>(1)
            : animation.drive(CurveTween(curve: curve)),
        child: child,
      );
    },
    transitionDuration: duration,
    reverseTransitionDuration: reverseDuration ?? duration,
  );
}

/// Entrance for the two full-window stages (Now Playing, Lyrics): the plain
/// crossfade, explicitly NOT the anchored scale of [_anchoredPage].
///
/// A `ScaleTransition` animates a transform over the entire route, and the
/// raster cache keys pictures on the accumulated matrix — so every frame of
/// the entrance *and* the exit re-rasterizes the whole page. On Now Playing
/// that page is the app's most expensive surface (full-window baked-blur aura,
/// scrim gradients, cover shadows, a live motion-art texture), so the close
/// re-rasterized a window-sized scene per frame for the length of the
/// transition — visible jank plus ~2GB of transient ANGLE surfaces — while the
/// same page with the ambient stage off cost nothing. A fade changes no
/// matrix: the page's rasters stay cached and the compositor only blends them.
///
/// Closing still reads right: while a route animates Flutter marks it
/// non-opaque, so the destination page is painted underneath and the stage
/// crossfades into it instead of cutting to the shell background.
///
/// The press anchor is consumed (and dropped) so a dock-cover tap that opened
/// a stage cannot linger in [WaveRouteOrigin] and be inherited by the next
/// route.
///
/// The window-sized stage gets its own slower dissolve with a quicker return.
Page<void> _stagePage(BuildContext context, Widget child) {
  WaveRouteOrigin.consume();
  return _fadePage(
    child,
    duration: waveMotion(context, WaveMotion.stage),
    reverseDuration: waveMotion(context, WaveMotion.slow),
    curve: WaveMotion.move,
  );
}

/// Pointer-anchored entrance for routes opened from a surface the user pressed
/// (a card, a cover).
///
/// The destination grows out of the recorded press point — a 0.985 → 1 scale
/// anchored at the pressed *height* (see [WaveRouteOrigin.alignmentIn] for why
/// it is not anchored horizontally), under the same crossfade — so a tap reads
/// as the page expanding out of what was tapped instead of a hard cut.
/// Reversing the route plays the same curve backwards, shrinking back toward
/// the origin.
///
/// With a cover flight or no pointer anchor, the detail page simply dissolves.
Page<void> _anchoredPage(BuildContext context, Widget child, {LocalKey? key}) {
  final origin = WaveRouteOrigin.consume();
  final duration = waveMotion(context, WaveMotion.slow);
  // A cover flight is already the motion (see flight.dart): scaling the page
  // underneath it would move the landing spot out from under the cover.
  if (origin == null || WaveFlight.isArmed) {
    return _fadePage(
      child,
      duration: duration,
      curve: WaveMotion.move,
      key: key,
    );
  }
  return CustomTransitionPage(
    key: key,
    child: child,
    transitionsBuilder:
        (context, animation, secondaryAnimation, child) {
      final curved = waveReduceMotion(context)
          ? const AlwaysStoppedAnimation<double>(1)
          : animation.drive(CurveTween(curve: WaveMotion.move));
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.985, end: 1).animate(curved),
          alignment: origin.alignmentIn(MediaQuery.sizeOf(context)),
          child: child,
        ),
      );
    },
    transitionDuration: duration,
    reverseTransitionDuration: duration,
  );
}

/// Rebuilt navigation — music first, no dashboard.
///
/// Last.fm authentication is optional (guest mode): [AuthGate] drives a
/// redirect so outsiders only ever see /welcome (rendered WITHOUT the
/// main shell), and insiders (signed in or guest) can never sit on
/// /welcome.
/// The initial gate value comes from synchronously-loaded prefs, so the
/// first frame already routes correctly — Home never flashes.
///
/// Home / Discover / Search · Library / Liked / Albums / Artists /
/// Playlists · Downloads · Friends / Settings · Now / Lyrics ·
///
/// Album / Artist details are first-class music layouts.
/// History stays routable but off prime nav.
GoRouter buildRouter({required AuthGate gate}) {
  return GoRouter(
    initialLocation: '/home',
    refreshListenable: gate,
    redirect: (context, state) {
      final atWelcome = state.uri.path == '/welcome';
      if (!gate.signedIn && !atWelcome) return '/welcome';
      if (gate.signedIn && atWelcome) return '/home';
      return null;
    },
    routes: [
      GoRoute(
        path: '/welcome',
        pageBuilder: (c, s) =>
            _page(const WaveWelcomePage()),
      ),
      StatefulShellRoute(
        // Custom branch container: keeps every branch mounted (tab state and
        // scroll survive) but animates the switch. See WaveBranchSwitcher.
        navigatorContainerBuilder: (context, navigationShell, children) =>
            WaveBranchSwitcher(
          currentIndex: navigationShell.currentIndex,
          children: children,
        ),
        builder: (context, state, navigationShell) => WaveShell(
          location: state.uri.hasQuery
              ? '${state.uri.path}?${state.uri.query}'
              : state.uri.path,
          child: navigationShell,
        ),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/home',
                pageBuilder: (c, s) =>
                    _page(const WaveHomePage()),
              ),
              GoRoute(
                path: '/home-layout',
                pageBuilder: (c, s) =>
                    _page(const WaveHomeLayoutPage()),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/stats',
                pageBuilder: (c, s) =>
                    _page(const WaveStatsPage()),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/search',
                pageBuilder: (c, s) => _page(WaveSearchPage(
                  initialQuery:
                      s.uri.queryParameters['q'] ?? '',
                )),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/liked',
                pageBuilder: (c, s) =>
                    _page(const WaveLikedPage()),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/albums',
                pageBuilder: (c, s) =>
                    _page(const WaveAlbumsPage()),
              ),
              GoRoute(
                path: '/album/:id',
                pageBuilder: (c, s) => _anchoredPage(
                  c,
                  WaveAlbumPage(
                    browseId: s.pathParameters['id'] ?? '',
                    // What the pressed card already knew. The selection
                    // fills the header on the first frame (see
                    // waveAlbumLocation), so the entrance animates the album
                    // instead of a spinner while browseAlbum answers.
                    fallbackTitle: s.uri.queryParameters['title'] ?? '',
                    fallbackArtist: s.uri.queryParameters['artist'] ?? '',
                    fallbackArt: s.uri.queryParameters['art'] ?? '',
                  ),
                  key: s.pageKey,
                ),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/artists',
                pageBuilder: (c, s) =>
                    _page(const WaveArtistsPage()),
              ),
              GoRoute(
                path: '/artist/:name',
                pageBuilder: (c, s) => _anchoredPage(
                  c,
                  WaveArtistPage(
                    name: s.pathParameters['name'] ?? '',
                  ),
                ),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/playlists',
                pageBuilder: (c, s) =>
                    _page(const WavePlaylistsPage()),
                routes: [
                  GoRoute(
                    path: ':id',
                    pageBuilder: (c, s) => _anchoredPage(
                      c,
                      WavePlaylistDetailPage(
                        id: int.tryParse(
                                s.pathParameters['id'] ?? '') ??
                            0,
                      ),
                    ),
                  ),
                ],
              ),
              GoRoute(
                path: '/ytplaylist/:id',
                pageBuilder: (c, s) => _anchoredPage(
                  c,
                  WaveYtPlaylistDetailPage(
                    playlistId:
                        s.pathParameters['id'] ?? '',
                    title: s.uri.queryParameters['title'] ??
                        '',
                    artworkUrl:
                        s.uri.queryParameters['art'] ?? '',
                  ),
                ),
              ),
              GoRoute(
                path: '/genre/:query',
                pageBuilder: (c, s) => _anchoredPage(
                  c,
                  WaveGenreDetailPage(
                    query: s.pathParameters['query'] ?? '',
                    title: s.uri.queryParameters['name'] ?? '',
                  ),
                ),
              ),
              GoRoute(
                path: '/spotifyplaylist/:id',
                pageBuilder: (c, s) => _anchoredPage(
                  c,
                  WaveSpotifyPlaylistDetailPage(
                    playlistId: s.pathParameters['id'] ?? '',
                    title: s.uri.queryParameters['title'] ?? '',
                    artworkUrl: s.uri.queryParameters['art'] ?? '',
                  ),
                ),
              ),
              GoRoute(
                path: '/ytshelf/:title',
                pageBuilder: (c, s) => _page(
                  WaveYtShelfPage(
                    title: s.pathParameters['title'] ?? '',
                  ),
                ),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/podcasts',
                pageBuilder: (c, s) =>
                    _page(const WavePodcastsPage()),
                routes: [
                  GoRoute(
                    path: ':id',
                    pageBuilder: (c, s) => _anchoredPage(
                      c,
                      WavePodcastShowPage(
                        showId: s.pathParameters['id'] ?? '',
                        fallbackTitle:
                            s.uri.queryParameters['title'] ?? '',
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/library',
                pageBuilder: (c, s) => _page(WaveLibraryPage(
                  initialTab: s.uri.queryParameters['tab'],
                )),
              ),
              // Downloads now lives in the Library.
              GoRoute(
                path: '/downloads',
                redirect: (c, s) => '/library?tab=downloads',
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/history',
                pageBuilder: (c, s) =>
                    _page(const WaveHistoryPage()),
              ),
              GoRoute(
                path: '/now',
                pageBuilder: (c, s) =>
                    _stagePage(c, const WaveNowPlayingPage()),
              ),
              GoRoute(
                path: '/jam',
                pageBuilder: (c, s) => _page(WaveJamPage(
                  initialCode: s.uri.queryParameters['code'],
                )),
              ),
              GoRoute(
                path: '/profile',
                pageBuilder: (c, s) =>
                    _page(const WaveProfilePage()),
              ),
              GoRoute(
                path: '/settings',
                pageBuilder: (c, s) => _page(WaveSettingsPage(
                  initialSection: s.uri.queryParameters['section'],
                )),
              ),
            ],
          ),
        ],
      ),
    ],
  );
}
