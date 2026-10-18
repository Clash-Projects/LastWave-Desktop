import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/storage/prefs.dart';
import 'package:lastwave_desktop/features/settings/accent.dart';
import 'package:lastwave_desktop/features/settings/system_accent.dart';
import 'package:lastwave_desktop/ui/components/ambient.dart';
import 'package:lastwave_desktop/ui/theme/fluent_theme.dart';
import 'package:lastwave_desktop/ui/theme/tokens.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Sentinel for "leave this provider to the real implementation".
const _none = Object();

/// Accent resolution: the settings-facing "Accent source" modes.
///
/// Covers the parts that can be tested without an OS or a display — the
/// per-platform probes' output parsers, the source-id mapping (including the
/// legacy `manual` value) and the cover-palette → accent derivation.
ArtworkPalette paletteWith({
  required Color vibrant,
  Color? primary,
  Color? lightVibrant,
}) =>
    ArtworkPalette(
      primary: primary ?? vibrant,
      vibrant: vibrant,
      darkMuted: const Color(0xFF101010),
      lightVibrant: lightVibrant ?? vibrant,
      cream: const Color(0xFFF0F0F0),
      shadow: const Color(0xFF000000),
    );

void main() {
  group('AccentSource.fromId', () {
    test('maps every supported id', () {
      expect(AccentSource.fromId('custom'), AccentSource.custom);
      expect(AccentSource.fromId('lastwave'), AccentSource.lastwave);
      expect(AccentSource.fromId('system'), AccentSource.system);
      expect(AccentSource.fromId('artwork'), AccentSource.artwork);
    });

    test('legacy/manual/unknown fall back to custom', () {
      expect(AccentSource.fromId('manual'), AccentSource.custom);
      expect(AccentSource.fromId('nonsense'), AccentSource.custom);
      expect(AccentSource.fromId(null), AccentSource.custom);
    });

    test('ids round-trip (what prefs stores)', () {
      for (final source in AccentSource.values) {
        expect(AccentSource.fromId(source.id), source);
      }
    });
  });

  group('accentFromPalette', () {
    test('normalises a mid-tone cover colour into the accent band', () {
      // Warm brown: usable, but far darker than an accent should be.
      final accent = accentFromPalette(
        paletteWith(vibrant: const Color(0xFF8A4A28)),
      );
      expect(accent, isNotNull);
      final hsl = HSLColor.fromColor(accent!);
      expect(hsl.lightness, inInclusiveRange(0.44, 0.63));
      expect(hsl.saturation, inInclusiveRange(0.44, 0.86));
    });

    test('keeps hue (a blue cover tints blue)', () {
      final accent = accentFromPalette(
        paletteWith(vibrant: const Color(0xFF204060)),
      );
      expect(accent, isNotNull);
      final hue = HSLColor.fromColor(accent!).hue;
      expect(hue, inInclusiveRange(190, 240));
    });

    test('grey covers give no accent (caller keeps custom)', () {
      expect(
        accentFromPalette(
          paletteWith(
            vibrant: const Color(0xFF808080),
            primary: const Color(0xFF9A9A9A),
            lightVibrant: const Color(0xFF6E6E6E),
          ),
        ),
        isNull,
      );
    });

    test('near-black and near-white candidates are skipped', () {
      expect(
        accentFromPalette(
          paletteWith(
            vibrant: const Color(0xFF050505),
            primary: const Color(0xFFFEFEFE),
            lightVibrant: const Color(0xFF101010),
          ),
        ),
        isNull,
      );
    });

    test('falls through to a later candidate when the first is unusable',
        () {
      final accent = accentFromPalette(
        paletteWith(
          vibrant: const Color(0xFF0A0A0A), // black-ish: skipped
          primary: const Color(0xFF7A2E8A), // purple: used
        ),
      );
      expect(accent, isNotNull);
      expect(HSLColor.fromColor(accent!).hue, inInclusiveRange(270, 320));
    });
  });

  group('SystemAccent parsers', () {
    test('Windows AccentColor is ABGR (0xAABBGGRR)', () {
      // 0xffd77800 → A=ff B=d7 G=78 R=00 → Windows blue #0078D7.
      final parsed = SystemAccent.parseWindowsAccent(
        r'HKEY_CURRENT_USER\Software\Microsoft\Windows\DWM'
        '\n    AccentColor    REG_DWORD    0xffd77800\n',
      );
      expect(parsed, isNotNull);
      expect(parsed!.toARGB32(), 0xFF0078D7);
    });

    test('Windows ColorizationColor is ARGB', () {
      final parsed = SystemAccent.parseWindowsColorization(
        '    ColorizationColor    REG_DWORD    0xc42d78d7\n',
      );
      expect(parsed!.toARGB32(), 0xFF2D78D7);
    });

    test('Windows output without a value yields null', () {
      expect(
        SystemAccent.parseWindowsAccent(
          'ERROR: The system was unable to find the specified registry key.',
        ),
        isNull,
      );
    });

    test('pure black/white registry accents are rejected', () {
      expect(SystemAccent.parseWindowsAccent('0xff000000'), isNull);
      expect(SystemAccent.parseWindowsAccent('0xffffffff'), isNull);
    });

    test('macOS accent indices map to the system palette', () {
      expect(SystemAccent.parseMacAccent('4')!.toARGB32(), 0xFF007AFF);
      expect(SystemAccent.parseMacAccent('0')!.toARGB32(), 0xFFFF5257);
      // Out-of-range indices clamp instead of throwing.
      expect(SystemAccent.parseMacAccent('99'), isNotNull);
      expect(SystemAccent.parseMacAccent('not-a-number'), isNull);
    });

    test('GNOME accent names map, junk is null', () {
      expect(SystemAccent.parseGnomeAccent("'teal'\n")!.toARGB32(),
          0xFF2190A4);
      expect(SystemAccent.parseGnomeAccent("'slate'")!.toARGB32(),
          0xFF6F8396);
      expect(SystemAccent.parseGnomeAccent('mustard'), isNull);
    });

    test('KDE accent triples parse, malformed ones are null', () {
      expect(SystemAccent.parseKdeAccent('61,174,233\n')!.toARGB32(),
          0xFF3DAEE9);
      expect(SystemAccent.parseKdeAccent('61 174 233'), isNotNull);
      expect(SystemAccent.parseKdeAccent('61,174'), isNull);
      expect(SystemAccent.parseKdeAccent('300,174,233'), isNull);
      expect(SystemAccent.parseKdeAccent(''), isNull);
    });

    test('KDE colour schemes yield their selection colour', () {
      // BreezeDark: no explicit AccentColor, so the scheme's selection
      // colour is what the desktop actually highlights with.
      const scheme = '[Colors:Window]\n'
          'BackgroundNormal=35,38,41\n'
          '\n'
          '[Colors:Selection]\n'
          'BackgroundAlternate=30,87,116\n'
          'BackgroundNormal=61,174,233\n'
          'DecorationFocus=61,174,233\n';
      expect(SystemAccent.parseKdeScheme(scheme)!.toARGB32(), 0xFF3DAEE9);
      // No selection group at all (and no group header) → nothing.
      expect(SystemAccent.parseKdeScheme('BackgroundNormal=1,2,3'), isNull);
      expect(
        SystemAccent.parseKdeScheme('[Colors:Window]\nBackgroundNormal=1,2,3'),
        isNull,
      );
    });

    test('iniValue reads groups case-insensitively, ignores look-alikes', () {
      const kdedefaults = '[General]\n'
          'ColorScheme=BreezeDark\n'
          'ColorSchemeHash=0efb452114ece4d3338057cb89f434aff85d80d0\n';
      expect(
        SystemAccent.iniValue(kdedefaults, 'General', 'ColorScheme'),
        'BreezeDark',
      );
      expect(
        SystemAccent.iniValue(kdedefaults, 'general', 'colorscheme'),
        'BreezeDark',
      );
      expect(
        SystemAccent.iniValue(kdedefaults, 'General', 'AccentColor'),
        isNull,
      );
      expect(
        SystemAccent.iniValue(kdedefaults, 'Other', 'ColorScheme'),
        isNull,
      );
    });
  });

  group('AccentResolution', () {
    test('default fallback is the neutral brand accent', () {
      expect(AccentResolution.fallback.color, WaveColors.defaultAccent);
      expect(AccentResolution.fallback.resolved, isTrue);
    });
  });

  group('accentResolutionProvider', () {
    /// Container with a real [ThemeController] over mock prefs; the OS and
    /// cover probes are injected so the test is deterministic everywhere.
    Future<ProviderContainer> container(
      Map<String, Object> prefsValues, {
      Object? system = _none,
      Object? artwork = _none,
    }) async {
      SharedPreferences.setMockInitialValues(prefsValues);
      final prefs = Prefs(await SharedPreferences.getInstance());
      final c = ProviderContainer(
        overrides: [
          prefsProvider.overrideWithValue(prefs),
          if (system != _none)
            systemAccentProvider.overrideWith((ref) async => system as Color?),
          if (artwork != _none)
            artworkAccentProvider.overrideWithValue(artwork as Color?),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('custom uses the picked colour', () async {
      final c = await container({
        'lw_accent': 0xFF12AB34,
        'lw_accent_source': 'custom',
      });
      final r = c.read(accentResolutionProvider);
      expect(r.source, AccentSource.custom);
      expect(r.color.toARGB32(), 0xFF12AB34);
      expect(r.resolved, isTrue);
    });

    test('lastwave uses the neutral brand accent, not the pick', () async {
      final c = await container({
        'lw_accent': 0xFF12AB34,
        'lw_accent_source': 'lastwave',
      });
      final r = c.read(accentResolutionProvider);
      expect(r.source, AccentSource.lastwave);
      expect(r.color, WaveColors.defaultAccent);
      expect(r.resolved, isTrue);
    });

    test('system uses the desktop accent when there is one', () async {
      final c = await container(
        {'lw_accent': 0xFF12AB34, 'lw_accent_source': 'system'},
        system: const Color(0xFF3DAEE9),
      );
      await c.read(systemAccentProvider.future);
      final r = c.read(accentResolutionProvider);
      expect(r.source, AccentSource.system);
      expect(r.color.toARGB32(), 0xFF3DAEE9);
      expect(r.resolved, isTrue);
    });

    test('system falls back to custom when the desktop exposes none',
        () async {
      final c = await container(
        {'lw_accent': 0xFF12AB34, 'lw_accent_source': 'system'},
        system: null,
      );
      await c.read(systemAccentProvider.future);
      final r = c.read(accentResolutionProvider);
      expect(r.resolved, isFalse);
      expect(r.color.toARGB32(), 0xFF12AB34);
    });

    test('artwork uses the cover tint, else falls back to custom', () async {
      final tinted = await container(
        {'lw_accent': 0xFF12AB34, 'lw_accent_source': 'artwork'},
        artwork: const Color(0xFF7A4F2E),
      );
      final r = tinted.read(accentResolutionProvider);
      expect(r.source, AccentSource.artwork);
      expect(r.color.toARGB32(), 0xFF7A4F2E);
      expect(r.resolved, isTrue);

      final plain = await container(
        {'lw_accent': 0xFF12AB34, 'lw_accent_source': 'artwork'},
        artwork: null,
      );
      final fallback = plain.read(accentResolutionProvider);
      expect(fallback.resolved, isFalse);
      expect(fallback.color.toARGB32(), 0xFF12AB34);
    });

    test('legacy "manual" source is a custom accent', () async {
      final c = await container({
        'lw_accent': 0xFF12AB34,
        'lw_accent_mode': 'manual',
      });
      final r = c.read(accentResolutionProvider);
      expect(r.source, AccentSource.custom);
      expect(r.color.toARGB32(), 0xFF12AB34);
    });
  });

  group('accent surface helpers', () {
    /// Pumps a themed app and hands the resolved context back.
    Future<BuildContext> themeContext(
      WidgetTester tester, {
      required Color accent,
      required bool dark,
    }) async {
      late BuildContext captured;
      final darkTheme = buildWaveFluentTheme(
        accent: accent,
        isLight: false,
      );
      final lightTheme = buildWaveFluentTheme(
        accent: accent,
        isLight: true,
      );
      await tester.pumpWidget(
        FluentApp(
          theme: lightTheme,
          darkTheme: darkTheme,
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          home: Builder(
            builder: (context) {
              captured = context;
              return const SizedBox();
            },
          ),
        ),
      );
      // FluentApp lerps between themes; read only after the animation.
      await tester.pumpAndSettle();
      return captured;
    }

    testWidgets('on-accent glyphs flip with light vs dark accents',
        (tester) async {
      // The LastWave neutral source: an off-white accent must take a black
      // glyph — hardcoded whites used to vanish into their own disc.
      var context = await themeContext(
        tester,
        accent: WaveColors.defaultAccent,
        dark: true,
      );
      expect(waveAccent(context).toARGB32(), WaveColors.defaultAccent.toARGB32());
      expect(waveOnAccent(context), Colors.black);
      expect(onAccentFor(const Color(0xFFE03030)), Colors.white);

      context = await themeContext(
        tester,
        accent: const Color(0xFFE03030),
        dark: true,
      );
      expect(waveAccent(context).toARGB32(), 0xFFE03030);
      expect(waveOnAccent(context), Colors.white);
    });

    testWidgets('washes flip with the theme, never hardcoded white',
        (tester) async {
      var context = await themeContext(
        tester,
        accent: const Color(0xFFE03030),
        dark: true,
      );
      expect(waveHoverWash(context), Colors.white.withValues(alpha: 0.07));
      expect(wavePressedWash(context), Colors.white.withValues(alpha: 0.12));
      expect(waveWash(context, 0.5), Colors.white.withValues(alpha: 0.5));

      context = await themeContext(
        tester,
        accent: const Color(0xFFE03030),
        dark: false,
      );
      expect(waveHoverWash(context), Colors.black.withValues(alpha: 0.07));
      expect(wavePressedWash(context), Colors.black.withValues(alpha: 0.12));
    });

    testWidgets('focus ring follows the accent (was a fixed grey)',
        (tester) async {
      final context = await themeContext(
        tester,
        accent: const Color(0xFFE03030),
        dark: true,
      );
      final ring = waveFocusRing(context);
      expect(ring.r, closeTo(224 / 255, 0.01));
      expect(ring.a, closeTo(0.85, 0.01));
    });
  });
}
