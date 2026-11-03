import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lastwave_desktop/core/storage/app_database.dart';
import 'package:lastwave_desktop/features/lyrics/lyrics_models.dart';
import 'package:lastwave_desktop/features/lyrics/lyrics_repository.dart';
import 'package:lastwave_desktop/features/lyrics/lyrics_snapshot.dart';

LyricsResult _word(String source) => LyricsResult(
      lines: const [
        LyricLine(
          timeMs: 1000,
          durationMs: 3000,
          text: 'Hello world',
          transliteration: 'hello world',
          syllables: [
            LyricSyllable(timeMs: 1000, durationMs: 500, text: 'Hello '),
            LyricSyllable(
              timeMs: 1500,
              durationMs: 500,
              text: 'world',
              isBackground: true,
            ),
          ],
        ),
        LyricLine(timeMs: 5000, durationMs: 3000, text: 'Second line'),
      ],
      isSynced: true,
      isWordSynced: true,
      plainLyrics: 'Hello world\nSecond line',
      source: source,
    );

/// Stubbed providers, with an optional disk layer; counts provider calls.
class _Repo extends LyricsRepository {
  final LyricsResult? answer;
  int calls = 0;

  _Repo(this.answer, AppDatabase? db)
      : super(
          Dio(),
          const Duration(milliseconds: 200),
          const Duration(seconds: 2),
          null,
          db,
        ) {
    waveGap = Duration.zero;
  }

  @override
  Future<LyricsResult?> fetchFromProvider(
    String providerId, {
    required String title,
    required String artist,
    String album = '',
    int? durationSeconds,
    String? videoId,
  }) async {
    calls++;
    return providerId == 'lrclib' ? answer : null;
  }
}

void main() {
  group('codec', () {
    test('round-trips lines, syllables, transliteration and flags', () {
      final back = decodeLyrics(encodeLyrics(_word('apple_music')))!;
      expect(back.source, 'apple_music');
      expect(back.isSynced, isTrue);
      expect(back.isWordSynced, isTrue);
      expect(back.plainLyrics, 'Hello world\nSecond line');
      expect(back.lines, hasLength(2));
      expect(back.lines.first.transliteration, 'hello world');
      expect(back.lines.first.syllables, hasLength(2));
      expect(back.lines.first.syllables.last.isBackground, isTrue);
      expect(back.lines.first.syllables.first.isBackground, isFalse);
      expect(back.lines.last.syllables, isEmpty);
    });

    test('instrumental survives; garbage and empty do not', () {
      const inst = LyricsResult(isInstrumental: true, source: 'x');
      expect(decodeLyrics(encodeLyrics(inst))!.isInstrumental, isTrue);
      expect(decodeLyrics('nope'), isNull);
      expect(decodeLyrics('{"v":9}'), isNull);
      expect(decodeLyrics(encodeLyrics(const LyricsResult.empty())), isNull);
    });
  });

  group('repository disk layer', () {
    late AppDatabase db;
    setUp(() => db = AppDatabase.inMemory());

    test('a restart finds the lyrics on disk and skips every provider',
        () async {
      final first = _Repo(_word('lrclib'), db);
      final a = await first.getLyrics(
          title: 'Song', artist: 'Artist', durationSeconds: 8);
      expect(a.isEmpty, isFalse);
      expect(first.calls, greaterThan(0));
      expect(db.cacheStats()['lyrics']!.entries, 1);

      // New instance = empty memory LRU, same database.
      final second = _Repo(null, db);
      final b = await second.getLyrics(
          title: 'Song', artist: 'Artist', durationSeconds: 8);
      expect(second.calls, 0, reason: 'served from disk, no race');
      expect(b.lines, hasLength(2));
      expect(b.isWordSynced, isTrue);
    });

    test('without a database it behaves as before', () async {
      final repo = _Repo(_word('lrclib'), null);
      final r = await repo.getLyrics(
          title: 'Song', artist: 'Artist', durationSeconds: 8);
      expect(r.isEmpty, isFalse);
    });

    test('a track nobody has lyrics for is not cached', () async {
      final repo = _Repo(null, db);
      final r = await repo.getLyrics(
          title: 'Nothing', artist: 'Nobody', durationSeconds: 8);
      expect(r.isEmpty, isTrue);
      expect(db.cacheStats()['lyrics'], isNull);
    });

    test('forceRefresh ignores the stored copy and replaces it', () async {
      final seed = _Repo(_word('old'), db);
      await seed.getLyrics(title: 'Song', artist: 'Artist', durationSeconds: 8);

      final fresh = _Repo(_word('new'), db);
      final r = await fresh.getLyrics(
        title: 'Song',
        artist: 'Artist',
        durationSeconds: 8,
        forceRefresh: true,
      );
      expect(fresh.calls, greaterThan(0));
      expect(r.source, 'new');
    });
  });
}
