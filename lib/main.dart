import 'dart:io';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'app/accessibility.dart';
import 'app/deep_link.dart';
import 'app/window.dart';
import 'core/artwork/artwork_resolver.dart';
import 'core/artwork/official_artwork_service.dart';
import 'core/diagnostics/diagnostics_log.dart';
import 'core/error/fatal_crumbs.dart';
import 'core/platform/allocator_tuning.dart';
import 'core/storage/app_database.dart';
import 'core/storage/prefs.dart';
import 'features/settings/app.dart';
import 'features/search/shared_providers.dart';

Future<void> main(List<String> args) async {
  // Freeze glibc's dynamic mmap/trim thresholds before anything large is
  // allocated: without this, libmpv's per-track multi-MB buffers end up
  // on a heap that never gives the pages back (+80 MB of RSS per track
  // change, measured). See lib/core/platform/allocator_tuning.dart.
  applyAllocatorTuning();
  WidgetsFlutterBinding.ensureInitialized();
  // Desktop is always mouse + keyboard. In the default "automatic" mode a
  // single touch/pen pointer event (touchscreen, Windows Ink, a touch
  // keyboard tap) flips Flutter's highlight mode to `touch`, which silences
  // every hover highlight (FocusableActionDetector only reports hover in
  // traditional mode), and only a key press flips it back — hence menu rows
  // that stayed dead until Tab or an Alt+Tab round trip.
  FocusManager.instance.highlightStrategy =
      FocusHighlightStrategy.alwaysTraditional;
  // Screen readers (NVDA, Narrator, VoiceOver): keep the semantics tree
  // built for the whole session and restore keyboard focus whenever the
  // window comes back. See lib/app/accessibility.dart (issue #75).
  AppAccessibility.enable();
  DeepLinks.start(args);
  // Fatal breadcrumbs: log-and-continue-handling (return false) so the
  // next fail-fast names its line in mpv-ops.log. Sync writes only.
  FlutterError.onError = (details) {
    writeFatalCrumb(fatalCrumb(details.exception, details.stack));
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    writeFatalCrumb(fatalCrumb(error, stack));
    return false;
  };
  // Desktop image cache budget: 64 MiB / 500 images.
  //
  // The previous 128 MiB was chosen when oversized tiles decoded at
  // native size; after DPR-aware decode sizing (each tile decodes at
  // `size × dpr` snapped to a 16px grid — see WaveArtwork) a long session
  // was observed filling that ceiling at roughly 5 MiB per track, i.e. up
  // to 128 MiB of pure decoded-artwork residency that only ever ratchets.
  // 64 MiB still holds ~150 tiles at a 320px decode or ~39 at 640px, so it
  // comfortably covers a visible grid; the cost of going below that is
  // re-decodes while scrolling large collections.
  PaintingBinding.instance.imageCache.maximumSize = 500;
  PaintingBinding.instance.imageCache.maximumSizeBytes =
      64 << 20; // 64 MiB
  if (runWebViewTitleBarWidget(args)) return;
  // libmpv is deliberately NOT dlopened here. MediaKit.ensureInitialized()
  // just dlopens a multi-MB .so (media_kit's NativeLibrary) — pure
  // first-frame latency — and nothing on the first frame needs it: the
  // warm-start player is created on a post-first-frame microtask, and
  // motion art only after a track plays. The call now lives at the top of
  // PlaybackService.ensurePlayer (and defensively in the motion-art
  // session), so the dlopen happens after the shell has painted. It is
  // idempotent, so ordering is preserved for both Player() call sites.

  // Image-cache database (cached_network_image → sqflite) needs the
  // desktop FFI backend, otherwise every thumbnail silently fails.
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  // Session log (Settings → General → Export diagnostic logs): one file
  // per run under the app-support root, beside the library database.
  // Started before anything else logs so boot crumbs land in it; the
  // verbose level follows prefs and is applied once they are read below.
  try {
    final support = await getApplicationSupportDirectory();
    DiagnosticsLog.init(
      Directory('${support.path}${Platform.pathSeparator}logs'),
    );
  } catch (_) {
    // Diagnostics must never block startup.
  }

  // Secrets are compiled in (obfuscated) via `dart tool/obfuscate_secrets.dart`.
  //
  // These three are independent — prefs (a JSON read), the SQLite cache
  // open (PRAGMA + additive migrations) and the native window bring-up
  // (Mica/title bar/tray/hotkeys). Serializing them made cold start pay
  // the SUM; starting all three up front makes it pay the MAX. Nothing
  // in `setupWindow` reads prefs or the database, so the window can be
  // brought up while they load.
  final prefsFuture = Prefs.load();
  final databaseFuture = AppDatabase.open();
  final windowFuture = setupWindow();
  final prefs = await prefsFuture;
  // Verbose logging is a saved preference: without this the toggle would
  // only take effect on the next launch.
  DiagnosticsLog.verbose = prefs.verboseLogs;
  final database = await databaseFuture;
  OfficialArtworkService.instance.init(db: database);
  await windowFuture;

  // Disk-side artwork cache bound. NOTE: this is currently a documented
  // no-op — the 759 heap "CacheObjects" were tiny metadata (~60 KB total),
  // so the RSS win already comes from the imageCache ceiling above, and
  // disk eviction stays with flutter_cache_manager's own 200-object /
  // 30-day LRU (an aggressive `emptyCache()` here would thrash). Kept as
  // the single call site if a real policy is ever added.
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
