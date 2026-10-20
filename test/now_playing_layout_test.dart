import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lastwave_desktop/core/artwork/animated_artwork_service.dart';
import 'package:lastwave_desktop/core/audio/stream_models.dart';
import 'package:lastwave_desktop/core/storage/app_database.dart';
import 'package:lastwave_desktop/core/storage/prefs.dart';
import 'package:lastwave_desktop/features/lyrics/lyrics_models.dart';
import 'package:lastwave_desktop/features/player/playback_service.dart';
import 'package:lastwave_desktop/features/player/player_state.dart';
import 'package:lastwave_desktop/features/search/shared_providers.dart';
import 'package:lastwave_desktop/ui/components/ambient.dart';
import 'package:lastwave_desktop/ui/lyrics/lyrics_panel.dart';
import 'package:lastwave_desktop/ui/now_playing/now_playing_page.dart';
import 'package:lastwave_desktop/ui/theme/haze.dart';

class _FakePlaybackService extends StateNotifier<PlayerSnapshot>
    implements PlaybackService {
  _FakePlaybackService(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _current = PlayableTrack(
  title: 'Do Numbari (From "Mirzapur The Movie")',
  artist: 'Dhanda Nyoliwala',
  album: 'Mirzapur',
  artworkUrl: 'https://is1-ssl.mzstatic.com/image/thumb/test.jpg',
);
const _next = PlayableTrack(title: 'Hola Amigo', artist: 'KR\$NA');

PlayerSnapshot _snapshot() => const PlayerSnapshot(
  current: _current,
  queue: [_current, _next],
  currentIndex: 0,
  stream: ResolvedStream(
    url: 'https://example.invalid/a.flac',
    bitrateKbps: 4608,
    audioCodec: 'HI-RES FLAC',
    isLossless: true,
    bitDepth: 24,
    samplingRateKhz: 96,
  ),
);

Future<void> _pumpNowPlaying(WidgetTester tester, {required Size size}) async {
  SharedPreferences.setMockInitialValues({'lw_visualizer_enabled': false});
  final prefs = await Prefs.load();
  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final fake = _FakePlaybackService(_snapshot());

  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        playbackServiceProvider.overrideWith((ref) => fake),
        animatedArtworkProvider.overrideWith((ref, query) async => null),
        artworkPaletteProvider.overrideWith(
          (ref, url) async => ArtworkPalette.fallback,
        ),
        waveLyricsProvider.overrideWith(
          (ref, track) => Stream.value(const LyricsResult.empty()),
        ),
      ],
      child: const FluentApp(
        themeMode: ThemeMode.dark,
        home: WaveNowPlayingPage(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

Rect _upNextRowRect(WidgetTester tester) {
  final row = find.byKey(const ValueKey('now-playing-up-next'));
  expect(row, findsOneWidget);
  return tester.getRect(row);
}

void main() {
  testWidgets('desktop metadata and UP NEXT stay inside the page', (
    tester,
  ) async {
    const size = Size(1024, 516);
    await _pumpNowPlaying(tester, size: size);

    expect(find.text('Do Numbari (From "Mirzapur The Movie")'), findsOneWidget);
    expect(find.text('HI-RES'), findsOneWidget);
    expect(find.text('FLAC · 4608 kbps'), findsOneWidget);
    expect(
      find.ancestor(of: find.text('HI-RES'), matching: find.byType(WaveGlass)),
      findsNothing,
    );
    expect(
      find.ancestor(of: find.text('UP NEXT'), matching: find.byType(WaveGlass)),
      findsNothing,
    );
    expect(_upNextRowRect(tester).bottom, lessThanOrEqualTo(size.height));
  });

  testWidgets('narrow metadata and UP NEXT fit without scrolling', (
    tester,
  ) async {
    const size = Size(800, 516);
    await _pumpNowPlaying(tester, size: size);

    await tester.tap(find.byTooltip('Hide lyrics'));
    await tester.pumpAndSettle();

    expect(find.text('Do Numbari (From "Mirzapur The Movie")'), findsOneWidget);
    expect(
      find.ancestor(of: find.text('UP NEXT'), matching: find.byType(WaveGlass)),
      findsNothing,
    );
    expect(_upNextRowRect(tester).bottom, lessThanOrEqualTo(size.height));
  });
}
