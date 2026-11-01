import 'package:fluent_ui/fluent_ui.dart';

import '../theme/wave_icons.dart';

/// Rebuilt navigation — music first, panels secondary.
///
/// Layout:
/// - Top: Home / Discover / Stats / Search (daily music use)
/// - Middle: Liked / Albums / Artists / Playlists (your collections)
/// - Then: Downloads
/// - Bottom (pinned): Friends / Settings
///
/// History stays routable but is not on the rail.
/// Mix Lab is a listen destination, so [/mixes] matches the loop above
/// before the fallback at the bottom of [waveActivePath].
class WaveDestination {
  final String path;
  final String label;
  final IconData icon;
  const WaveDestination(this.path, this.label, this.icon);
}

const waveListenDestinations = [
  WaveDestination('/home', 'Home', WaveIcons.home),
  WaveDestination('/stats', 'Stats', WaveIcons.stats),
  WaveDestination('/search', 'Search', WaveIcons.search),
  WaveDestination('/mixes', 'Mix Lab', WaveIcons.mixes),
];

const waveCollectionDestinations = [
  WaveDestination('/liked', 'Liked Songs', WaveIcons.liked),
  WaveDestination('/albums', 'Albums', WaveIcons.albums),
  WaveDestination('/artists', 'Artists', WaveIcons.artists),
  WaveDestination('/playlists', 'Playlists', WaveIcons.playlists),
  WaveDestination('/podcasts', 'Podcasts', WaveIcons.podcasts),
];

const waveOfflineDestinations = [
  WaveDestination('/downloads', 'Downloads', WaveIcons.downloads),
];

const waveSystemDestinations = [
  WaveDestination('/friends', 'Friends', WaveIcons.friends),
  WaveDestination('/settings', 'Settings', WaveIcons.settings),
];

List<WaveDestination> get allWaveDestinations => [
      ...waveListenDestinations,
      ...waveCollectionDestinations,
      ...waveOfflineDestinations,
      ...waveSystemDestinations,
    ];

String waveRoutePath(String location) => location.split('?').first;

String waveActivePath(String location) {
  final path = waveRoutePath(location);
  for (final d in allWaveDestinations) {
    if (path == d.path || path.startsWith('${d.path}/')) {
      return d.path;
    }
  }
  if (path.startsWith('/album')) return '/albums';
  if (path.startsWith('/artist')) return '/artists';
  if (path.startsWith('/now')) return '/home';
  if (path.startsWith('/lyrics')) return '/home';
  if (path.startsWith('/history')) return '/stats';
  if (path.startsWith('/stats')) return '/stats';
  if (path == '/home-layout' || path.startsWith('/home-layout/')) {
    return '/home';
  }
  if (path.startsWith('/mixes')) return '/home';
  if (path.startsWith('/profile')) return '/friends';
  return '/home';
}
