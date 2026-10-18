import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';

/// Best-effort read of the desktop environment's accent colour.
///
/// Settings → Appearance offers an "Accent source: system" mode, and there
/// is no portable API for it: Windows keeps it in the registry, macOS in a
/// `defaults` key, GNOME in a gsettings enum and KDE in its config files
/// (`kdeglobals` + the active `color-schemes/*.colors`). Each
/// platform is probed with the cheapest mechanism available, with a short
/// timeout, and *anything* unexpected degrades to `null` — the caller then
/// falls back to the custom accent. A probe can never hang startup, throw
/// into the theme, or log command output.
///
/// The parsers are static and pure so they can be tested without the OS.
class SystemAccent {
  SystemAccent._();

  /// Cap on a single probe. The theme renders with the fallback accent
  /// until (and unless) a value arrives.
  static const Duration timeout = Duration(seconds: 2);

  static bool _probed = false;
  static Color? _cached;

  /// Probe result, cached for the process. `null` means "this desktop
  /// exposes nothing usable" and is cached too (no repeated shell-outs).
  static Future<Color?> read({bool refresh = false}) async {
    if (_probed && !refresh) return _cached;
    _probed = true;
    try {
      _cached = await _probe();
    } catch (_) {
      _cached = null;
    }
    return _cached;
  }

  static Future<Color?> _probe() async {
    if (Platform.isWindows) return windows();
    if (Platform.isMacOS) return macos();
    if (Platform.isLinux) return linux();
    return null;
  }

  // ── Windows ──────────────────────────────────────────────────────────
  //
  // `HKCU\Software\Microsoft\Windows\DWM` keeps the accent as an ABGR
  // DWORD (`AccentColor`); `ColorizationColor` is its ARGB sibling and the
  // fallback for builds that don't write the former.
  static Future<Color?> windows() async {
    final accent = await _run('reg', [
      'query',
      r'HKCU\Software\Microsoft\Windows\DWM',
      '/v',
      'AccentColor',
    ]);
    final parsed = parseWindowsAccent(accent ?? '');
    if (parsed != null) return parsed;
    final colorization = await _run('reg', [
      'query',
      r'HKCU\Software\Microsoft\Windows\DWM',
      '/v',
      'ColorizationColor',
    ]);
    return parseWindowsColorization(colorization ?? '');
  }

  /// `AccentColor` — ABGR (`0xAABBGGRR`), e.g. `0xffd77800` is orange.
  static Color? parseWindowsAccent(String output) {
    final hex = _firstDword(output);
    if (hex == null) return null;
    final a = (hex >> 24) & 0xFF;
    final b = (hex >> 16) & 0xFF;
    final g = (hex >> 8) & 0xFF;
    final r = hex & 0xFF;
    return _sanitize(Color.fromARGB(a == 0 ? 0xFF : a, r, g, b));
  }

  /// `ColorizationColor` — ARGB (`0xAARRGGBB`).
  static Color? parseWindowsColorization(String output) {
    final hex = _firstDword(output);
    if (hex == null) return null;
    return _sanitize(Color(hex | 0xFF000000));
  }

  static int? _firstDword(String output) {
    final match = RegExp(r'0x([0-9a-fA-F]{8})').firstMatch(output);
    if (match == null) return null;
    return int.tryParse(match.group(1)!, radix: 16);
  }

  // ── macOS ────────────────────────────────────────────────────────────
  //
  // `AppleAccentColor` is an index into the system accent palette; the key
  // is absent on a default install, whose accent is blue.
  static const Map<String, Color> _macAccents = {
    '-1': Color(0xFF8E8E93), // graphite / multicolour
    '0': Color(0xFFFF5257), // red
    '1': Color(0xFFFF9F0A), // orange
    '2': Color(0xFFFFD60A), // yellow
    '3': Color(0xFF30D158), // green
    '4': Color(0xFF007AFF), // blue
    '5': Color(0xFFA550A7), // purple
    '6': Color(0xFFF74F9E), // pink
  };

  static Future<Color?> macos() async {
    final raw = await _run('defaults', ['read', '-g', 'AppleAccentColor']);
    return parseMacAccent(raw ?? '') ?? _macAccents['4']; // default: blue
  }

  static Color? parseMacAccent(String output) {
    final value = int.tryParse(output.trim());
    if (value == null) return null;
    final clamped = value.clamp(-1, 6);
    return _macAccents['$clamped'];
  }

  // ── Linux ────────────────────────────────────────────────────────────
  //
  // GNOME 47+ has a real accent setting (`accent-color`, an enum name).
  // KDE keeps either an explicit `[General] AccentColor` (Plasma 5.24+)
  // or nothing at all — in which case the accent users actually see is the
  // active colour scheme's selection colour.
  //
  // Order matters: a KDE box usually still has GNOME's schemas installed,
  // where `gsettings` answers with GNOME's *default* ('blue') rather than
  // anything on screen. So the desktop actually running is asked first.
  static const Map<String, Color> _gnomeAccents = {
    'blue': Color(0xFF3584E4),
    'teal': Color(0xFF2190A4),
    'green': Color(0xFF3A944A),
    'yellow': Color(0xFFC88800),
    'orange': Color(0xFFED5B00),
    'red': Color(0xFFE62D42),
    'pink': Color(0xFFD56199),
    'purple': Color(0xFF9141AC),
    'slate': Color(0xFF6F8396),
  };

  static Future<Color?> linux() async {
    final desktop =
        (Platform.environment['XDG_CURRENT_DESKTOP'] ?? '').toLowerCase();
    final kdeFirst = desktop.contains('kde') || desktop.contains('plasma');
    final probes = kdeFirst
        ? <Future<Color?> Function()>[kdeAccent, gnomeAccent]
        : <Future<Color?> Function()>[gnomeAccent, kdeAccent];
    for (final probe in probes) {
      final color = await probe();
      if (color != null) return color;
    }
    return null;
  }

  static Future<Color?> gnomeAccent() async {
    final out = await _run('gsettings', [
      'get',
      'org.gnome.desktop.interface',
      'accent-color',
    ]);
    return out == null ? null : parseGnomeAccent(out);
  }

  /// KDE accent, read from the config *files* (no `kreadconfig`
  /// dependency): the explicit accent when set, otherwise the active
  /// colour scheme's selection colour.
  static Future<Color?> kdeAccent() async {
    final home = Platform.environment['HOME'] ?? '';
    final configs = <String>[
      if (home.isNotEmpty) '$home/.config/kdeglobals',
      if (home.isNotEmpty) '$home/.config/kdedefaults/kdeglobals',
    ];
    final contents = <String>[];
    for (final path in configs) {
      final text = await _read(path);
      if (text != null) contents.add(text);
    }
    for (final text in contents) {
      final accent = iniValue(text, 'General', 'AccentColor');
      if (accent == null) continue;
      final parsed = parseKdeAccent(accent);
      if (parsed != null) return parsed;
    }
    // No explicit accent: the scheme's selection colour is the paint.
    var scheme = 'Breeze';
    for (final text in contents) {
      final name = iniValue(text, 'General', 'ColorScheme');
      if (name != null && name.isNotEmpty) {
        scheme = name;
        break;
      }
    }
    final dataHome = Platform.environment['XDG_DATA_HOME'] ??
        (home.isEmpty ? '' : '$home/.local/share');
    final dataDirs =
        (Platform.environment['XDG_DATA_DIRS'] ?? '/usr/local/share:/usr/share')
            .split(':');
    final dirs = <String>[
      if (dataHome.isNotEmpty) '$dataHome/color-schemes',
      for (final dir in dataDirs)
        if (dir.isNotEmpty) '$dir/color-schemes',
    ];
    for (final dir in dirs) {
      final text = await _read('$dir/$scheme.colors');
      if (text == null) continue;
      final parsed = parseKdeScheme(text);
      if (parsed != null) return parsed;
    }
    return null;
  }

  static Color? parseGnomeAccent(String output) {
    final name = output.trim().replaceAll("'", '').toLowerCase();
    return _gnomeAccents[name];
  }

  static Color? parseKdeAccent(String output) {
    final parts = output
        .split(RegExp(r'[,\s]+'))
        .where((p) => p.isNotEmpty)
        .map((p) => int.tryParse(p))
        .toList();
    if (parts.length < 3) return null;
    if (parts.any((p) => p == null || p < 0 || p > 255)) return null;
    return _sanitize(
      Color.fromARGB(0xFF, parts[0]!, parts[1]!, parts[2]!),
    );
  }

  /// `[Colors:Selection] BackgroundNormal=R,G,B` out of a KDE `.colors`
  /// scheme file (`BreezeDark.colors` → Breeze blue).
  static Color? parseKdeScheme(String contents) {
    final value = iniValue(contents, 'Colors:Selection', 'BackgroundNormal');
    return value == null ? null : parseKdeAccent(value);
  }

  /// Minimal INI lookup (`[Group]` / `Key=Value`, case-insensitive).
  static String? iniValue(String contents, String group, String key) {
    var current = '';
    for (final raw in contents.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith(';')) {
        continue;
      }
      if (line.startsWith('[') && line.endsWith(']')) {
        current = line.substring(1, line.length - 1).trim().toLowerCase();
        continue;
      }
      if (current != group.toLowerCase()) continue;
      final eq = line.indexOf('=');
      if (eq <= 0) continue;
      if (line.substring(0, eq).trim().toLowerCase() != key.toLowerCase()) {
        continue;
      }
      return line.substring(eq + 1).trim();
    }
    return null;
  }

  /// File read that treats "missing/unreadable" as no data.
  static Future<String?> _read(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  // ── Shared ───────────────────────────────────────────────────────────

  /// Accents that are pure black or pure white are unusable as an accent
  /// (they read as "no accent"); the caller falls back instead.
  static Color? _sanitize(Color color) {
    final hsl = HSLColor.fromColor(color);
    if (hsl.lightness <= 0.08 || hsl.lightness >= 0.97) return null;
    return color.withValues(alpha: 1);
  }

  /// Runs a probe binary, swallowing "not installed" and timeouts.
  static Future<String?> _run(String exe, List<String> args) async {
    try {
      final result =
          await Process.run(exe, args).timeout(timeout);
      if (result.exitCode != 0) return null;
      final out = result.stdout;
      return out is String ? out : null;
    } catch (_) {
      return null;
    }
  }
}
