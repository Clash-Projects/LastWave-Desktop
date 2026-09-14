import 'package:fluent_ui/fluent_ui.dart';

import '../theme/wave_icons.dart';

/// Rebuilt navigation — music first, panels secondary.
///
/// Layout:
/// - Top: Home / Discover / Search (daily music use)
/// - Middle: Library / Liked / Albums / Artists / Playlists
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
  WaveDestination('/library', 'Library', WaveIcons.library),
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

String waveActivePath(String location) {
  for (final d in allWaveDestinations) {
    if (location == d.path || location.startsWith('${d.path}/')) {
      return d.path;
    }
  }
  if (location.startsWith('/album')) return '/albums';
  if (location.startsWith('/artist')) return '/artists';
  if (location.startsWith('/now')) return '/home';
  if (location.startsWith('/lyrics')) return '/home';
  if (location.startsWith('/history')) return '/library';
  if (location.startsWith('/mixes')) return '/discover';
  if (location.startsWith('/profile')) return '/friends';
  return '/home';
}
