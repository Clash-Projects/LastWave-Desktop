import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/video/audio_alignment.dart';

/// Irregular onset pattern (no period), like real music at hop scale.
Float32List pattern(int length, int seed) {
  final rng = math.Random(seed);
  return Float32List.fromList([
    for (var i = 0; i < length; i++)
      rng.nextDouble() < 0.18 ? rng.nextDouble() : 0.0,
  ]);
}

Float32List withIntro(Float32List song, int introHops, int seed, int length) {
  final noise = pattern(introHops, seed);
  final out = Float32List(length);
  for (var i = 0; i < length; i++) {
    out[i] = i < introHops
        ? noise[i]
        : (i - introHops < song.length ? song[i - introHops] : 0);
  }
  return out;
}

void main() {
  test('finds a video intro offset', () {
    final song = pattern(1000, 1); // 50 s
    final video = withIntro(pattern(3000, 1), 240, 99, 2000); // 12 s intro
    expect(estimateConsistentVideoOffsetMs(song, video), 240 * alignmentHopMs);
  });

  test('zero offset for the same timeline', () {
    final song = pattern(1000, 7);
    final video = pattern(2000, 7);
    expect(estimateConsistentVideoOffsetMs(song, video), 0);
  });

  test('unrelated audio yields no offset', () {
    expect(
      estimateConsistentVideoOffsetMs(pattern(1000, 3), pattern(2000, 4)),
      isNull,
    );
  });

  test('too little audio yields no offset', () {
    expect(estimateVideoOffsetMs(pattern(100, 3), pattern(2000, 3)), isNull);
  });

  test('pcm pipeline recovers an offset end to end', () {
    const rate = 8000;
    final rng = math.Random(5);
    // Bursty noise: random loud/quiet 50 ms blocks.
    final blocks = [for (var i = 0; i < 2200; i++) rng.nextDouble() < 0.2];
    Uint8List render(int startBlock, int count) {
      final data = ByteData(count * 400 * 2);
      final r = math.Random(11);
      for (var b = 0; b < count; b++) {
        final loud = startBlock + b >= 0 && blocks[startBlock + b];
        for (var i = 0; i < 400; i++) {
          final v = ((r.nextDouble() * 2 - 1) * (loud ? 20000 : 300)).round();
          data.setInt16((b * 400 + i) * 2, v, Endian.little);
        }
      }
      return data.buffer.asUint8List();
    }

    final song = render(100, 1000); // song starts 5 s into the video
    final video = render(0, 2000);
    expect(
      alignPcm16((song: song, video: video, sampleRate: rate)),
      100 * alignmentHopMs,
    );
  });
}
