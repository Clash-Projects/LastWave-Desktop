import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/settings/accent.dart';
import 'package:lastwave_desktop/ui/components/ambient.dart';
import 'package:lastwave_desktop/ui/theme/tokens.dart';

ArtworkPalette _palette(Color primary) => ArtworkPalette(
      primary: primary,
      vibrant: primary,
      darkMuted: primary,
      lightVibrant: primary,
      cream: const Color(0xFFEEEEEE),
      shadow: const Color(0xFF000000),
    );

void main() {
  test('artwork theme keeps the cover hue on a dark, readable base', () {
    final base = themeBaseFromPalette(_palette(const Color(0xFFE03030)));
    final hsl = HSLColor.fromColor(base);
    expect(hsl.hue, closeTo(0, 2));
    expect(WaveSurfaces.isLightBase(base), isFalse);
    expect(WaveSurfaces.fromCustomBase(base).isCustom, isTrue);
  });

  test('a light or grey cover still gives a dark, near-neutral base', () {
    final white = themeBaseFromPalette(_palette(const Color(0xFFF5F5F5)));
    expect(WaveSurfaces.isLightBase(white), isFalse);
    expect(HSLColor.fromColor(white).saturation, lessThan(0.18));
  });
}
