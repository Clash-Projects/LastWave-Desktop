// ignore_for_file: avoid_print
// End-to-end: the real PlaybackService, two real libmpv decks on mpv's
// null output (real-time clock), three generated tracks, two AutoMix
// hand-offs in a row. Guards the regressions users actually hit:
//  * after a mix the listener's volume must be unchanged (it once fell
//    to ~0 and the next mix faded songs to silence);
//  * the incoming song must be audible during the second mix too;
//  * after each mix exactly one deck is audible, at full level;
//  * no watchdog repairs were needed.
// Needs libmpv (skipped otherwise).
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/audio/stream_models.dart';
import 'package:lastwave_desktop/core/storage/prefs.dart';
import 'package:lastwave_desktop/features/downloads/download_manager.dart';
import 'package:lastwave_desktop/features/innertube/innertube_api.dart';
import 'package:lastwave_desktop/features/lastfm/scrobble_repository.dart';
import 'package:lastwave_desktop/features/lossless/lossless_source.dart';
import 'package:lastwave_desktop/features/player/playback_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Tube extends Fake implements InnerTubeMusicApi {
  @override
  void prefetchNextTrack(String videoId) {}
  @override
  void reportPlaybackFailure(String videoId) {}
}

class _Lossless extends Fake implements LosslessSource {
  @override
  bool get isConfigured => false;
  @override
  void invalidateStream({required String title, required String artist}) {}
  @override
  void clearStreamCache() {}
}

class _Scrobbler extends Fake implements ScrobbleRepository {
  @override
  Future<ScrobbleOutcome> updateNowPlaying(
          {required String artist, required String track, String album = ''}) async =>
      ScrobbleOutcome.noSession;
  @override
  Future<ScrobbleOutcome> scrobble(
          {required String artist,
          required String track,
          String album = '',
          required int timestampSec}) async =>
      ScrobbleOutcome.noSession;
}

class _Downloads extends Fake implements DownloadManager {
  @override
  String? localPathFor(String title, String artist) => null;
}

class _Sessions extends Fake implements SessionStore {
  @override
  Map<String, dynamic> load() => {};
  @override
  void save(Map<String, dynamic> payload) {}
  @override
  void clear() {}
  @override
  void recordLocalPlay(String title, String artist) {}
}

/// Mono 16-bit WAV: accented kick on every beat, off-beat hats, a pad.
File writeDrums(String path, double bpm, double seconds) {
  const sr = 22050;
  final n = (seconds * sr).round();
  final x = Float64List(n);
  final rnd = math.Random(bpm.round());
  final beat = 60 / bpm;
  var i = 0;
  for (var t = 0.5; t < seconds - 1.5; t += beat, i++) {
    final s = (t * sr).round();
    for (var k = 0; k < 0.15 * sr && s + k < n; k++) {
      final tt = k / sr;
      x[s + k] += math.sin(2 * math.pi * (55 + 90 * math.exp(-tt * 30)) * tt) *
          math.exp(-tt * 12) *
          (i % 4 == 0 ? 1.0 : 0.7);
    }
    final h = ((t + beat / 2) * sr).round();
    for (var k = 0; k < 0.03 * sr && h + k < n; k++) {
      x[h + k] += (rnd.nextDouble() * 2 - 1) * 0.15 * math.exp(-k / sr * 120);
    }
  }
  for (var k = (0.5 * sr).round(); k < ((seconds - 1.5) * sr).round(); k++) {
    x[k] += 0.1 * math.sin(2 * math.pi * 220 * k / sr);
  }
  final b = BytesBuilder();
  void u32(int v) => b.add((ByteData(4)..setUint32(0, v, Endian.little))
      .buffer
      .asUint8List());
  void u16(int v) => b.add((ByteData(2)..setUint16(0, v, Endian.little))
      .buffer
      .asUint8List());
  b.add('RIFF'.codeUnits);
  u32(36 + n * 2);
  b.add('WAVEfmt '.codeUnits);
  u32(16);
  u16(1);
  u16(1);
  u32(sr);
  u32(sr * 2);
  u16(2);
  u16(16);
  b.add('data'.codeUnits);
  u32(n * 2);
  final pcm = ByteData(n * 2);
  for (var k = 0; k < n; k++) {
    pcm.setInt16(k * 2, (x[k].clamp(-1.6, 1.6) / 1.6 * 30000).round(),
        Endian.little);
  }
  b.add(pcm.buffer.asUint8List());
  return File(path)..writeAsBytesSync(b.toBytes());
}

void main() {
  final hasMpv = File('/usr/lib/x86_64-linux-gnu/libmpv.so.2').existsSync();

  test('two AutoMix hand-offs keep volume, audibility and decks sane',
      () async {
    final dir = await Directory.systemTemp.createTemp('automix-e2e');
    final tracks = [
      for (final (i, bpm) in [124.0, 126.0, 128.0].indexed)
        PlayableTrack(
          title: 'Track $i',
          artist: 'Artist $i',
          playbackUrl: writeDrums('${dir.path}/t$i.wav', bpm, 64).path,
        ),
    ];
    SharedPreferences.setMockInitialValues({
      'lw_automix_enabled': true,
      'lw_automix_seconds': 14,
      'lw_automix_spectral': true,
    });
    final prefs = Prefs(await SharedPreferences.getInstance());
    PlaybackService.debugAudioOutput = 'null';
    final svc = PlaybackService(_Tube(), _Lossless(), _Scrobbler(),
        _Downloads(), PrefsHandle(prefs), _Sessions());
    await svc.ensurePlayer();
    await svc.setVolume(0.7);
    await svc.playQueue(tracks, 0);

    Future<void> until(bool Function() ok, Duration max) async {
      final end = DateTime.now().add(max);
      while (!ok()) {
        if (DateTime.now().isAfter(end)) fail('timed out');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }

    for (var hop = 1; hop <= 2; hop++) {
      await until(() => svc.state.duration > Duration.zero,
          const Duration(seconds: 10));
      // Past the analysis threshold, well before the mix window.
      await Future<void>.delayed(const Duration(seconds: 1));
      await svc.seek(const Duration(seconds: 38));
      var maxIncoming = 0.0;
      var sawMix = false;
      final end = DateTime.now().add(const Duration(seconds: 40));
      while (svc.state.currentIndex != hop) {
        if (DateTime.now().isAfter(end)) fail('no hand-off to $hop');
        final m = svc.debugMixState;
        if (m.mixing) {
          sawMix = true;
          maxIncoming = math.max(maxIncoming, m.standbyVolume ?? 0);
        }
        // The listener's volume never moves during a mix.
        expect(svc.state.volume, 0.7);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      print('hop $hop: mixed=$sawMix max_incoming_volume=$maxIncoming');
      expect(sawMix, isTrue, reason: 'hop $hop should be an overlap');
      expect(maxIncoming, greaterThan(50),
          reason: 'incoming song must be audible during mix $hop');
      // Settled: one deck at full level, the other silent.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final m = svc.debugMixState;
      expect(m.primaryVolume, closeTo(70, 1));
      expect(m.standbyVolume ?? 0, lessThan(0.5));
      expect(svc.state.volume, 0.7);
    }
    // Let the watchdog take a few looks at the settled state.
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(svc.debugMixState.faults, 0);
    await svc.disposePlayer();
  },
      skip: !hasMpv,
      timeout: const Timeout(Duration(minutes: 3)));
}
