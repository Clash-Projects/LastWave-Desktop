import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'app/window.dart';
import 'core/storage/app_database.dart';
import 'core/storage/prefs.dart';
import 'features/settings/app.dart';
import 'features/search/shared_providers.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (runWebViewTitleBarWidget(args)) return;
  // Single persistent media_kit/libmpv backend (Limusic parity is
  // configured Dart-side in PlaybackService.ensurePlayer: audio-only
  // vo=null, 32MiB demuxer cache, on-disk cache, gapless-audio).
  // Windows bundles libmpv via media_kit_libs_video — no Rust, no
  // C++ changes required (profiling shows no native bottleneck).
  MediaKit.ensureInitialized();

  // Image-cache database (cached_network_image → sqflite) needs the
  // desktop FFI backend, otherwise every thumbnail silently fails.
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  // Secrets are compiled in (obfuscated) via `dart tool/obfuscate_secrets.dart`.
  final prefs = await Prefs.load();
  final database = await AppDatabase.open();

  await setupWindow();

  runApp(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(database),
      ],
      child: const LastWaveApp(),
    ),
  );
}
