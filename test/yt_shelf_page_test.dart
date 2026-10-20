import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lastwave_desktop/core/storage/app_database.dart';
import 'package:lastwave_desktop/core/storage/prefs.dart';
import 'package:lastwave_desktop/features/innertube/innertube_api.dart';
import 'package:lastwave_desktop/features/innertube/yt_library_providers.dart';
import 'package:lastwave_desktop/features/search/shared_providers.dart';
import 'package:lastwave_desktop/ui/collections/yt_shelf_page.dart';
import 'package:lastwave_desktop/ui/components/ambient.dart';

/// A shelf longer than any home rail: the page is the only surface that is
/// supposed to show all of it.
YtHomeShelf _listenAgain() => YtHomeShelf(
      title: 'Listen again',
      trackCards: [
        for (var i = 0; i < 12; i++)
          YouTubeMusicTrack(
            videoId: 'v$i',
            title: 'Song $i',
            artist: 'Artist $i',
            // An official CDN URL: WaveArtwork skips the iTunes upgrade for
            // these, so the test never leaves a network timer behind.
            artworkUrl: 'https://is1-ssl.mzstatic.com/image/thumb/x$i.jpg',
          ),
      ],
    );

Future<void> _pump(
  WidgetTester tester, {
  required List<YtHomeShelf> shelves,
  required String title,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await Prefs.load();
  final db = AppDatabase.inMemory();
  addTearDown(db.close);

  await tester.binding.setSurfaceSize(const Size(1200, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        ytHomeShelvesProvider.overrideWith((ref) async => shelves),
        artworkPaletteProvider.overrideWith(
          (ref, url) async => ArtworkPalette.fallback,
        ),
      ],
      child: FluentApp(
        themeMode: ThemeMode.dark,
        home: WaveYtShelfPage(title: title),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('the page carries the whole shelf, not the rail cap', (
    tester,
  ) async {
    await _pump(tester, shelves: [_listenAgain()], title: 'Listen again');

    expect(find.text('12 songs'), findsOneWidget);
    expect(find.text('Play all'), findsOneWidget);
    // Item eleven is past the ten-card cap the home rail applies.
    expect(find.text('Song 11'), findsOneWidget);
  });

  testWidgets('a shelf the account no longer returns says so', (tester) async {
    await _pump(
      tester,
      shelves: [_listenAgain()],
      title: 'Forgotten favorites',
    );

    expect(find.text('Shelf not available'), findsOneWidget);
    expect(find.text('Play all'), findsNothing);
  });
}
