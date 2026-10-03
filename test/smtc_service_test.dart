import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/audio/stream_models.dart';
import 'package:lastwave_desktop/features/player/player_state.dart';
import 'package:lastwave_desktop/features/smtc/smtc_service.dart';

const _track = PlayableTrack(
  title: 'Song',
  artist: 'Artist',
  album: 'Album',
  artworkUrl: 'https://example.com/cover.jpg',
);

PlayerSnapshot _snap({
  PlayableTrack? current = _track,
  bool isPlaying = true,
  bool isBuffering = false,
  Duration position = Duration.zero,
  Duration duration = const Duration(minutes: 3),
  double speed = 1.0,
}) =>
    PlayerSnapshot(
      current: current,
      isPlaying: isPlaying,
      isBuffering: isBuffering,
      position: position,
      duration: duration,
      speed: speed,
    );

void main() {
  group('smtcStatusFor', () {
    test('stopped with no track', () {
      expect(smtcStatusFor(const PlayerSnapshot()), smtcStatusStopped);
    });

    test('playing / paused / buffering map distinctly', () {
      expect(smtcStatusFor(_snap()), smtcStatusPlaying);
      expect(
          smtcStatusFor(_snap(isPlaying: false)), smtcStatusPaused);
      expect(
          smtcStatusFor(_snap(isPlaying: true, isBuffering: true)),
          smtcStatusChanging);
    });
  });

  group('smtcUpdateFor', () {
    test('first snapshot always pushes with rate + track flags', () {
      final update = smtcUpdateFor(null, _snap());
      expect(update, isNotNull);
      expect(update!['title'], 'Song');
      expect(update['status'], smtcStatusPlaying);
      expect(update['rate'], 1.0);
      expect(update['hasTrack'], isTrue);
      expect(update['canNext'], isTrue);
      expect(update['canPrev'], isTrue);
    });

    test('pausing freezes the shell timeline via zero rate', () {
      final before = _snap();
      final update =
          smtcUpdateFor(before, _snap(isPlaying: false));
      expect(update, isNotNull);
      expect(update!['status'], smtcStatusPaused);
      expect(update['rate'], 0.0);
    });

    test('identical ticks do not push (shell extrapolates)', () {
      final before = _snap(position: const Duration(seconds: 10));
      final same =
          _snap(position: const Duration(seconds: 10, milliseconds: 500));
      expect(smtcUpdateFor(before, same), isNull);
    });

    test('seeks past the threshold push with clamped position', () {
      final before = _snap(position: const Duration(seconds: 10));
      final after = _snap(position: const Duration(seconds: 60));
      final update = smtcUpdateFor(before, after);
      expect(update, isNotNull);
      expect(update!['positionMs'], 60000);
    });

    test('track end clears to stopped without track flags', () {
      final update = smtcUpdateFor(
          _snap(), const PlayerSnapshot());
      expect(update, isNotNull);
      expect(update!['status'], smtcStatusStopped);
      expect(update['hasTrack'], isFalse);
      expect(update['canNext'], isFalse);
    });
  });
}
