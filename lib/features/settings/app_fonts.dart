import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/network/dio_factory.dart';
import 'theme_controller.dart';

/// One choice in Settings → Appearance → Font. [id] is what Prefs stores:
/// '' for the Windows default, a system family name, or a Fontsource id.
class AppFont {
  final String id;
  final String label;
  final bool web;
  const AppFont(this.id, this.label, {this.web = true});
}

const appFonts = <AppFont>[
  AppFont('', 'System default (Segoe UI Variable)', web: false),
  AppFont('Segoe UI', 'Segoe UI', web: false),
  AppFont('Bahnschrift', 'Bahnschrift', web: false),
  AppFont('inter', 'Inter'),
  AppFont('geist', 'Geist'),
  AppFont('manrope', 'Manrope'),
  AppFont('plus-jakarta-sans', 'Plus Jakarta Sans'),
  AppFont('dm-sans', 'DM Sans'),
  AppFont('figtree', 'Figtree'),
  AppFont('outfit', 'Outfit'),
  AppFont('onest', 'Onest'),
  AppFont('poppins', 'Poppins'),
  AppFont('sora', 'Sora'),
  AppFont('urbanist', 'Urbanist'),
  AppFont('lexend', 'Lexend'),
  AppFont('be-vietnam-pro', 'Be Vietnam Pro'),
  AppFont('space-grotesk', 'Space Grotesk'),
  AppFont('red-hat-display', 'Red Hat Display'),
  AppFont('rubik', 'Rubik'),
  AppFont('work-sans', 'Work Sans'),
  AppFont('ibm-plex-sans', 'IBM Plex Sans'),
  AppFont('montserrat', 'Montserrat'),
  AppFont('nunito', 'Nunito'),
  AppFont('quicksand', 'Quicksand'),
  AppFont('raleway', 'Raleway'),
  AppFont('josefin-sans', 'Josefin Sans'),
  AppFont('open-sans', 'Open Sans'),
  AppFont('roboto', 'Roboto'),
  AppFont('lato', 'Lato'),
];

const _weights = [400, 500, 600, 700];
final _loaded = <String>{};
final _dio = DioFactory.create();

/// Downloads (once, cached in app support) and registers a web font as one
/// family with real 400–700 faces, so bold text is not synthesised. Weights
/// a family lacks (Lato has no 500/600) are skipped; the engine picks the
/// nearest face. Null when nothing could be loaded (offline, first use).
Future<String?> _loadWebFont(String id) async {
  final family = 'LW $id';
  if (_loaded.contains(family)) return family;
  final dir = Directory(
      '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}fonts');
  await dir.create(recursive: true);
  final loader = FontLoader(family);
  var faces = 0;
  for (final w in _weights) {
    final file = File('${dir.path}${Platform.pathSeparator}$id-$w.ttf');
    if (!await file.exists()) {
      try {
        final res = await _dio.get<List<int>>(
          'https://cdn.jsdelivr.net/fontsource/fonts/$id@latest/latin-$w-normal.ttf',
          options: Options(
            responseType: ResponseType.bytes,
            validateStatus: (s) => s == 200,
          ),
        );
        // Written aside and renamed, so a cut download never caches.
        final part = File('${file.path}.part');
        await part.writeAsBytes(res.data!, flush: true);
        await part.rename(file.path);
      } catch (_) {
        continue;
      }
    }
    loader.addFont(file.readAsBytes().then(ByteData.sublistView));
    faces++;
  }
  if (faces == 0) return null;
  await loader.load();
  _loaded.add(family);
  return family;
}

/// The family to render the app in; null = the Windows default. Keeps the
/// previous font on screen while a new one downloads.
final appFontFamilyProvider = FutureProvider<String?>((ref) async {
  final id = ref.watch(themeControllerProvider.select((t) => t.font));
  final font = appFonts.where((f) => f.id == id).firstOrNull;
  if (font == null || font.id.isEmpty) return null;
  if (!font.web) return font.id;
  try {
    return await _loadWebFont(font.id);
  } catch (_) {
    return null;
  }
});
