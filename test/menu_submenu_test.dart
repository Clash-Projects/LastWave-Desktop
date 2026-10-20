import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lastwave_desktop/core/storage/app_database.dart';
import 'package:lastwave_desktop/features/library/playlists.dart';
import 'package:lastwave_desktop/ui/components/menus.dart';

Future<void> _pumpPanel(WidgetTester tester, List<WaveMenuEntry> entries) async {
  await tester.binding.setSurfaceSize(const Size(1000, 700));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    FluentApp(
      themeMode: ThemeMode.dark,
      home: ScaffoldPage(
        content: Center(
          child: SizedBox(
            width: 260,
            child: WaveFlyoutPanel.items(entries: entries),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Builds the real "Add to playlist" entry against [repo] and hands back the
/// rows it would cascade.
Future<List<WaveMenuEntry>> _playlistRows(
  WidgetTester tester,
  PlaylistRepository repo,
) async {
  WaveMenuSubmenu? entry;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        playlistRepositoryProvider.overrideWith((ref) => repo),
      ],
      child: FluentApp(
        themeMode: ThemeMode.dark,
        home: Consumer(
          builder: (context, ref, _) {
            entry ??= waveAddToPlaylistEntry(
              context: context,
              ref: ref,
              playlists: ref.watch(playlistRepositoryProvider),
              track: const StoredTrack(name: 'Song', artist: 'Artist'),
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return entry!.items();
}

void main() {
  testWidgets('a library of only Liked Songs still offers a way to add one', (
    tester,
  ) async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final repo = PlaylistRepository(db);
    await repo.ensureLikedSongs();

    final rows = await _playlistRows(tester, repo);
    final labels = rows.whereType<WaveMenuAction>().map((a) => a.label);

    expect(labels, contains('New playlist…'));
    // The liked row is the repository's own; it is never a filing target.
    expect(labels, isNot(contains('Liked Songs')));
  });

  testWidgets('existing playlists come first, then the create row', (
    tester,
  ) async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final repo = PlaylistRepository(db);
    await repo.ensureLikedSongs();
    await repo.createCustom('Chill');

    final rows = await _playlistRows(tester, repo);
    final labels =
        rows.whereType<WaveMenuAction>().map((a) => a.label).toList();

    expect(labels, ['Chill', 'New playlist…']);
  });

  testWidgets('hovering a submenu row opens its nested panel', (tester) async {
    await _pumpPanel(tester, [
      WaveMenuAction(label: 'Play', onPressed: () {}),
      WaveMenuSubmenu(
        label: 'Add to playlist',
        items: () => [
          WaveMenuAction(label: 'Chill', onPressed: () {}),
          WaveMenuAction(label: 'Focus', onPressed: () {}),
        ],
      ),
    ]);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();

    final row = find.text('Add to playlist');
    expect(row, findsOneWidget);
    await gesture.moveTo(tester.getCenter(row));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.text('Chill'), findsOneWidget);
    expect(find.text('Focus'), findsOneWidget);
  });

  testWidgets('a submenu with no entries has nothing to show', (tester) async {
    await _pumpPanel(tester, [
      WaveMenuSubmenu(label: 'Add to playlist', items: () => const []),
    ]);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();

    await gesture.moveTo(tester.getCenter(find.text('Add to playlist')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    // The row itself is still there; nothing else is.
    expect(find.text('Add to playlist'), findsOneWidget);
  });
}
