import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:lastwave_desktop/core/storage/app_database.dart';
import 'package:lastwave_desktop/features/search/shared_providers.dart';
import 'package:lastwave_desktop/features/stats/stats_providers.dart';

void main() {
  test('listeningStatsProvider computes 100% local SQLite stats including albums and actual durations',
      () async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);

    db.recordLocalPlay(
      title: 'Lose Yourself',
      artist: 'Eminem',
      album: '8 Mile',
      durationMs: 326000, // 5m 26s
    );
    db.recordLocalPlay(
      title: 'Mockingbird',
      artist: 'Eminem',
      album: 'Encore',
      durationMs: 251000, // 4m 11s
    );

    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);

    final stats = await container.read(listeningStatsProvider.future);

    expect(stats.totalPlays, 2);
    // (326000 + 251000) / 60000 = 9.616 -> rounds to 10 mins (vs 7 with flat 3.5 estimate)
    expect(stats.totalMinutesListened, 10);
    expect(stats.hasEstimatedDuration, isFalse);
    expect(stats.uniqueArtists, 1);
    expect(stats.uniqueTracks, 2);
    expect(stats.currentStreakDays, 1);
    expect(stats.peakListeningLabel, isNot('—'));
    expect(stats.topArtists.map((a) => a.name), contains('Eminem'));
    expect(stats.topTracks.length, 2);
    expect(
      stats.topAlbums.map((a) => a.name),
      containsAll(<String>['8 Mile', 'Encore']),
    );
    expect(stats.isLastFmConnected, isFalse);
    expect(stats.lastFmScrobbles, 0);

    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final dayPlays = db.loadPlaysForDate(today);
    expect(dayPlays.map((p) => p.title),
        containsAll(<String>['Lose Yourself', 'Mockingbird']));
  });

  test('updateLatestLocalPlayDuration backfills unmeasured track duration', () async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);

    db.recordLocalPlay(
      title: 'Stan',
      artist: 'Eminem',
      album: 'The Marshall Mathers LP',
    );
    db.updateLatestLocalPlayDuration(
      title: 'Stan',
      artist: 'Eminem',
      durationMs: 404000,
    );

    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);

    final stats = await container.read(listeningStatsProvider.future);
    expect(stats.totalMinutesListened, 7); // 404000 / 60000 = 6.73 -> 7
    expect(stats.hasEstimatedDuration, isFalse);
  });

  test('listeningStatsProvider reports dash peak label when local plays are empty',
      () async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);

    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);

    final stats = await container.read(listeningStatsProvider.future);

    expect(stats.totalPlays, 0);
    expect(stats.totalMinutesListened, 0);
    expect(stats.currentStreakDays, 0);
    expect(stats.peakListeningLabel, '—');
    expect(stats.topAlbums, isEmpty);
  });
}
