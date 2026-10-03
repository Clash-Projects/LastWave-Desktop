import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../app/window.dart';
import '../../app/window_lifecycle.dart';
import '../../app/auth_gate.dart';
import '../../core/storage/prefs.dart';
import '../../design_system/fluent/lw_scrollbar.dart';
import '../../features/lastfm/auth_repository.dart';
import '../../ui/theme/fluent_theme.dart';
import '../../ui/theme/haze.dart';
import '../player/playback_service.dart';
import '../audio_output/output_controller.dart';
import '../innertube/innertube_api.dart';
import '../mpris/mpris_service.dart';
import '../smtc/smtc_service.dart';
import '../presence/discord_presence_service.dart';
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
      initialInside: ref.read(prefsProvider).isAuthenticated ||
          ref.read(prefsProvider).isGuest,
    );
    _router = buildRouter(gate: _gate);
    // Warm start (non-blocking, best-effort): create the single
    // persistent media_kit/libmpv player. BotGuard pre-warms once on a
    // delay (single hidden window, reused for app lifetime): this moves
    // the one-time WebView init off the first ciphered playback, so a
    // WEB_REMIX fallback never stalls transport on a cold window spawn.
    // Direct-only mode (lw_disable_potoken) skips it — zero WebViews.
    Future.microtask(() {
      try {
        ref.read(playbackServiceProvider.notifier).ensurePlayer();
      } catch (_) {}
      try {
        ref.read(audioOutputProvider.notifier).attach();
      } catch (_) {}
      try {
        // Discord Rich Presence: own block so an audio failure above can
        // never skip it; never throws (Discord closed degrades to silence).
        ref.read(discordPresenceProvider).startup();
      } catch (_) {}
      try {
        // MPRIS (Linux): exposes now-playing + transport on the session
        // bus for bars, playerctl and media keys. No-op elsewhere.
        ref.read(mprisProvider).startup();
      } catch (_) {}
      try {
        // SMTC (Windows): volume flyout, lock screen, Bluetooth and
        // hardware media keys. No-op elsewhere.
        ref.read(smtcProvider).startup();
      } catch (_) {}
      Future<void>.delayed(const Duration(seconds: 20), () {
        try {
          if (ref.read(prefsProvider).disablePoToken) return;
          ref.read(innerTubeProvider).preWarmBotGuard();
        } catch (_) {}
      });
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
    // Live auth state drives the gate (login, logout, guest entry,
    // session expiry). Guests count as inside.
    ref.listen(
        authRepositoryProvider.select((a) =>
            a.status == AuthStatus.signedIn ||
            a.status == AuthStatus.guest),
        (_, inside) => _gate.update(inside));
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
      child: WindowLifecycle(
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
          // No acrylic anywhere: fluent MenuFlyout/ComboBox render a
          // fullscreen BackdropFilter blur unless DisableAcrylic is
          // present — that blur sample on the open frame is the hitch
          // on every toolbar popup. The app is opaque dark anyway, so
          // solid flyouts read identically. (Own haze system untouched.)
          builder: (context, child) =>
              DisableAcrylic(child: child ?? const SizedBox.shrink()),
        ),
      ),
    );
  }
}
