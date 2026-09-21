import 'package:fluent_ui/fluent_ui.dart';

import '../theme/wave_icons.dart';

/// Rebuilt navigation — music first, panels secondary.
///
/// Layout:
/// - Top: Home / Discover / Search (daily music use)
/// - Middle: Liked / Albums / Artists / Playlists (your collections)
/// - Then: Downloads
/// - Bottom (pinned): Friends / Settings
///
/// History + Mix Lab stay routable but are NOT prime nav.
class WaveDestination {
  final String path;
  final String label;
  final IconData icon;
  const WaveDestination(this.path, this.label, this.icon);
}

const waveListenDestinations = [
  WaveDestination('/home', 'Home', WaveIcons.home),
  WaveDestination('/discover', 'Discover', WaveIcons.discover),
  WaveDestination('/search', 'Search', WaveIcons.search),
];

const waveCollectionDestinations = [
  WaveDestination('/liked', 'Liked Songs', WaveIcons.liked),
  WaveDestination('/albums', 'Albums', WaveIcons.albums),
  WaveDestination('/artists', 'Artists', WaveIcons.artists),
  WaveDestination('/playlists', 'Playlists', WaveIcons.playlists),
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
  if (path.startsWith('/history')) return '/liked';
  if (path.startsWith('/mixes')) return '/discover';
  if (path.startsWith('/profile')) return '/friends';
  return '/home';
}
