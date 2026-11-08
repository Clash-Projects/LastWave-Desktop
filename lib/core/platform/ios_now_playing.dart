import 'dart:io';

import 'package:flutter/services.dart';

/// iPadOS Lock Screen, Control Center, and headset media controls.
///
/// Playback remains owned by the existing PlaybackService/media_kit player.
/// This channel only mirrors metadata and forwards system transport commands.
class IosNowPlayingBridge {
  IosNowPlayingBridge._();

  static const MethodChannel _channel = MethodChannel('com.lastwave/audio');
  static bool _initialized = false;

  static Future<void> initialize({
    required Future<void> Function() onPlay,
    required Future<void> Function() onPause,
    required Future<void> Function() onToggle,
    required Future<void> Function() onNext,
    required Future<void> Function() onPrevious,
    required Future<void> Function(Duration position) onSeek,
  }) async {
    if (!Platform.isIOS || _initialized) return;

    // Register the Dart-side handlers before asking native iOS to enable
    // remote commands, so a command can never arrive without a receiver.
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'play':
        case 'resume':
          await onPlay();
          return;
        case 'pause':
          await onPause();
          return;
        case 'toggle':
          await onToggle();
          return;
        case 'next':
          await onNext();
          return;
        case 'previous':
          await onPrevious();
          return;
        case 'seek':
          final seconds = (call.arguments as num?)?.toDouble() ?? 0;
          final safeSeconds = seconds.isFinite && seconds > 0 ? seconds : 0;
          await onSeek(
            Duration(milliseconds: (safeSeconds * 1000).round()),
          );
          return;
        default:
          throw PlatformException(
            code: 'unimplemented_media_command',
            message: 'Unsupported iPadOS media command: ${call.method}',
          );
      }
    });

    await _channel.invokeMethod<void>('configure');
    _initialized = true;
  }

  static Future<void> update({
    required String title,
    required String artist,
    required String album,
    required String artworkUrl,
    required Duration duration,
    required Duration position,
    required bool isPlaying,
    required double speed,
  }) async {
    if (!Platform.isIOS || !_initialized) return;

    try {
      await _channel.invokeMethod<void>('updateNowPlaying', {
        'title': title,
        'artist': artist,
        'album': album,
        'artworkUrl': artworkUrl,
        'durationSeconds': duration.inMilliseconds / 1000.0,
        'positionSeconds': position.inMilliseconds / 1000.0,
        'isPlaying': isPlaying,
        'speed': speed,
      });
    } catch (_) {
      // The system media surface is supplementary; it must not interrupt
      // playback if iOS temporarily rejects a metadata update.
    }
  }

  static Future<void> clear() async {
    if (!Platform.isIOS || !_initialized) return;
    try {
      await _channel.invokeMethod<void>('clearNowPlaying');
    } catch (_) {}
  }
}
