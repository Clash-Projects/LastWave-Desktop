import 'package:fluent_ui/fluent_ui.dart';
import 'package:go_router/go_router.dart';

import 'auth_gate.dart';

import '../ui/app_shell/app_shell.dart';
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
import '../ui/discover/discover_page.dart';
import '../ui/home/home_page.dart';
import '../ui/library/library_page.dart';
import '../ui/lyrics/lyrics_screen.dart';
import '../ui/misc/support_pages.dart';
import '../ui/now_playing/now_playing_page.dart';
import '../ui/search/search_page.dart';
import '../ui/settings/settings_page.dart';
import '../ui/theme/tokens.dart';

/// WinUI 3 page navigation — "Entrance" transition: full fade-in with a
/// short upward drift, decelerating hard (easeOutCubic) over [WaveMotion.slow].
Page<void> _page(Widget child) {
  return CustomTransitionPage(
    child: child,
    transitionsBuilder:
        (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
      );
      return FadeTransition(
        opacity: Tween<double>(begin: 0, end: 1).animate(curved),
        child: SlideTransition(
          position: Tween<Offset>(
                  begin: const Offset(0, 0.02), end: Offset.zero)
              .animate(curved),
          child: child,
        ),
      );
    },
    transitionDuration: WaveMotion.slow,
  );
}

/// Rebuilt navigation — music first, no dashboard.
///
/// Last.fm authentication is compulsory: [AuthGate] drives a redirect so
/// unauthenticated users only ever see /welcome (rendered WITHOUT the
/// main shell), and authenticated users can never sit on /welcome.
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
      return null;
    },
    routes: [
      GoRoute(
        path: '/welcome',
        pageBuilder: (c, s) =>
            _page(const WaveWelcomePage()),
      ),
      ShellRoute(
        builder: (context, state, child) => WaveShell(
          location: state.uri.hasQuery
              ? '${state.uri.path}?${state.uri.query}'
              : state.uri.path,
          child: child,
        ),
        routes: [
          GoRoute(
            path: '/home',
            pageBuilder: (c, s) =>
                _page(const WaveHomePage()),
          ),
          GoRoute(
            path: '/discover',
            pageBuilder: (c, s) =>
                _page(const WaveDiscoverPage()),
          ),
          GoRoute(
            path: '/search',
            pageBuilder: (c, s) => _page(WaveSearchPage(
              initialQuery:
                  s.uri.queryParameters['q'] ?? '',
            )),
          ),
          GoRoute(
            path: '/library',
            pageBuilder: (c, s) =>
                _page(const WaveLibraryPage()),
          ),
          GoRoute(
            path: '/liked',
            pageBuilder: (c, s) =>
                _page(const WaveLikedPage()),
          ),
          GoRoute(
            path: '/albums',
            pageBuilder: (c, s) =>
                _page(const WaveAlbumsPage()),
          ),
          GoRoute(
            path: '/album/:id',
            pageBuilder: (c, s) => _page(
              WaveAlbumPage(
                browseId: Uri.decodeComponent(
                    s.pathParameters['id'] ?? ''),
              ),
            ),
          ),
          GoRoute(
            path: '/artists',
            pageBuilder: (c, s) =>
                _page(const WaveArtistsPage()),
          ),
          GoRoute(
            path: '/artist/:name',
            pageBuilder: (c, s) => _page(
              WaveArtistPage(
                name: Uri.decodeComponent(
                    s.pathParameters['name'] ?? ''),
              ),
            ),
          ),
          GoRoute(
            path: '/playlists',
            pageBuilder: (c, s) =>
                _page(const WavePlaylistsPage()),
            routes: [
              GoRoute(
                path: ':id',
                pageBuilder: (c, s) => _page(
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
            path: '/mixes',
            pageBuilder: (c, s) =>
                _page(const WaveMixLabPage()),
          ),
          GoRoute(
            path: '/downloads',
            pageBuilder: (c, s) =>
                _page(const WaveDownloadsPage()),
          ),
          GoRoute(
            path: '/history',
            pageBuilder: (c, s) =>
                _page(const WaveHistoryPage()),
          ),
          GoRoute(
            path: '/now',
            pageBuilder: (c, s) =>
                _page(const WaveNowPlayingPage()),
          ),
          GoRoute(
            path: '/lyrics',
            pageBuilder: (c, s) =>
                _page(const WaveLyricsScreen()),
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
            pageBuilder: (c, s) =>
                _page(const WaveSettingsPage()),
          ),
        ],
      ),
    ],
  );
}
