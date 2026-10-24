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
import '../ui/collections/downloads_page.dart';
import '../ui/collections/history_page.dart';
import '../ui/collections/liked_page.dart';
import '../ui/collections/playlist_detail_page.dart';
import '../ui/collections/playlists_page.dart';
import '../ui/collections/yt_playlist_detail_page.dart';
import '../ui/collections/yt_shelf_page.dart';
import '../ui/stats/stats_page.dart';
import '../ui/home/home_page.dart';
import '../ui/khinsider/khinsider_album_page.dart';
import '../ui/lyrics/lyrics_screen.dart';
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

/// The one crossfade builder. Both directions are always explicit: go_router
/// defaults `reverseTransitionDuration` to **300 ms regardless of**
/// `transitionDuration`, so every route used to push in 110 ms and pop out
/// 300 ms — the exit (a stage has no incoming animation to mask it) read as a
/// long slow dissolve while the entrance was instant.
///
/// [curve] is applied in both directions by `CurvedAnimation` when no
/// `reverseCurve` is given, so an asymmetric curve (easeOut) also reads
/// backwards: the exit holds near-full opacity and then drops, instead of
/// mirroring the entrance. Pass a symmetric curve wherever the two have to
/// look the same.
Page<void> _fadePage(
  Widget child, {
  required Duration duration,
  required Curve curve,
}) {
  return CustomTransitionPage(
    child: child,
    transitionsBuilder:
        (context, animation, secondaryAnimation, child) {
      return FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: curve),
        child: child,
      );
    },
    transitionDuration: duration,
    reverseTransitionDuration: duration,
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
/// 180 ms with a symmetric curve, deliberately: the old 110 ms in / 300 ms out
/// pair was neither even nor mirror-able, and this stage has no incoming
/// animation on the way out to hide it — the closing dissolve is the whole
/// gesture. `easeInOutCubic` makes the exit the exact reverse of the entrance.
Page<void> _stagePage(Widget child) {
  WaveRouteOrigin.consume();
  return _fadePage(
    child,
    duration: WaveMotion.normal,
    curve: Curves.easeInOutCubic,
  );
}

/// Pointer-anchored entrance for routes opened from a surface the user pressed
/// (a card, a cover).
///
/// The destination grows out of the recorded press point — a 0.96 → 1 scale
/// anchored at the pressed *height* (see [WaveRouteOrigin.alignmentIn] for why
/// it is not anchored horizontally), under the same crossfade — so a tap reads
/// as the page expanding out of what was tapped instead of a hard cut.
/// Reversing the route plays the same curve backwards, shrinking back toward
/// the origin.
///
/// Falls back to [_page] whenever no fresh origin exists (deep link, hotkey,
/// command palette, session restore) and drops to a plain fade when the OS
/// reduce-motion switch is on.
Page<void> _anchoredPage(Widget child) {
  final origin = WaveRouteOrigin.consume();
  if (origin == null) return _page(child);
  // A cover flight is already the motion (see flight.dart): scaling the page
  // underneath it would move the landing spot out from under the cover.
  if (WaveFlight.isArmed) return _page(child);
  return CustomTransitionPage(
    child: child,
    transitionsBuilder:
        (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: WaveMotion.standard,
      );
      if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
        return FadeTransition(opacity: curved, child: child);
      }
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
          alignment: origin.alignmentIn(MediaQuery.sizeOf(context)),
          child: child,
        ),
      );
    },
    transitionDuration: WaveMotion.normal,
    // Same bug as [_page]: go_router would otherwise pop this in 300 ms while
    // it entered in 180.
    reverseTransitionDuration: WaveMotion.normal,
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
/// History + Mix Lab stay routable but off prime nav.
GoRouter buildRouter({required AuthGate gate}) {
  return GoRouter(
    initialLocation: '/home',
    refreshListenable: gate,
    redirect: (context, state) {
      final atWelcome = state.uri.path == '/welcome';
      if (!gate.signedIn && !atWelcome) return '/welcome';
      if (gate.signedIn && atWelcome) return '/home';
      if (state.uri.path == '/discover') return '/home';
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
              GoRoute(
                path: '/khinsider/:id',
                pageBuilder: (c, s) => _anchoredPage(WaveKhAlbumPage(
                  albumId: Uri.decodeComponent(s.pathParameters['id'] ?? ''),
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
                  WaveAlbumPage(
                    browseId: Uri.decodeComponent(
                        s.pathParameters['id'] ?? ''),
                    // What the pressed card already knew. The selection
                    // fills the header on the first frame (see
                    // waveAlbumLocation), so the entrance animates the album
                    // instead of a spinner while browseAlbum answers.
                    fallbackTitle: s.uri.queryParameters['title'] ?? '',
                    fallbackArtist: s.uri.queryParameters['artist'] ?? '',
                    fallbackArt: s.uri.queryParameters['art'] ?? '',
                  ),
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
                  WaveArtistPage(
                    name: Uri.decodeComponent(
                        s.pathParameters['name'] ?? ''),
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
                path: '/ytshelf/:title',
                pageBuilder: (c, s) => _page(
                  WaveYtShelfPage(
                    title: Uri.decodeComponent(
                        s.pathParameters['title'] ?? ''),
                  ),
                ),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/downloads',
                pageBuilder: (c, s) =>
                    _page(const WaveDownloadsPage()),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/mixes',
                pageBuilder: (c, s) =>
                    _page(const WaveMixLabPage()),
              ),
              GoRoute(
                path: '/history',
                pageBuilder: (c, s) =>
                    _page(const WaveHistoryPage()),
              ),
              GoRoute(
                path: '/now',
                pageBuilder: (c, s) =>
                    _stagePage(const WaveNowPlayingPage()),
              ),
              GoRoute(
                path: '/lyrics',
                pageBuilder: (c, s) =>
                    _stagePage(const WaveLyricsScreen()),
              ),
              GoRoute(
                path: '/friends',
                pageBuilder: (c, s) =>
                    _page(const WaveFriendsPage()),
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
