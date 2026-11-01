import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/app/window_title.dart';
import 'package:lastwave_desktop/core/audio/stream_models.dart';

void main() {
  test('window title is the song and artist', () {
    expect(
      windowTitleFor(const PlayableTrack(title: 'Cheap Thrills', artist: 'Sia')),
      'Cheap Thrills \u2014 Sia',
    );
  });

  test('window title falls back to the song when the artist is missing', () {
    expect(
      windowTitleFor(const PlayableTrack(title: 'Cheap Thrills', artist: '')),
      'Cheap Thrills',
    );
  });

  test('window title falls back to the app name when nothing plays', () {
    expect(windowTitleFor(null), 'LastWave');
    expect(
      windowTitleFor(const PlayableTrack(title: '  ', artist: 'Sia')),
      'LastWave',
    );
  });
}
