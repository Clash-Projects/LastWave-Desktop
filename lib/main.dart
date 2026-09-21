import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'app/window.dart';
import 'core/artwork/artwork_resolver.dart';
import 'core/artwork/official_artwork_service.dart';
import 'core/storage/app_database.dart';
import 'core/storage/prefs.dart';
import 'features/settings/app.dart';
import 'features/search/shared_providers.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // Keep decoded-image memory bounded on long sessions: Home/Discover
  // grids of 1400px covers fill the default 100MiB/1000-image cache
  // and decode bursts spike RSS to 500MiB. 50MiB/200 images is plenty
  // for visible tiles; offscreen tiles re-decode from disk cache.
  PaintingBinding.instance.imageCache.maximumSize = 200;
  PaintingBinding.instance.imageCache.maximumSizeBytes =
      50 << 20; // 50 MiB
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
  OfficialArtworkService.instance.init(db: database);

  await setupWindow();

  // Cap the on-disk image cache that backs CachedNetworkImage (default
  // keeps 200+ files / 30 days → 759 CacheObjects in the heap dump).
  // Bounded disk cache also keeps decoded-image re-creation cheap.
  ArtworkResolver.trimDiskCacheIfNeeded();

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
