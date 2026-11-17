import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import '../core/artwork/animated_artwork_session.dart';
import '../core/storage/prefs.dart';
import '../features/lastfm/auth_repository.dart';
import '../features/player/playback_service.dart';
import '../ui/now_playing/immersive.dart';

/// Auth gate seam watched by [MiniPlayerController] (overridable in tests
/// without spinning up Last.fm/secure-storage dependencies).
final miniShellActiveProvider = Provider<bool>((ref) {
  final status = ref.watch(authRepositoryProvider.select((a) => a.status));
  return status == AuthStatus.signedIn || status == AuthStatus.guest;
});

/// Playback state seam watched by [MiniPlayerController] (overridable in tests
/// without instantiating `PlaybackService` / `libmpv`).
final miniPlaybackStateProvider = Provider<({bool hasTrack, bool isPlaying})>(
  (ref) => ref.watch(
    playbackServiceProvider.select(
      (s) => (hasTrack: s.current != null, isPlaying: s.isPlaying),
    ),
  ),
);

/// Native runner channel for intercepting OS minimize before animation
/// (Windows `WM_SYSCOMMAND`/`SC_MINIMIZE`, macOS `performMiniaturize`).
const windowControlChannel = MethodChannel('lastwave/window_control');

/// Minimal abstraction over `window_manager`, `screen_retriever`, and
/// `lastwave/window_control` so [MiniPlayerController] can be thoroughly unit tested.
abstract class MiniWindowAdapter {
  Future<bool> isMaximized();
  Future<bool> isMinimized();
  Future<bool> isFullScreen();
  Future<void> setFullScreen(bool value);
  Future<void> unmaximize();
  Future<void> maximize();
  Future<void> minimize();
  Future<void> restore();
  Future<void> show();
  Future<void> hide();
  Future<void> focus();
  Future<Size> getSize();
  Future<void> setSize(Size size);
  Future<Offset> getPosition();
  Future<void> setPosition(Offset position);
  Future<void> setMinimumSize(Size size);
  Future<void> setAlwaysOnTop(bool value);
  Future<void> setSkipTaskbar(bool value);
  Future<List<Rect>> getDisplayWorkAreas();
  Future<void> setNativeInterceptMinimize(bool enabled);
}

class _DesktopMiniWindowAdapter implements MiniWindowAdapter {
  const _DesktopMiniWindowAdapter();

  @override
  Future<bool> isMaximized() => windowManager.isMaximized();

  @override
  Future<bool> isMinimized() => windowManager.isMinimized();

  @override
  Future<bool> isFullScreen() => windowManager.isFullScreen();

  @override
  Future<void> setFullScreen(bool value) => windowManager.setFullScreen(value);

  @override
  Future<void> unmaximize() => windowManager.unmaximize();

  @override
  Future<void> maximize() => windowManager.maximize();

  @override
  Future<void> minimize() => windowManager.minimize();

  @override
  Future<void> restore() => windowManager.restore();

  @override
  Future<void> show() => windowManager.show();

  @override
  Future<void> hide() => windowManager.hide();

  @override
  Future<void> focus() => windowManager.focus();

  @override
  Future<Size> getSize() => windowManager.getSize();

  @override
  Future<void> setSize(Size size) => windowManager.setSize(size);

  @override
  Future<Offset> getPosition() => windowManager.getPosition();

  @override
  Future<void> setPosition(Offset position) =>
      windowManager.setPosition(position);

  @override
  Future<void> setMinimumSize(Size size) => windowManager.setMinimumSize(size);

  @override
  Future<void> setAlwaysOnTop(bool value) =>
      windowManager.setAlwaysOnTop(value);

  @override
  Future<void> setSkipTaskbar(bool value) =>
      windowManager.setSkipTaskbar(value);

  @override
  Future<List<Rect>> getDisplayWorkAreas() async {
    final displays = await screenRetriever.getAllDisplays();
    return [
      for (final d in displays)
        Rect.fromLTWH(
          (d.visiblePosition ?? Offset.zero).dx,
          (d.visiblePosition ?? Offset.zero).dy,
          (d.visibleSize ?? d.size).width,
          (d.visibleSize ?? d.size).height,
        ),
    ];
  }

  @override
  Future<void> setNativeInterceptMinimize(bool enabled) async {
    if (!Platform.isWindows && !Platform.isMacOS) return;
    await windowControlChannel.invokeMethod<void>(
      'setInterceptMinimize',
      enabled,
    );
  }
}

class MiniPlayerState {
  final bool isMini;
  final bool transitioning;
  final bool minimizedFromMini;
  final bool hiddenToTray;

  const MiniPlayerState({
    this.isMini = false,
    this.transitioning = false,
    this.minimizedFromMini = false,
    this.hiddenToTray = false,
  });

  MiniPlayerState copyWith({
    bool? isMini,
    bool? transitioning,
    bool? minimizedFromMini,
    bool? hiddenToTray,
  }) =>
      MiniPlayerState(
        isMini: isMini ?? this.isMini,
        transitioning: transitioning ?? this.transitioning,
        minimizedFromMini: minimizedFromMini ?? this.minimizedFromMini,
        hiddenToTray: hiddenToTray ?? this.hiddenToTray,
      );
}

/// App-scoped owner of the single-window floating miniplayer lifecycle.
///
/// Coordinates transitions between the full shell and [WaveMiniPlayer],
/// OS/title-bar minimize interception, taskbar/Dock visibility policies,
/// multi-monitor bounds clamping, and safe restoration from tray/MPRIS/hotkeys.
class MiniPlayerController extends StateNotifier<MiniPlayerState> {
  static const Size fullDefaultSize = Size(1360, 860);
  static const Size fullMinSize = Size(1024, 640);
  static const Size miniSize = Size(380, 78);
  static const Size miniMinSize = Size(300, 64);

  final Ref _ref;
  final MiniWindowAdapter _window;
  final bool _nativePreInterceptSupported;

  Size? _savedWindowSize;
  Offset? _savedWindowPos;
  bool _savedWasMaximized = false;
  bool _bypassNextOsMinimize = false;
  bool? _lastNativeIntercept;
  Future<void> _serial = Future<void>.value();

  MiniPlayerController(
    this._ref, {
    MiniWindowAdapter? window,
    bool? nativePreInterceptSupported,
  })  : _window = window ?? const _DesktopMiniWindowAdapter(),
        _nativePreInterceptSupported =
            nativePreInterceptSupported ?? (Platform.isWindows || Platform.isMacOS),
        super(const MiniPlayerState());

  Future<T> _serialized<T>(Future<T> Function() fn) {
    final completer = Completer<T>();
    _serial = _serial.then((_) async {
      try {
        completer.complete(await fn());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  /// Evaluates whether [mode] should morph on minimize for a track state.
  static bool shouldInterceptForMode({
    required String mode,
    required bool hasTrack,
    required bool isPlaying,
  }) {
    return switch (mode) {
      'always' => true,
      'playing' => isPlaying && hasTrack,
      'track' => hasTrack,
      _ => false,
    };
  }

  /// Clamps a desired miniplayer top-left [desired] (of [windowSize]) inside
  /// the closest/containing display work area, preserving negative coordinates
  /// for secondary monitors placed left of or above the primary display.
  static Offset clampMiniPositionToWorkAreas(
    Offset desired,
    Size windowSize,
    List<Rect> workAreas, {
    double margin = 8.0,
  }) {
    if (workAreas.isEmpty) return desired;

    final targetRect = desired & windowSize;
    final center = targetRect.center;

    Rect? chosen;
    var bestArea = -1.0;
    for (final area in workAreas) {
      if (area.width <= 0 || area.height <= 0) continue;
      if (area.contains(center)) {
        chosen = area;
        break;
      }
      final overlap = targetRect.intersect(area);
      final overlapArea =
          math.max(0.0, overlap.width) * math.max(0.0, overlap.height);
      if (overlapArea > bestArea) {
        bestArea = overlapArea;
        chosen = area;
      }
    }

    // If saved coordinates fell off all monitors (e.g., monitor unplugged),
    // place cleanly near the bottom-right of the primary display.
    if (chosen == null || (bestArea <= 0 && !chosen.contains(center))) {
      final primary = workAreas.firstWhere(
        (r) => r.width > 0 && r.height > 0,
        orElse: () => workAreas.first,
      );
      final maxX = math.max(primary.left, primary.right - windowSize.width);
      final maxY = math.max(primary.top, primary.bottom - windowSize.height);
      final px = (primary.right - windowSize.width - 24.0)
          .clamp(primary.left, maxX)
          .toDouble();
      final py = (primary.bottom - windowSize.height - 24.0)
          .clamp(primary.top, maxY)
          .toDouble();
      return Offset(px, py);
    }

    final padX = chosen.width > windowSize.width + margin * 2 ? margin : 0.0;
    final padY = chosen.height > windowSize.height + margin * 2 ? margin : 0.0;
    final minX = chosen.left + padX;
    final minY = chosen.top + padY;
    final maxX = math.max(minX, chosen.right - windowSize.width - padX);
    final maxY = math.max(minY, chosen.bottom - windowSize.height - padY);
    return Offset(
      desired.dx.clamp(minX, maxX).toDouble(),
      desired.dy.clamp(minY, maxY).toDouble(),
    );
  }

  bool get _insideShell => _ref.read(miniShellActiveProvider);

  /// True when an OS/title-bar minimize action on the full window should
  /// morph into the floating miniplayer instead of minimizing normally.
  bool get canInterceptMinimize {
    if (!_insideShell ||
        state.isMini ||
        state.transitioning ||
        _bypassNextOsMinimize) {
      return false;
    }
    final prefs = _ref.read(prefsProvider);
    final playback = _ref.read(miniPlaybackStateProvider);
    return shouldInterceptForMode(
      mode: prefs.minimizeToMiniMode,
      hasTrack: playback.hasTrack,
      isPlaying: playback.isPlaying,
    );
  }

  /// Pushes the latest intercept state to native platform runners and keeps
  /// taskbar visibility synced if preferences changed while already in mini mode.
  Future<void> syncFromPrefs() async {
    await _syncNativeIntercept();
    if (state.isMini && !state.minimizedFromMini) {
      final mode = _ref.read(prefsProvider).miniTaskbarMode;
      await _safe(() => _window.setSkipTaskbar(mode != 'show'));
    }
  }

  Future<void> _syncNativeIntercept() async {
    if (!_nativePreInterceptSupported) return;
    final next = canInterceptMinimize;
    if (_lastNativeIntercept == next) return;
    _lastNativeIntercept = next;
    await _safe(() => _window.setNativeInterceptMinimize(next));
  }

  /// Toggles between the full shell and floating miniplayer (used by the dock).
  Future<void> toggle() {
    if (state.isMini) {
      return exit();
    }
    return enter(bypassTriggerRules: true);
  }

  /// Handles clicks on the full window's custom minimize (`—`) button.
  Future<void> handleMinimizeRequest() async {
    if (canInterceptMinimize) {
      await enter();
      return;
    }
    await _performOsMinimize();
  }

  void _scheduleBypassReset() {
    Future<void>.delayed(const Duration(milliseconds: 500), () {
      if (_bypassNextOsMinimize) {
        _bypassNextOsMinimize = false;
        unawaited(_syncNativeIntercept());
      }
    });
  }

  Future<void> _performOsMinimize() async {
    _bypassNextOsMinimize = true;
    await _syncNativeIntercept();
    await _safe(() => _window.minimize());
    _scheduleBypassReset();
  }

  /// Transitions the single OS window into the floating miniplayer.
  Future<void> enter({bool bypassTriggerRules = false}) {
    return _serialized(() async {
      if (state.isMini) return;
      if (!bypassTriggerRules && !canInterceptMinimize) return;
      if (bypassTriggerRules && !_insideShell) return;

      state = state.copyWith(transitioning: true);
      await _syncNativeIntercept();

      try {
        await _safe(() async {
          if (await _window.isMinimized()) {
            await _window.restore();
            await Future<void>.delayed(const Duration(milliseconds: 40));
          }
          if (await _window.isFullScreen()) {
            await _window.setFullScreen(false);
            await Future<void>.delayed(const Duration(milliseconds: 60));
          }
        });
        try {
          _ref.read(nowPlayingImmersiveProvider.notifier).state = false;
        } catch (_) {}

        await _safe(() async {
          _savedWasMaximized = await _window.isMaximized();
          if (_savedWasMaximized) {
            await _window.unmaximize();
            await Future<void>.delayed(const Duration(milliseconds: 60));
          }
          _savedWindowSize = await _window.getSize();
          _savedWindowPos = await _window.getPosition();
        });

        _setMediaBackgrounded(true);

        state = state.copyWith(
          isMini: true,
          minimizedFromMini: false,
          hiddenToTray: false,
        );

        await _safe(() async {
          await _window.setMinimumSize(miniMinSize);
          await _window.setSize(miniSize);
          final target = await _resolveMiniPosition();
          if (target != null) {
            await _window.setPosition(target);
          }
          await _window.setAlwaysOnTop(true);
          final taskbarMode = _ref.read(prefsProvider).miniTaskbarMode;
          await _window.setSkipTaskbar(taskbarMode != 'show');
        });
      } finally {
        state = state.copyWith(transitioning: false);
        await _syncNativeIntercept();
      }
    });
  }

  Future<Offset?> _resolveMiniPosition() async {
    final prefs = _ref.read(prefsProvider);
    final saved = prefs.miniPlayerPosition;
    Offset? desired = saved;
    if (desired == null && _savedWindowPos != null && _savedWindowSize != null) {
      desired = Offset(
        _savedWindowPos!.dx + (_savedWindowSize!.width - miniSize.width - 24),
        _savedWindowPos!.dy +
            (_savedWindowSize!.height - miniSize.height - 24),
      );
    }
    if (desired == null) return null;

    var areas = const <Rect>[];
    await _safe(() async {
      areas = await _window.getDisplayWorkAreas();
    });
    return clampMiniPositionToWorkAreas(desired, miniSize, areas);
  }

  Future<void> _saveCurrentMiniPosition() async {
    await _safe(() async {
      if (state.minimizedFromMini ||
          state.hiddenToTray ||
          await _window.isMinimized()) {
        return;
      }
      final pos = await _window.getPosition();
      // Win32 reports (-32000, -32000) for minimized windows; genuine negative
      // multi-monitor coordinates stay well above -30000.
      if (pos.dx <= -30000 || pos.dy <= -30000) return;
      await _ref.read(prefsProvider).setMiniPlayerPosition(pos);
    });
  }

  /// Restores the window back from the floating miniplayer to the full shell.
  Future<void> exit({bool ensureShown = false}) {
    return _serialized(() async {
      if (!state.isMini) {
        if (ensureShown) {
          await _safe(() async {
            if (await _window.isMinimized()) await _window.restore();
            await _window.show();
            await _window.focus();
          });
        }
        return;
      }

      state = state.copyWith(transitioning: true);
      await _syncNativeIntercept();

      try {
        await _saveCurrentMiniPosition();

        await _safe(() async {
          await _window.setAlwaysOnTop(false);
          await _window.setSkipTaskbar(false);
          if (ensureShown || state.minimizedFromMini || state.hiddenToTray) {
            if (await _window.isMinimized()) {
              await _window.restore();
            }
            await _window.show();
          }
          await _window.setMinimumSize(fullMinSize);
          if (_savedWasMaximized) {
            await _window.maximize();
          } else {
            final restoreSize = _savedWindowSize ?? fullDefaultSize;
            final restorePos = _savedWindowPos;
            if (restorePos != null) {
              await _window.setPosition(restorePos);
            }
            await _window.setSize(restoreSize);
          }
          if (ensureShown) {
            await _window.focus();
          }
        });

        state = const MiniPlayerState();
        _setMediaBackgrounded(false);
      } finally {
        state = state.copyWith(transitioning: false);
        await _syncNativeIntercept();
      }
    });
  }

  /// Invoked by `WaveMiniPlayer`'s own minimize (`—`) button so it minimizes
  /// to the taskbar or hides to tray cleanly without re-triggering mini mode.
  Future<void> minimizeFromMini() {
    return _serialized(() async {
      if (!state.isMini) {
        await _performOsMinimize();
        return;
      }

      await _saveCurrentMiniPosition();

      final taskbarMode = _ref.read(prefsProvider).miniTaskbarMode;
      if (taskbarMode == 'tray') {
        state = state.copyWith(minimizedFromMini: true, hiddenToTray: true);
        await _safe(() => _window.hide());
        return;
      }

      _bypassNextOsMinimize = true;
      await _syncNativeIntercept();
      state = state.copyWith(minimizedFromMini: true, hiddenToTray: false);

      await _safe(() async {
        // Restore taskbar visibility before minimizing under Windows/macOS:
        // minimizing a WS_EX_TOOLWINDOW draws a legacy floating desktop stub.
        if (taskbarMode == 'smart') {
          await _window.setSkipTaskbar(false);
        }
        await _window.minimize();
      });
      _scheduleBypassReset();
    });
  }

  /// Called by [WindowLifecycle.onWindowMinimize].
  ///
  /// Returns `true` if the OS minimize was intercepted on a platform without a
  /// native pre-minimize hook (e.g. Linux) so the caller should keep visibility
  /// active and wait for [enter] rather than backgrounding the window.
  bool handleOsWindowMinimized() {
    if (_bypassNextOsMinimize) {
      _bypassNextOsMinimize = false;
      unawaited(_syncNativeIntercept());
      return false;
    }
    if (state.isMini) {
      if (!state.minimizedFromMini) {
        state = state.copyWith(minimizedFromMini: true);
      }
      return false;
    }
    if (!_nativePreInterceptSupported && canInterceptMinimize) {
      unawaited(_restoreAndEnterMini());
      return true;
    }
    return false;
  }

  Future<void> _restoreAndEnterMini() async {
    await _safe(() => _window.restore());
    await enter();
  }

  /// Called by [WindowLifecycle.onWindowRestore] / `onWindowFocus`.
  Future<void> onWindowRestored() async {
    _bypassNextOsMinimize = false;
    if (!state.isMini) {
      await _syncNativeIntercept();
      return;
    }
    final wasHiddenOrMin = state.minimizedFromMini || state.hiddenToTray;
    if (wasHiddenOrMin) {
      state = state.copyWith(minimizedFromMini: false, hiddenToTray: false);
    }
    await _safe(() async {
      await _window.setAlwaysOnTop(true);
      final mode = _ref.read(prefsProvider).miniTaskbarMode;
      await _window.setSkipTaskbar(mode != 'show');
    });
    await _syncNativeIntercept();
  }

  /// Syncs native interception or leaves mini mode when auth state changes.
  Future<void> onAuthChanged(bool inside) async {
    if (!inside && state.isMini) {
      await exit();
    } else {
      await syncFromPrefs();
    }
  }

  /// Ensures clean window flags before process exit.
  Future<void> prepareForQuit() async {
    if (!state.isMini) return;
    await _safe(() async {
      await _window.setAlwaysOnTop(false);
      await _window.setSkipTaskbar(false);
    });
  }

  void _setMediaBackgrounded(bool backgrounded) {
    try {
      _ref.read(animatedArtworkSessionProvider).setBackgrounded(backgrounded);
    } catch (_) {}
    try {
      _ref.read(canvasPanelSessionProvider).setBackgrounded(backgrounded);
    } catch (_) {}
  }

  static Future<void> _safe(Future<void> Function() fn) async {
    try {
      await fn();
    } catch (_) {}
  }
}

final miniWindowAdapterProvider = Provider<MiniWindowAdapter>(
  (_) => const _DesktopMiniWindowAdapter(),
);

final miniNativeInterceptSupportedProvider = Provider<bool>(
  (_) => Platform.isWindows || Platform.isMacOS,
);

final miniPlayerProvider =
    StateNotifierProvider<MiniPlayerController, MiniPlayerState>((ref) {
  final controller = MiniPlayerController(
    ref,
    window: ref.watch(miniWindowAdapterProvider),
    nativePreInterceptSupported: ref.watch(miniNativeInterceptSupportedProvider),
  );
  // Keep native pre-minimize interception synced with playback & auth changes.
  ref.listen<({bool hasTrack, bool isPlaying})>(
    miniPlaybackStateProvider,
    (_, _) => unawaited(controller.syncFromPrefs()),
  );
  ref.listen<bool>(
    miniShellActiveProvider,
    (_, inside) => unawaited(controller.onAuthChanged(inside)),
  );
  controller.syncFromPrefs();
  return controller;
});
