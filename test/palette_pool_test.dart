import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/ui/components/ambient.dart';

/// Raw straight RGBA, 4 bytes per pixel — the shape
/// `ui.Image.toByteData()` produces and `PaletteGenerator.fromByteData`
/// documents. A solid fill keeps the palette deterministic.
List<int> _solid(int w, int h, int r, int g, int b) {
  final out = <int>[];
  for (var i = 0; i < w * h; i++) {
    out
      ..add(r)
      ..add(g)
      ..add(b)
      ..add(255);
  }
  return out;
}

void main() {
  test('every palette job resolves through the warm isolates', () async {
    final before = palettePoolFallbacks;

    for (var i = 0; i < 12; i++) {
      final palette = await extractPaletteForTest(
        _solid(16, 16, 0x33, 0x66, 0xCC),
        16,
        16,
      );
      expect(palette, isA<ArtworkPalette>());
      expect(palette.primary.a, 1.0);
    }

    // The failure this guards against: `_send` was never assigned from the
    // isolate handshake, so `_sendPort()` always threw and every request
    // fell back to `compute()` — one isolate spawned (plus one killed) per
    // palette instead of zero.
    expect(palettePoolFallbacks, before,
        reason: 'warm pool should never fall back to compute()');
  });

  test('concurrent jobs keep their own payloads', () async {
    final red = _solid(24, 24, 0xE0, 0x30, 0x30);
    final blue = _solid(24, 24, 0x20, 0x50, 0xC0);

    final results = await Future.wait([
      for (var i = 0; i < 8; i++)
        i.isEven
            ? extractPaletteForTest(red, 24, 24)
            : extractPaletteForTest(blue, 24, 24),
    ]);

    expect(results, hasLength(8));
    // Interleaved payloads must not be crossed by the round-robin pool.
    final even = results[0].primary;
    final odd = results[1].primary;
    expect(even, isNot(odd));
    for (var i = 2; i < 8; i += 2) {
      expect(results[i].primary, even);
    }
    for (var i = 3; i < 8; i += 2) {
      expect(results[i].primary, odd);
    }

    expect(palettePoolFallbacks, 0);
  });
}
