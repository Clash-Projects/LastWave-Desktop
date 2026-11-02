import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/audio/stream_models.dart';
import 'package:lastwave_desktop/core/network/dio_factory.dart';
import 'package:lastwave_desktop/core/network/lastfm_api.dart';
import 'package:lastwave_desktop/core/network/rate_guard.dart';
import 'package:lastwave_desktop/core/storage/app_database.dart';
import 'package:lastwave_desktop/core/storage/prefs.dart';
import 'package:lastwave_desktop/core/storage/secure_store.dart';
import 'package:lastwave_desktop/features/downloads/download_manager.dart';
import 'package:lastwave_desktop/features/innertube/innertube_api.dart';
import 'package:lastwave_desktop/features/lastfm/scrobble_repository.dart';
import 'package:lastwave_desktop/features/lossless/lossless_source.dart';
import 'package:lastwave_desktop/features/lyrics/lyrics_repository.dart';
import 'package:lastwave_desktop/features/player/playback_service.dart';
import 'package:lastwave_desktop/features/player/player_state.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _NoLossless implements LosslessSource {
  @override
  bool get isConfigured => false;

  @override
  Future<ResolvedStream?> resolveStream({
    required String title,
    required String artist,
    String album = '',
    int expectedDurationSeconds = 0,
    int preferredQuality = 27,
  }) async =>
      null;

  @override
  void invalidateStream({required String title, required String artist}) {}

  @override
  void clearStreamCache() {}
}

/// Waits until the snapshot reports [target] played time.
Future<Duration> _waitForPosition(
  PlaybackService service,
  Duration target, {
  Duration timeout = const Duration(seconds: 90),
}) {
  final completer = Completer<Duration>();
  void check(PlayerSnapshot snapshot) {
    if (completer.isCompleted) return;
    if (snapshot.position >= target) {
      completer.complete(snapshot.position);
    } else if (snapshot.error != null) {
      completer.completeError(StateError('playback error: ${snapshot.error}'));
    }
  }

  final remove = service.addListener(check);
  check(service.state);
  return completer.future.timeout(timeout).whenComplete(remove);
}

void main() {
  test(
      'real PlaybackService resolves, opens mpv and advances through the queue',
      () async {
    SharedPreferences.setMockInitialValues({});
    MediaKit.ensureInitialized(
      libmpv:
          File('build/windows/x64/runner/Release/libmpv-2.dll').absolute.path,
    );

    final prefs = await Prefs.load();
    final db = AppDatabase.inMemory();
    final tube = InnerTubeMusicApi(DioFactory.create(), SecureStore());
    final lossless = _NoLossless();
    final scrobbler = ScrobbleRepository(
      LastFmApiService(DioFactory.create(), LastFmRateGuard()),
      prefs,
    );
    final downloads =
        DownloadManager(db, prefs, lossless, tube, LyricsRepository());
    final service = PlaybackService(
      tube,
      lossless,
      scrobbler,
      downloads,
      PrefsHandle(prefs),
      SessionStore(db),
    );
    addTearDown(() async {
      await service.disposePlayer();
      service.dispose();
      downloads.dispose();
      db.raw.close();
    });

    await service.ensurePlayer();
    await service.setVolume(0);

    const first = PlayableTrack(
      title: 'Qaafirana',
      artist: 'Arijit Singh',
    );
    const second = PlayableTrack(
      title: 'Tum Hi Ho',
      artist: 'Arijit Singh',
    );

    await service.playQueue([first, second], 0, sourceLabel: 'e2e');

    final firstPosition =
        await _waitForPosition(service, const Duration(seconds: 3));
    expect(firstPosition, greaterThanOrEqualTo(const Duration(seconds: 3)));
    expect(service.state.isPlaying, isTrue,
        reason: 'player should report playing, not skip');
    expect(service.state.error, isNull);

    final stream = service.state.stream;
    expect(stream, isNotNull, reason: 'a stream must have been resolved');
    expect(stream!.url.startsWith('sabr:'), isFalse,
        reason: 'mpv cannot open SABR protocol URLs');
    expect(
      stream.mimeType.startsWith('audio/') ||
          stream.mimeType == 'video/mp4' ||
          stream.mimeType.contains('mpegurl'),
      isTrue,
      reason: 'unexpected stream container: ${stream.mimeType}',
    );
    expect(stream.bitrateKbps, greaterThan(0));
    expect(service.state.current?.videoId, isNotEmpty,
        reason: 'resolved match should be written back to the queue');

    await service.next();
    final secondPosition =
        await _waitForPosition(service, const Duration(seconds: 2));
    expect(secondPosition, greaterThanOrEqualTo(const Duration(seconds: 2)));
    expect(service.state.currentIndex, 1);
    expect(service.state.current?.title, second.title);
    expect(service.state.isPlaying, isTrue);
  },
      skip: !Platform.isWindows || !const bool.fromEnvironment('LIVE_PLAYBACK'),
      timeout: const Timeout(Duration(minutes: 6)));
}
