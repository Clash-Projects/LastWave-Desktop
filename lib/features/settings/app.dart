import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../app/window.dart';
import '../../app/auth_gate.dart';
import '../../core/storage/prefs.dart';
import '../../design_system/fluent/lw_scrollbar.dart';
import '../../features/lastfm/auth_repository.dart';
import '../../ui/theme/fluent_theme.dart';
import '../../ui/theme/haze.dart';
import '../player/playback_service.dart';
import 'theme_controller.dart';

/// LastWave desktop application root.
///
/// Single primary system: FluentApp router + Wave Fluent theme.
/// Native window material via flutter_acrylic/window_manager.
///
/// Last.fm authentication is compulsory: [AuthGate] is seeded from the
/// synchronously-loaded prefs session and follows the live auth state,
/// driving the router redirect — unauthenticated users only ever see
/// the welcome screen, never the shell.
class LastWaveApp extends ConsumerStatefulWidget {
  const LastWaveApp({super.key});
  @override
  ConsumerState<LastWaveApp> createState() => _LastWaveAppState();
}

class _LastWaveAppState extends ConsumerState<LastWaveApp> {
  late final GoRouter _router;
  late final AuthGate _gate;

  @override
  void initState() {
    super.initState();
    // Prefs are fully loaded before runApp, and AuthRepository restores
    // the same state synchronously — the first frame routes correctly.
    _gate = AuthGate(
      initialSignedIn: ref.read(prefsProvider).isAuthenticated,
    );
    _router = buildRouter(gate: _gate);
    // Warm start (non-blocking, best-effort): create the single
    // persistent media_kit/libmpv player. BotGuard is intentionally
    // NOT pre-warmed here — it is lazy (only a WEB_REMIX fallback
    // mints poTokens, and desktop_webview_window always spawns a real
    // OS window, so warming it at startup is what produced the extra
    // "LastWave BotGuard" taskbar tab).
    Future.microtask(() {
      try {
        ref.read(playbackServiceProvider.notifier).ensurePlayer();
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _gate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(
        themeControllerProvider.select((t) => t.isLight),
        (_, light) => applyWindowMaterial(isLight: light));
    // Live auth state drives the gate (login, logout, session expiry).
    ref.listen(
        authRepositoryProvider
            .select((a) => a.status == AuthStatus.signedIn),
        (_, signedIn) => _gate.update(signedIn));
    final theme = ref.watch(themeControllerProvider);

    final darkTheme = buildWaveFluentTheme(
      accent: theme.accent,
      isLight: false,
    );
    final lightTheme = buildWaveFluentTheme(
      accent: theme.accent,
      isLight: true,
    );

    return WaveHazeScope(
      material: switch (theme.hazeMaterial) {
        'haze' => WaveMaterialMode.haze,
        'solid' => WaveMaterialMode.solid,
        _ => WaveMaterialMode.automatic,
      },
      intensity: switch (theme.hazeIntensity) {
        'low' => WaveHazeIntensity.low,
        'high' => WaveHazeIntensity.high,
        _ => WaveHazeIntensity.medium,
      },
      child: FluentApp.router(
        title: 'LastWave',
        debugShowCheckedModeBanner: false,
        theme: lightTheme,
        darkTheme: darkTheme,
        themeMode:
            theme.isLight ? ThemeMode.light : ThemeMode.dark,
        routerConfig: _router,
        // ONE Fluent scrollbar treatment everywhere: thin, fades when
        // idle, no browser-style horizontal bars under carousels.
        scrollBehavior: const WaveScrollBehavior(),
      ),
    );
  }
}
