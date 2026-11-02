import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lastwave_desktop/core/network/network_monitor.dart';
import 'package:lastwave_desktop/core/storage/app_database.dart';
import 'package:lastwave_desktop/core/storage/prefs.dart';
import 'package:lastwave_desktop/features/feed/feed_repository.dart';
import 'package:lastwave_desktop/features/home/home_providers.dart';
import 'package:lastwave_desktop/features/innertube/innertube_api.dart';
import 'package:lastwave_desktop/features/innertube/yt_library_providers.dart';
import 'package:lastwave_desktop/features/player/playback_service.dart';
import 'package:lastwave_desktop/features/player/player_state.dart';
import 'package:lastwave_desktop/features/podcasts/podcast_repository.dart';
import 'package:lastwave_desktop/features/search/shared_providers.dart';
import 'package:lastwave_desktop/ui/components/ambient.dart';
import 'package:lastwave_desktop/ui/home/home_page.dart';

const _art = 'https://is1-ssl.mzstatic.com/image/thumb/x.jpg';

class _FakePlayback extends StateNotifier<PlayerSnapshot>
    implements PlaybackService {
  _FakePlayback() : super(const PlayerSnapshot());

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeNetwork extends StateNotifier<bool> implements NetworkMonitor {
  _FakeNetwork() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<YouTubeMusicTrack> _songs(String prefix, int n) => [
      for (var i = 0; i < n; i++)
        YouTubeMusicTrack(
          videoId: '$prefix$i',
          title: '$prefix song $i',
          artist: '$prefix artist $i',
          artworkUrl: _art,
        ),
    ];

final _shelves = [
  YtHomeShelf(title: 'Listen again', trackCards: _songs('again', 8)),
  YtHomeShelf(title: 'Quick picks', tracks: _songs('quick', 12)),
  YtHomeShelf(title: 'Music videos for you', trackCards: _songs('vid', 8)),
  YtHomeShelf(title: 'Mixed for you', trackCards: _songs('mix', 8)),
  YtHomeShelf(title: 'New releases', trackCards: _songs('new', 8)),
];

Future<void> _pump(
  WidgetTester tester, {
  required Size size,
  required bool connected,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await Prefs.load();
  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        playbackServiceProvider.overrideWith((ref) => _FakePlayback()),
        networkMonitorProvider.overrideWith((ref) => _FakeNetwork()),
        artworkPaletteProvider.overrideWith(
          (ref, url) async => ArtworkPalette.fallback,
        ),
        ytConnectionProvider.overrideWith(
          (ref) => YtConnection(connected: connected),
        ),
        ytHomeShelvesProvider.overrideWith(
          (ref) async => connected ? _shelves : const [],
        ),
        feedProvider.overrideWith(
          (ref) async => FeedData(
            // Charts render artist tiles without YouTube, and those start
            // artwork lookups, so only the connected case carries them.
            charts: connected
                ? const [
                    GeneratedTrack(
                      name: 'Chart song',
                      artist: 'Chart artist',
                      artworkUrl: _art,
                    ),
                  ]
                : const [],
            becauseSeed: 'Fav',
            becauseYouListened: const [
              GeneratedTrack(name: 'B1', artist: 'X', artworkUrl: _art),
              GeneratedTrack(name: 'B2', artist: 'Y', artworkUrl: _art),
              GeneratedTrack(name: 'B3', artist: 'Z', artworkUrl: _art),
            ],
          ),
        ),
        personalMixProvider.overrideWith((ref) async => null),
        friendsActivityProvider.overrideWith((ref) async => const []),
        podcastHomeProvider.overrideWith((ref) async => const []),
      ],
      child: const FluentApp(
        themeMode: ThemeMode.dark,
        home: WaveHomePage(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
}

void main() {
  testWidgets('connected Home leads with YouTube shelves in priority order', (
    tester,
  ) async {
    await _pump(tester, size: const Size(1400, 4000), connected: true);

    final quick = tester.getTopLeft(find.text('Quick picks')).dy;
    final again = tester.getTopLeft(find.text('Listen again')).dy;
    final mix = tester.getTopLeft(find.text('Mixed for you')).dy;
    final because =
        tester.getTopLeft(find.text('Because you listened to Fav')).dy;
    final releases = tester.getTopLeft(find.text('New releases')).dy;
    final videos = tester.getTopLeft(find.text('Music videos for you')).dy;
    expect(quick, lessThan(again));
    // YouTube's own shelves keep YouTube's order...
    expect(again, lessThan(videos));
    expect(videos, lessThan(mix));
    expect(mix, lessThan(releases));
    // ...and the small Last.fm rows follow the feed.
    expect(releases, lessThan(because));

    expect(find.text('CHART SPOTLIGHT'), findsNothing);
    expect(find.text('Trending Now'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('connected Home fits a narrow window', (tester) async {
    await _pump(tester, size: const Size(800, 900), connected: true);
    expect(find.text('Quick picks'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('without YouTube, Home keeps its own layout', (tester) async {
    await _pump(tester, size: const Size(1400, 4000), connected: false);
    expect(find.text('Quick picks'), findsNothing);
    expect(find.text('Made For You'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
