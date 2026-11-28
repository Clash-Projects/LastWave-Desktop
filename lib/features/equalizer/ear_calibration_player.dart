import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'ear_tone_generator.dart';

/// Lightweight, isolated calibration audio player for playing safe warble
/// tones during the listener's Ear Profile calibration.
///
/// Mirrors [AnimatedArtworkSession]'s serialized native-op pattern so rapid
/// user taps never race `libmpv` open/stop/dispose calls.
class EarCalibrationPlayer {
  Player? _player;
  Directory? _tempDir;
  int _slot = 0;
  int _playGeneration = 0;
  bool _disposed = false;
  bool _isPlaying = false;
  Future<void> _tail = Future<void>.value();

  bool get isPlaying => _isPlaying;

  Future<void> _serialized(Future<void> Function() fn) {
    final next = _tail.then((_) async {
      try {
        await fn();
      } catch (e) {
        debugPrint('EarCalibrationPlayer op failed: $e');
      }
    });
    _tail = next;
    return next;
  }

  Future<Player?> _ensurePlayer() async {
    if (_disposed) return null;
    if (_player != null) return _player;
    MediaKit.ensureInitialized();
    final created = Player(
      configuration: const PlayerConfiguration(
        vo: 'null',
        title: 'LastWave Ear Calibration',
        bufferSize: 512 * 1024,
        osc: false,
        logLevel: MPVLogLevel.error,
      ),
    );
    try {
      final dyn = created.platform as dynamic;
      if (dyn != null) {
        try {
          await dyn.setProperty('vid', 'no');
        } catch (_) {}
        try {
          await dyn.setProperty('audio-display', 'no');
        } catch (_) {}
        try {
          await dyn.setProperty('load-scripts', 'no');
        } catch (_) {}
      }
    } catch (_) {}
    if (_disposed) {
      try {
        await created.dispose();
      } catch (_) {}
      return null;
    }
    _player = created;
    return created;
  }

  Future<Directory> _ensureTempDir() async {
    final existing = _tempDir;
    if (existing != null && existing.existsSync()) return existing;
    final created = await Directory.systemTemp.createTemp('lastwave_ear_');
    _tempDir = created;
    return created;
  }

  /// Synthesizes and plays a looping warble cue for [freqHz] at
  /// [attenuationDb] on [channel].
  Future<void> playTone({
    required int freqHz,
    required double attenuationDb,
    EarChannel channel = EarChannel.both,
  }) async {
    if (_disposed) return;
    final gen = ++_playGeneration;
    final wavBytes = EarToneGenerator.synthesizeWarbleWav(
      freqHz: freqHz,
      attenuationDb: attenuationDb,
      channel: channel,
    );

    await _serialized(() async {
      if (_disposed || gen != _playGeneration) return;
      final dir = await _ensureTempDir();
      if (_disposed || gen != _playGeneration) return;

      // Alternate filenames so Windows never locks a file still closing in mpv.
      _slot = (_slot + 1) % 2;
      final file = File(
        '${dir.path}${Platform.pathSeparator}cue_$_slot.wav',
      );
      await file.writeAsBytes(wavBytes, flush: true);

      final player = await _ensurePlayer();
      if (player == null || _disposed || gen != _playGeneration) return;

      await player.setPlaylistMode(PlaylistMode.single);
      await player.setVolume(100);
      await player.open(Media(file.path), play: true);
      _isPlaying = true;
    });
  }

  /// Stops any active calibration cue without destroying the player instance.
  Future<void> stopTone() async {
    _playGeneration++;
    _isPlaying = false;
    await _serialized(() async {
      final player = _player;
      if (player == null) return;
      try {
        await player.pause();
      } catch (_) {}
      try {
        await player.stop();
      } catch (_) {}
    });
  }

  /// Releases the underlying `libmpv` player and removes temp WAV files.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _playGeneration++;
    _isPlaying = false;
    await _serialized(() async {
      final player = _player;
      _player = null;
      if (player != null) {
        try {
          await player.pause();
        } catch (_) {}
        try {
          await player.stop();
        } catch (_) {}
        try {
          await player.dispose();
        } catch (_) {}
      }
      final dir = _tempDir;
      _tempDir = null;
      if (dir != null) {
        try {
          if (dir.existsSync()) {
            await dir.delete(recursive: true);
          }
        } catch (_) {}
      }
    });
  }
}
