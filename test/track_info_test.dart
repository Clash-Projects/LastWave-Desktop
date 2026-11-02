import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/audio/stream_models.dart';
import 'package:lastwave_desktop/ui/components/menus.dart';

void main() {
  group('trackShareLink', () {
    test('uses the YouTube Music watch URL when there is a video id', () {
      const track =
          PlayableTrack(title: 'Song', artist: 'Singer', videoId: 'abc123');
      expect(trackShareLink(track), 'https://music.youtube.com/watch?v=abc123');
    });

    test('falls back to the local path, then to nothing', () {
      const local = PlayableTrack(
        title: 'Song',
        artist: 'Singer',
        playbackUrl: r'C:\Music\song.flac',
      );
      expect(trackShareLink(local), r'C:\Music\song.flac');
      const bare = PlayableTrack(title: 'Song', artist: 'Singer');
      expect(trackShareLink(bare), isNull);
    });
  });

  group('trackMediaOrigin', () {
    late Directory dir;
    late File file;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('lw_origin');
      file = File('${dir.path}${Platform.pathSeparator}song.flac')
        ..writeAsBytesSync([0]);
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('a stream has no path', () {
      const track =
          PlayableTrack(title: 'Song', artist: 'Singer', videoId: 'abc123');
      final origin = trackMediaOrigin(track: track);
      expect(origin.kind, 'Stream');
      expect(origin.path, isNull);
    });

    test('a playback file that exists is a local file', () {
      final track = PlayableTrack(
        title: 'Song',
        artist: 'Singer',
        playbackUrl: file.path,
      );
      final origin = trackMediaOrigin(track: track);
      expect(origin.kind, 'Local file');
      expect(origin.path, file.path);
    });

    test('a downloaded copy of a streamed track is a download', () {
      const track =
          PlayableTrack(title: 'Song', artist: 'Singer', videoId: 'abc123');
      final origin = trackMediaOrigin(track: track, downloadPath: file.path);
      expect(origin.kind, 'Download');
      expect(origin.path, file.path);
    });

    test('the same file as playback and download counts as a download', () {
      final track = PlayableTrack(
        title: 'Song',
        artist: 'Singer',
        playbackUrl: file.path,
      );
      final origin = trackMediaOrigin(track: track, downloadPath: file.path);
      expect(origin.kind, 'Download');
    });
  });

  test('formatTrackDuration', () {
    expect(formatTrackDuration(Duration.zero), 'Unknown');
    expect(formatTrackDuration(const Duration(seconds: 65)), '1:05');
    expect(formatTrackDuration(const Duration(hours: 1, seconds: 5)), '1:00:05');
  });
}
