import 'package:go_router/go_router.dart';

import '../features/albums/albums_screen.dart';
import '../features/artists/artists_screen.dart';
import '../features/downloads/downloads_screen.dart';
import '../features/friends/friends_screen.dart';
import '../features/generate/generate_screen.dart';
import '../features/history/history_screen.dart';
import '../features/home/home_screen.dart';
import '../features/lastfm/login_screen.dart';
import '../features/library/library_screen.dart';
import '../features/library/liked_screen.dart';
import '../features/lyrics/lyrics_screen.dart';
import '../features/player/now_playing_screen.dart';
import '../features/playlists/playlist_detail_screen.dart';
import '../features/playlists/playlists_screen.dart';
import '../features/profile/profile_screen.dart';
import '../features/search/search_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/shell/desktop_shell.dart';

/// Desktop navigation: single shell (sidebar + player bar) with
/// top-level content routes. Mirrors Android `Screen` destinations
/// adapted for desktop IA.
GoRouter buildRouter() {
  return GoRouter(
    initialLocation: '/home',
    routes: [
      ShellRoute(
        builder: (context, state, child) =>
            DesktopShell(location: state.uri.path, child: child),
        routes: [
          GoRoute(
            path: '/home',
            pageBuilder: (c, s) =>
                const NoTransitionPage(child: HomeScreen()),
          ),
          GoRoute(
            path: '/search',
            pageBuilder: (c, s) =>
                const NoTransitionPage(child: SearchScreen()),
          ),
          GoRoute(
            path: '/library',
            pageBuilder: (c, s) =>
                const NoTransitionPage(child: LibraryScreen()),
          ),
          GoRoute(
            path: '/liked',
            pageBuilder: (c, s) =>
                const NoTransitionPage(child: LikedScreen()),
          ),
          GoRoute(
            path: '/albums',
            pageBuilder: (c, s) =>
                const NoTransitionPage(child: AlbumsScreen()),
          ),
          GoRoute(
            path: '/artists',
            pageBuilder: (c, s) =>
                const NoTransitionPage(child: ArtistsScreen()),
          ),
          GoRoute(
            path: '/playlists',
            pageBuilder: (c, s) =>
                const NoTransitionPage(child: PlaylistsScreen()),
            routes: [
              GoRoute(
                path: ':id',
                pageBuilder: (c, s) => NoTransitionPage(
                  child: PlaylistDetailScreen(
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
                const NoTransitionPage(child: GenerateScreen()),
          ),
          GoRoute(
            path: '/downloads',
            pageBuilder: (c, s) => const NoTransitionPage(
                child: DownloadsScreen()),
          ),
          GoRoute(
            path: '/history',
            pageBuilder: (c, s) =>
                const NoTransitionPage(child: HistoryScreen()),
          ),
          GoRoute(
            path: '/now',
            pageBuilder: (c, s) => const NoTransitionPage(
                child: NowPlayingScreen()),
          ),
          GoRoute(
            path: '/lyrics',
            pageBuilder: (c, s) =>
                const NoTransitionPage(child: LyricsScreen()),
          ),
          GoRoute(
            path: '/friends',
            pageBuilder: (c, s) =>
                const NoTransitionPage(child: FriendsScreen()),
          ),
          GoRoute(
            path: '/profile',
            pageBuilder: (c, s) =>
                const NoTransitionPage(child: ProfileScreen()),
          ),
          GoRoute(
            path: '/settings',
            pageBuilder: (c, s) =>
                const NoTransitionPage(child: SettingsScreen()),
          ),
          GoRoute(
            path: '/login',
            pageBuilder: (c, s) =>
                const NoTransitionPage(child: LoginScreen()),
          ),
        ],
      ),
    ],
  );
}
