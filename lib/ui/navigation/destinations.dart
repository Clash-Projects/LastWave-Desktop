import 'package:fluent_ui/fluent_ui.dart';

import '../../core/l10n/app_localizations.dart';
import '../theme/wave_icons.dart';

/// Rebuilt navigation — music first, panels secondary.
///
/// Layout:
/// - Top: Home / Discover / Stats / Search (daily music use)
/// - Middle: Podcasts / Playlists (Liked Songs is a tile in Playlists)
/// - Then: Library (local files, downloads, your playlists)
/// - Bottom (pinned): Jam / Settings
///
/// History stays routable but is not on the rail.
class WaveDestination {
  final String path;
  final String label;
  final IconData icon;
  const WaveDestination(this.path, this.label, this.icon);

  /// Localized label with automatic fallback to default [label] (English).
  String localizedLabel(BuildContext context) {
    try {
      final l10n = context.l10n;
      return switch (path) {
        '/home' => l10n.navHome,
        '/stats' => l10n.navStats,
        '/search' => l10n.navSearch,
        '/podcasts' => l10n.navPodcasts,
        '/playlists' => l10n.navPlaylists,
        '/library' => l10n.navLibrary,
        '/jam' => l10n.navJam,
        '/settings' => l10n.navSettings,
        _ => label,
      };
    } catch (_) {
      return label;
    }
  }
}

const waveListenDestinations = [
  WaveDestination('/home', 'Home', WaveIcons.home),
  WaveDestination('/stats', 'Stats', WaveIcons.stats),
  WaveDestination('/search', 'Search', WaveIcons.search),
];

const waveCollectionDestinations = [
  WaveDestination('/podcasts', 'Podcasts', WaveIcons.podcasts),
  WaveDestination('/playlists', 'Playlists', WaveIcons.playlists),
];

const waveOfflineDestinations = [
  WaveDestination('/library', 'Library', WaveIcons.library),
];

const waveSystemDestinations = [
  WaveDestination('/jam', 'Jam', WaveIcons.jam),
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
  if (path.startsWith('/downloads')) return '/library';
  if (path.startsWith('/album')) return '/albums';
  if (path.startsWith('/artist')) return '/artists';
  if (path.startsWith('/now')) return '/home';
  if (path.startsWith('/history')) return '/stats';
  if (path.startsWith('/stats')) return '/stats';
  if (path == '/home-layout' || path.startsWith('/home-layout/')) {
    return '/home';
  }
  if (path.startsWith('/liked')) return '/playlists';
  if (path.startsWith('/profile')) return '/settings';
  return '/home';
}
