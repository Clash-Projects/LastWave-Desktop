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
      alignPcm16((song: song, video: video, sampleRate: rate))?.offsetMs,
      100 * alignmentHopMs,
    );
  });

  group('different master or mix', () {
    Float32List mixed(double noise) {
      final base = pattern(3000, 1);
      final other = pattern(2200, 77);
      final v = Float32List(2000);
      for (var i = 0; i < 2000; i++) {
        final s = i >= 240 && i - 240 < base.length ? base[i - 240] : 0.0;
        v[i] = s + noise * other[i];
      }
      return v;
    }

    test('a weak match is accepted on the loose pass, at the right spot', () {
      final song = pattern(1000, 1);
      final video = mixed(2.0);
      expect(estimateVideoOffsetMs(song, video), isNull);
      final result = estimateAlignment(song, video);
      expect(result, isNotNull);
      expect(result!.relaxed, isTrue);
      expect(result.offsetMs, 240 * alignmentHopMs);
    });

    test('a clean match does not need the loose pass', () {
      final result = estimateAlignment(pattern(1000, 1), mixed(0.5));
      expect(result!.relaxed, isFalse);
      expect(result.offsetMs, 240 * alignmentHopMs);
    });

    test('drowned-out audio still yields nothing', () {
      expect(estimateAlignment(pattern(1000, 1), mixed(4.0)), isNull);
    });

    test('loose pass never invents a match between unrelated tracks', () {
      var falsePositives = 0;
      for (var seed = 100; seed < 140; seed++) {
        if (estimateAlignment(
              pattern(1000, seed),
              pattern(2000, seed + 1000),
            ) !=
            null) {
          falsePositives++;
        }
      }
      expect(falsePositives, 0);
    });
  });

  group('spectral flux', () {
    const rate = 8000;

    /// Tonal "notes" at random pitches and times over quiet noise, so the
    /// signal has spectral structure, not only loudness.
    Float64List music(int seconds, int seed) {
      final rng = math.Random(seed);
      final out = Float64List(seconds * rate);
      var i = 0;
      while (i < out.length) {
        final len = 800 + rng.nextInt(3200);
        final freq = 110.0 * math.pow(2, rng.nextInt(36) / 12);
        final amp = 0.1 + rng.nextDouble() * 0.4;
        for (var k = 0; k < len && i + k < out.length; k++) {
          final env = math.exp(-k / (len / 3));
          out[i + k] += amp * env * math.sin(2 * math.pi * freq * k / rate);
        }
        i += len ~/ (1 + rng.nextInt(2));
      }
      return out;
    }

    Uint8List pcm(Float64List x) {
      final b = ByteData(x.length * 2);
      for (var i = 0; i < x.length; i++) {
        b.setInt16(
          i * 2,
          (x[i].clamp(-1.0, 1.0) * 32767).round(),
          Endian.little,
        );
      }
      return b.buffer.asUint8List();
    }

    test('one value per hop', () {
      final flux = spectralFluxFromPcm16(pcm(music(10, 1)), rate);
      expect(flux.length, closeTo(10000 / alignmentHopMs, 2));
    });

    test('finds a film-style intro under a different mix', () {
      final track = music(120, 3);
      final song = Float64List.sublistView(track, 0, 60 * rate);
      // 25 s of unrelated "dialogue" first, then the song at lower level
      // with other sound laid over it.
      final noise = music(160, 9);
      final video = Float64List(150 * rate);
      for (var i = 0; i < video.length; i++) {
        final t = i - 25 * rate;
        final s = t >= 0 && t < track.length ? track[t] * 0.6 : 0.0;
        video[i] = s + noise[i] * (t < 0 ? 0.8 : 0.25);
      }
      final r = alignPcm16((
        song: pcm(song),
        video: pcm(video),
        sampleRate: rate,
      ));
      expect(r?.offsetMs, 25000);
    });

    test('unrelated music does not align', () {
      expect(
        alignPcm16((
          song: pcm(music(60, 21)),
          video: pcm(music(150, 22)),
          sampleRate: rate,
        )),
        isNull,
      );
    });

    test('a re-edit is not confirmed but its opening is guessed', () {
      final track = music(120, 5);
      final song = Float64List.sublistView(track, 0, 60 * rate);
      // Video: 10 s intro, first 35 s of the song, a 20 s scene, the rest.
      final scene = music(20, 31);
      final intro = music(10, 32);
      final video = Float64List.fromList([
        ...intro,
        ...track.sublist(0, 35 * rate),
        ...scene,
        ...track.sublist(35 * rate, 100 * rate),
      ]);
      final input = (song: pcm(song), video: pcm(video), sampleRate: rate);
      expect(guessOffsetPcm16(input), 10000);
    });
  });
}
