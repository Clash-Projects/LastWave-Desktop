import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/lyrics/lyrics_models.dart';
import 'package:lastwave_desktop/features/lyrics/lyrics_repository.dart';

LyricsResult _word(String source) => LyricsResult(
      lines: [
        LyricLine(
          timeMs: 1000,
          durationMs: 3000,
          text: 'Hello world',
          syllables: const [
            LyricSyllable(timeMs: 1000, durationMs: 500, text: 'Hello '),
            LyricSyllable(timeMs: 1500, durationMs: 500, text: 'world'),
          ],
        ),
        LyricLine(
          timeMs: 5000,
          durationMs: 3000,
          text: 'Second line',
          syllables: const [
            LyricSyllable(timeMs: 5000, durationMs: 500, text: 'Second '),
            LyricSyllable(timeMs: 5500, durationMs: 500, text: 'line'),
          ],
        ),
      ],
      isSynced: true,
      isWordSynced: true,
      plainLyrics: 'Hello world\nSecond line',
      source: source,
    );

LyricsResult _line(String source) => LyricsResult(
      lines: const [
        LyricLine(timeMs: 1000, durationMs: 3000, text: 'Hello world'),
        LyricLine(timeMs: 5000, durationMs: 3000, text: 'Second line'),
      ],
      isSynced: true,
      isWordSynced: false,
      plainLyrics: 'Hello world\nSecond line',
      source: source,
    );

/// Repository with stubbed providers and short timeouts.
class _StubRepo extends LyricsRepository {
  final Map<String, LyricsResult?> results;
  final Map<String, int> calls = {};
  final Map<String, Duration> delays;

  _StubRepo(this.results, {this.delays = const {}})
      : super(
          Dio(),
          const Duration(milliseconds: 200),
          const Duration(seconds: 2),
        );

  @override
  Future<LyricsResult?> fetchFromProvider(
    String providerId, {
    required String title,
    required String artist,
    String album = '',
    int? durationSeconds,
    String? videoId,
  }) {
    calls[providerId] = (calls[providerId] ?? 0) + 1;
    final delay = delays[providerId] ?? Duration.zero;
    final result = results[providerId];
    if (delay == Duration.zero) return Future.value(result);
    return Future.delayed(delay, () => result);
  }
}

void main() {
  test('word beats faster line; explicit preferred line outranks race line',
      () async {
    // Preferred better (line, slow) vs apple line (fast): preferred wins.
    final repo = _StubRepo({
      'better_lyrics': _line('BetterLyrics (Line-Sync)'),
      'apple_music': _line('Apple Music (Line-Sync)'),
    }, delays: {
      'better_lyrics': const Duration(milliseconds: 100),
    });
    final picked = await repo.getLyrics(
      title: 'T',
      artist: 'A',
      preferredProviderId: 'better_lyrics',
    );
    expect(picked.source, contains('BetterLyrics'));

    // Kugou word (slow) beats apple line (fast) in Auto.
    final auto = _StubRepo({
      'kugou': _word('Kugou KRC (Word-Sync)'),
      'apple_music': _line('Apple Music (Line-Sync)'),
    }, delays: {
      'kugou': const Duration(milliseconds: 300),
    });
    final word = await auto.getLyrics(title: 'T', artist: 'A');
    expect(word.isWordSynced, isTrue);
    expect(word.source, contains('Kugou'));
  });

  test('excluded provider is never attempted; best of rest wins', () async {
    final repo = _StubRepo({
      'kugou': _word('Kugou KRC (Word-Sync)'),
      'apple_music': _line('Apple Music (Line-Sync)'),
    });
    final result = await repo.getLyrics(
      title: 'T',
      artist: 'A',
      excludeProviderIds: const {'kugou'},
    );
    expect(result.isWordSynced, isFalse);
    expect(result.source, contains('Apple'));
    expect(repo.calls.containsKey('kugou'), isFalse);
  });

  test('cache key separates preferred providers', () async {
    final repo = _StubRepo({
      'kugou': _word('Kugou KRC (Word-Sync)'),
      'apple_music': _line('Apple Music (Line-Sync)'),
    });
    await repo.getLyrics(title: 'T', artist: 'A');
    expect(repo.calls['kugou'], 1);
    await repo.getLyrics(title: 'T', artist: 'A');
    expect(repo.calls['kugou'], 1); // served from cache
    await repo.getLyrics(
        title: 'T', artist: 'A', preferredProviderId: 'kugou');
    expect(repo.calls['kugou'], 2); // new key → refetch
  });

  test('race deadline resolves from collected partials', () async {
    final hanging = Completer<LyricsResult?>();
    final repo = _HangingRepo(
      hanging.future,
      line: _line('Apple Music (Line-Sync)'),
    );
    final result = await repo.getLyrics(title: 'T', artist: 'A');
    expect(result.isEmpty, isFalse);
    expect(result.source, contains('Apple'));
  });
}

class _HangingRepo extends LyricsRepository {
  final Future<LyricsResult?> hanging;
  final LyricsResult line;
  _HangingRepo(this.hanging, {required this.line})
      : super(
          Dio(),
          const Duration(milliseconds: 50),
          const Duration(milliseconds: 300),
        );

  @override
  Future<LyricsResult?> fetchFromProvider(
    String providerId, {
    required String title,
    required String artist,
    String album = '',
    int? durationSeconds,
    String? videoId,
  }) {
    if (providerId == 'lrc_red') return hanging;
    if (providerId == 'apple_music') return Future.value(line);
    return Future.value(null);
  }
}
