import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/jam/jam_client.dart';

void main() {
  test('a track survives the wire format', () {
    const track = JamTrack(
      id: 'dQw4w9WgXcQ',
      title: 'Song',
      artist: 'Artist',
      album: 'Album',
      artworkUrl: 'https://example.com/a.jpg',
      durationMs: 212000,
    );
    final back = JamTrack.fromJson(track.toJson());
    expect(back.id, track.id);
    expect(back.title, track.title);
    expect(back.artist, track.artist);
    expect(back.album, track.album);
    expect(back.durationMs, 212000);
  });

  test('missing and string fields do not throw', () {
    final track = JamTrack.fromJson({'title': 'Only a title', 'duration_ms': '5000'});
    expect(track.id, '');
    expect(track.artist, '');
    expect(track.durationMs, 5000);
  });
}
