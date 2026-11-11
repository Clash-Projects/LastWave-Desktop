import 'dart:async';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/deep_link.dart';
import '../../app/router.dart';
import '../../app/window.dart';
import '../../app/window_lifecycle.dart';
import '../../core/artwork/official_artwork_service.dart';
import '../../core/storage/prefs.dart';
import '../../design_system/fluent/lw_scrollbar.dart';
import '../../ui/theme/fluent_theme.dart';
import '../../ui/theme/tokens.dart';
import '../../ui/theme/haze.dart';
import '../player/playback_service.dart';
import '../audio_output/output_controller.dart';
import '../jam/jam_sync.dart';
import '../innertube/innertube_api.dart';
import '../library/yt_library_sync.dart';
import '../mpris/mpris_service.dart';
import '../smtc/smtc_service.dart';
import '../presence/discord_presence_service.dart';
import 'accent.dart';
import 'theme_controller.dart';

/// LastWave desktop application root.
///
/// Single primary system: FluentApp router + Wave Fluent theme.
/// Native window material via flutter_acrylic/window_manager.
///
/// Last.fm authentication is optional. The music shell is available on
/// first launch, and Last.fm can be connected later from Settings.
class LastWaveApp extends ConsumerStatefulWidget {
  const LastWaveApp({super.key});
  @override
  ConsumerState<LastWaveApp> createState() => _LastWaveAppState();
}

class _LastWaveAppState extends ConsumerState<LastWaveApp> {
  StreamSubscription<String>? _linkSub;
  AppLifecycleListener? _lifecycle;

  void _openLink(String link) {
    final route = routeForLink(link);
    if (route != null) _router.go(route);
  }

  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    // The first route is Home; Last.fm is an optional integration.
    _router = buildRouter();
    // lastwave:// links: the launch link once the first frame is up, and
    // links forwarded by a second launch while running.
    _linkSub = DeepLinks.stream.listen(_openLink);
    unawaited(
      DeepLinks.takeInitialAsync().then((launchLink) {
        if (launchLink == null || !mounted) return;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _openLink(launchLink);
        });
      }).catchError((_) {}),
    );
    // Warm start (non-blocking, best-effort): create the single
    // persistent media_kit/libmpv player. BotGuard pre-warms once on a
    // delay (single hidden window, reused for app lifetime): this moves
    // the one-time WebView init off the first ciphered playback, so a
    // WEB_REMIX fallback never stalls transport on a cold window spawn.
    // Direct-only mode (lw_disable_potoken) skips it — zero WebViews.
    Future.microtask(() {
      // Artist tiles whose Deezer lookup fails (rate limit, no press
      // photo) fall back to the YouTube Music portrait, same as the
      // artist detail page.
      OfficialArtworkService.instance.artistPhotoFallback = (name) async {
        final artists =
            await ref.read(innerTubeProvider).searchArtists(name, limit: 3);
        return artists.isEmpty ? '' : artists.first.artworkUrl;
      };
      OfficialArtworkService.instance.trackCoverFallback =
          (title, artist) async {
        final hit = await ref
            .read(innerTubeProvider)
            .findBestMatchOrNull(title, artist);
        return hit?.artworkUrl ?? '';
      };
      OfficialArtworkService.instance.albumCoverFallback =
          (album, artist) async {
        final tube = ref.read(innerTubeProvider);
        String norm(String s) =>
            OfficialArtworkService.normalizeForSearch(s);
        // Last.fm bills "Aarzu (with Asim Azhar)", "X (From "Film")",
        // "Y (feat. Z)"; the catalog files plain "Aarzu" / "X" / "Y".
        final plain = album.replaceFirst(RegExp(r'\s*[\(\[].*$'), '').trim();
        final titles = {album, if (plain.isNotEmpty) plain};
        for (final t in titles) {
          final want = norm(t);
          if (want.isEmpty) continue;
          final albums = await tube.searchAlbums('$t $artist', limit: 5);
          for (final a in albums) {
            final got = norm(a.name);
            if (a.artworkUrl.isNotEmpty &&
                got.isNotEmpty &&
                (got == want || got.contains(want) || want.contains(got))) {
              return a.artworkUrl;
            }
          }
        }
        // A single is billed as an album on Last.fm but filed as a song.
        for (final t in titles) {
          final song = await tube.findBestMatchOrNull(t, artist);
          if (song != null && song.artworkUrl.isNotEmpty) {
            return song.artworkUrl;
          }
        }
        return '';
      };
      try {
        ref.read(playbackServiceProvider.notifier).ensurePlayer();
      } catch (_) {}
      try {
        // Two-way YouTube Music sync; idle until an account is connected.
        final sync = ref.read(ytLibrarySyncProvider)..start();
        _lifecycle = AppLifecycleListener(onResume: sync.kick);
      } catch (_) {}
      try {
        ref.read(audioOutputProvider.notifier).attach();
      } catch (_) {}
      if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
        try {
          // Desktop Discord Rich Presence; never blocks audio startup.
          ref.read(discordPresenceProvider).startup();
        } catch (_) {}
        try {
          ref.read(mprisProvider).startup();
        } catch (_) {}
        try {
          ref.read(smtcProvider).startup();
        } catch (_) {}
      }
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
    _linkSub?.cancel();
    _lifecycle?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      ref.listen(
          themeControllerProvider.select(
              (t) => (t.effectiveLight, t.amoled, t.customSurfaces?.background)),
          (_, mode) => applyWindowMaterial(
                isLight: mode.$1,
                amoled: mode.$2,
                background: mode.$3,
              ));
    }
    // Bridges Jam room events to the player; idle until a room is joined.
    ref.watch(jamSyncProvider);
    final theme = ref.watch(themeControllerProvider);
    // Accent source (custom / LastWave neutral / system / artwork) is
    // resolved in one place; anything that can't answer falls back to the
    // custom pick there.
    final accent = ref.watch(accentResolutionProvider).color;

    // Custom theme: one generated palette, published as the dark or the
    // light theme depending on how bright its base is.
    final activeSurfaces = WaveSurfaces.graphite;
    final darkTheme = buildWaveFluentTheme(
      accent: accent,
      isLight: false,
      amoled: false,
    );
    final lightTheme = buildWaveFluentTheme(
      accent: accent,
      isLight: true,
      custom: null,
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
              theme.effectiveLight ? ThemeMode.light : ThemeMode.dark,
          routerConfig: _router,
          // ONE Fluent scrollbar treatment everywhere: thin, fades when
          // idle, no browser-style horizontal bars under carousels.
          scrollBehavior: const WaveScrollBehavior(),
          // No acrylic anywhere: fluent MenuFlyout/ComboBox render a
          // fullscreen BackdropFilter blur unless DisableAcrylic is
          // present — that blur sample on the open frame is the hitch
          // on every toolbar popup. The app is opaque dark anyway, so
          // solid flyouts read identically. (Own haze system untouched.)
          builder: (context, child) => WaveSurfacesScope(
            surfaces: activeSurfaces,
            child: DisableAcrylic(child: child ?? const SizedBox.shrink()),
          ),
        ),
      ),
    );
  }
}
