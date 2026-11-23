import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/lyrics/lyric_texture_cache.dart';
import 'package:lastwave_desktop/features/lyrics/lyrics_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('LyricTextureCache enforces sliding window eviction (<= 15 items)', () async {
    final cache = LyricTextureCache();
    final lines = List.generate(
      60,
      (i) => LyricLine(
        timeMs: i * 3000,
        durationMs: 2500,
        text: 'Line $i of the song with some words to test baking',
      ),
    );

    const activeStyle = TextStyle(fontSize: 24, color: Colors.white);
    const inactiveStyle = TextStyle(fontSize: 24, color: Colors.grey);

    // Step through lines from 0 to 59
    for (var current = 0; current < 60; current += 3) {
      await cache.syncWindow(
        activeIndex: current,
        lines: lines,
        maxWidth: 600,
        dpr: 1.0,
        activeStyle: activeStyle,
        inactiveStyle: inactiveStyle,
        font: 'Segoe UI',
      );
      // Window is [activeIndex - 6 .. activeIndex + 8], max items = 15
      expect(cache.length, lessThanOrEqualTo(15));
    }

    cache.dispose();
  });
}
