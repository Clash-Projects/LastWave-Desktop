import 'dart:async';
import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/app/mini_player_controller.dart';
import 'package:lastwave_desktop/core/storage/prefs.dart';
import 'package:lastwave_desktop/ui/now_playing/immersive.dart';
import 'package:lastwave_desktop/ui/settings/settings_search.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeWindowAdapter implements MiniWindowAdapter {
  bool maximized = false;
  bool minimized = false;
  bool fullScreen = false;
  bool visible = true;
  bool alwaysOnTop = false;
  bool skipTaskbar = false;
  Size size = const Size(1360, 860);
  Size minSize = const Size(1024, 640);
  Offset position = const Offset(100, 80);
  List<Rect> workAreas = const [Rect.fromLTWH(0, 0, 1920, 1040)];
  bool? lastNativeIntercept;
  final List<String> calls = [];
  Future<void> Function()? onUnmaximize;
  Future<void> Function()? onRestore;
  Future<void> Function(bool value)? onSetSkipTaskbar;

  @override
  Future<List<Rect>> getDisplayWorkAreas() async {
    calls.add('getDisplayWorkAreas');
    return workAreas;
  }

  @override
  Future<Offset> getPosition() async {
    calls.add('getPosition');
    return minimized ? const Offset(-32000, -32000) : position;
  }

  @override
  Future<Size> getSize() async {
    calls.add('getSize');
    return size;
  }

  @override
  Future<bool> isFullScreen() async => fullScreen;

  @override
  Future<bool> isMaximized() async => maximized;

  @override
  Future<bool> isMinimized() async => minimized;

  @override
  Future<void> focus() async {
    calls.add('focus');
  }

  @override
  Future<void> hide() async {
    visible = false;
    calls.add('hide');
  }

  @override
  Future<void> maximize() async {
    maximized = true;
    minimized = false;
    calls.add('maximize');
  }

  @override
  Future<void> minimize() async {
    minimized = true;
    calls.add('minimize');
  }

  @override
  Future<void> restore() async {
    minimized = false;
    calls.add('restore');
    if (onRestore != null) await onRestore!();
  }

  @override
  Future<void> setAlwaysOnTop(bool value) async {
    alwaysOnTop = value;
    calls.add('setAlwaysOnTop($value)');
  }

  @override
  Future<void> setFullScreen(bool value) async {
    fullScreen = value;
    calls.add('setFullScreen($value)');
  }

  @override
  Future<void> setMinimumSize(Size value) async {
    minSize = value;
    calls.add('setMinimumSize(${value.width.toInt()},${value.height.toInt()})');
  }

  @override
  Future<void> setNativeInterceptMinimize(bool enabled) async {
    lastNativeIntercept = enabled;
    calls.add('setNativeIntercept($enabled)');
  }

  @override
  Future<void> setPosition(Offset value) async {
    position = value;
    calls.add('setPosition(${value.dx.round()},${value.dy.round()})');
  }

  @override
  Future<void> setSize(Size value) async {
    size = value;
    calls.add('setSize(${value.width.toInt()},${value.height.toInt()})');
  }

  @override
  Future<void> setSkipTaskbar(bool value) async {
    skipTaskbar = value;
    calls.add('setSkipTaskbar($value)');
    if (onSetSkipTaskbar != null) await onSetSkipTaskbar!(value);
  }

  @override
  Future<void> show() async {
    visible = true;
    calls.add('show');
  }

  @override
  Future<void> unmaximize() async {
    maximized = false;
    calls.add('unmaximize');
    if (onUnmaximize != null) await onUnmaximize!();
  }
}

final _testInsideProvider = StateProvider<bool>((_) => true);
final _testPlaybackProvider =
    StateProvider<({bool hasTrack, bool isPlaying})>(
  (_) => (hasTrack: false, isPlaying: false),
);

Future<(ProviderContainer, _FakeWindowAdapter, Prefs)> _createHarness({
  Map<String, Object> initialPrefs = const {},
  bool nativePreIntercept = true,
  bool insideShell = true,
  bool hasTrack = false,
  bool isPlaying = false,
}) async {
  SharedPreferences.setMockInitialValues(initialPrefs);
  final prefs = Prefs(await SharedPreferences.getInstance());
  final adapter = _FakeWindowAdapter();
  final container = ProviderContainer(
    overrides: [
      prefsProvider.overrideWithValue(prefs),
      miniWindowAdapterProvider.overrideWithValue(adapter),
      miniNativeInterceptSupportedProvider.overrideWithValue(nativePreIntercept),
      _testInsideProvider.overrideWith((_) => insideShell),
      _testPlaybackProvider.overrideWith(
        (_) => (hasTrack: hasTrack, isPlaying: isPlaying),
      ),
      miniShellActiveProvider.overrideWith(
        (ref) => ref.watch(_testInsideProvider),
      ),
      miniPlaybackStateProvider.overrideWith(
        (ref) => ref.watch(_testPlaybackProvider),
      ),
    ],
  );
  // Instantiate the controller eagerly as WindowLifecycle does.
  container.read(miniPlayerProvider);
  await Future<void>.delayed(Duration.zero);
  return (container, adapter, prefs);
}

void main() {
  test('shouldInterceptForMode covers all four modes', () {
    expect(
      MiniPlayerController.shouldInterceptForMode(
        mode: 'off',
        hasTrack: true,
        isPlaying: true,
      ),
      isFalse,
    );
    expect(
      MiniPlayerController.shouldInterceptForMode(
        mode: 'playing',
        hasTrack: true,
        isPlaying: false,
      ),
      isFalse,
    );
    expect(
      MiniPlayerController.shouldInterceptForMode(
        mode: 'playing',
        hasTrack: true,
        isPlaying: true,
      ),
      isTrue,
    );
    expect(
      MiniPlayerController.shouldInterceptForMode(
        mode: 'track',
        hasTrack: false,
        isPlaying: false,
      ),
      isFalse,
    );
    expect(
      MiniPlayerController.shouldInterceptForMode(
        mode: 'track',
        hasTrack: true,
        isPlaying: false,
      ),
      isTrue,
    );
    expect(
      MiniPlayerController.shouldInterceptForMode(
        mode: 'always',
        hasTrack: false,
        isPlaying: false,
      ),
      isTrue,
    );
  });

  test('track mode (default hybrid) morphs when loaded and minimizes when idle',
      () async {
    final (container, window, prefs) = await _createHarness();
    addTearDown(container.dispose);

    expect(prefs.minimizeToMiniMode, 'track');
    expect(window.lastNativeIntercept, isFalse);

    // Idle minimize passes through to OS minimize.
    await container.read(miniPlayerProvider.notifier).handleMinimizeRequest();
    expect(container.read(miniPlayerProvider).isMini, isFalse);
    expect(window.minimized, isTrue);
    await container.read(miniPlayerProvider.notifier).onWindowRestored();
    window.minimized = false;

    // Paused with loaded track -> intercepts and morphs to miniplayer.
    container.read(_testPlaybackProvider.notifier).state = (
      hasTrack: true,
      isPlaying: false,
    );
    await Future<void>.delayed(Duration.zero);
    expect(window.lastNativeIntercept, isTrue);

    await container.read(miniPlayerProvider.notifier).handleMinimizeRequest();
    expect(container.read(miniPlayerProvider).isMini, isTrue);
    expect(window.size, MiniPlayerController.miniSize);
    expect(window.alwaysOnTop, isTrue);
    expect(window.skipTaskbar, isTrue); // default taskbar mode = smart
    expect(window.lastNativeIntercept, isFalse); // disabled once in mini mode
  });

  test('minimizeFromMini smart mode restores taskbar before OS minimize and avoids stub',
      () async {
    final (container, window, _) = await _createHarness(
      hasTrack: true,
      isPlaying: true,
    );
    addTearDown(container.dispose);

    final ctrl = container.read(miniPlayerProvider.notifier);
    await ctrl.enter();
    expect(window.skipTaskbar, isTrue);

    window.calls.clear();
    await ctrl.minimizeFromMini();

    final skipIdx = window.calls.indexOf('setSkipTaskbar(false)');
    final minIdx = window.calls.indexOf('minimize');
    expect(skipIdx, greaterThanOrEqualTo(0));
    expect(minIdx, greaterThan(skipIdx));
    expect(container.read(miniPlayerProvider).minimizedFromMini, isTrue);
    expect(window.minimized, isTrue);

    // Restoring from taskbar keeps mini mode and re-hides taskbar.
    window.minimized = false;
    await ctrl.onWindowRestored();
    expect(container.read(miniPlayerProvider).isMini, isTrue);
    expect(container.read(miniPlayerProvider).minimizedFromMini, isFalse);
    expect(window.alwaysOnTop, isTrue);
    expect(window.skipTaskbar, isTrue);
  });

  test('tray taskbar mode hides to tray on minimizeFromMini and restores full on exit',
      () async {
    final (container, window, _) = await _createHarness(
      initialPrefs: {'lw_mini_taskbar_mode': 'tray'},
      hasTrack: true,
    );
    addTearDown(container.dispose);

    final ctrl = container.read(miniPlayerProvider.notifier);
    await ctrl.enter();
    expect(window.skipTaskbar, isTrue);

    await ctrl.minimizeFromMini();
    expect(window.visible, isFalse);
    expect(window.calls, isNot(contains('minimize')));
    expect(container.read(miniPlayerProvider).hiddenToTray, isTrue);

    // Expanding from tray restores full window size, alwaysOnTop=false, skipTaskbar=false.
    await ctrl.exit(ensureShown: true);
    expect(container.read(miniPlayerProvider).isMini, isFalse);
    expect(container.read(miniPlayerProvider).hiddenToTray, isFalse);
    expect(window.visible, isTrue);
    expect(window.alwaysOnTop, isFalse);
    expect(window.skipTaskbar, isFalse);
    expect(window.size, const Size(1360, 860));
    expect(window.minSize, MiniPlayerController.fullMinSize);
  });

  test('Linux OS minimize fallback restores and enters mini without looping',
      () async {
    final (container, window, _) = await _createHarness(
      nativePreIntercept: false,
      hasTrack: true,
      isPlaying: true,
    );
    addTearDown(container.dispose);

    final ctrl = container.read(miniPlayerProvider.notifier);
    window.minimized = true;
    final intercepted = ctrl.handleOsWindowMinimized();
    expect(intercepted, isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(container.read(miniPlayerProvider).isMini, isTrue);
    expect(window.minimized, isFalse);

    // Subsequent OS minimize while already mini does not re-intercept.
    expect(ctrl.handleOsWindowMinimized(), isFalse);
  });

  test('sign out exits miniplayer automatically and blocks intercept on /welcome',
      () async {
    final (container, window, _) = await _createHarness(
      initialPrefs: {'lw_minimize_to_mini_mode': 'always'},
    );
    addTearDown(container.dispose);

    final ctrl = container.read(miniPlayerProvider.notifier);
    await ctrl.enter();
    expect(container.read(miniPlayerProvider).isMini, isTrue);

    container.read(_testInsideProvider.notifier).state = false;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(container.read(miniPlayerProvider).isMini, isFalse);
    expect(window.alwaysOnTop, isFalse);
    expect(window.size, const Size(1360, 860));
    expect(ctrl.canInterceptMinimize, isFalse);
  });

  test('fullscreen & maximized window state are cleaned on enter and restored on exit',
      () async {
    final (container, window, _) = await _createHarness(
      hasTrack: true,
    );
    addTearDown(container.dispose);

    window.maximized = true;
    window.fullScreen = true;
    container.read(nowPlayingImmersiveProvider.notifier).state = true;

    final ctrl = container.read(miniPlayerProvider.notifier);
    await ctrl.enter();

    expect(window.fullScreen, isFalse);
    expect(window.maximized, isFalse);
    expect(container.read(nowPlayingImmersiveProvider), isFalse);
    expect(window.size, MiniPlayerController.miniSize);

    await ctrl.exit();
    expect(window.maximized, isTrue);
    expect(window.alwaysOnTop, isFalse);
  });

  test('exit while minimized does not persist (-32000, -32000) to prefs',
      () async {
    final (container, window, prefs) = await _createHarness(
      hasTrack: true,
    );
    addTearDown(container.dispose);

    final ctrl = container.read(miniPlayerProvider.notifier);
    await ctrl.enter();
    // Simulate external minimize (e.g. Win+D) where getPosition returns -32000.
    window.minimized = true;
    await ctrl.exit(ensureShown: true);
    expect(prefs.miniPlayerPosition, isNull);
    expect(window.alwaysOnTop, isFalse);

    // minimizeFromMini saves the valid floating coordinates before minimizing,
    // and exiting afterward preserves them instead of writing (-32000, -32000).
    window.minimized = false;
    window.size = const Size(1360, 860);
    window.position = const Offset(100, 80);
    await ctrl.enter();
    final floatingPos = window.position;
    await ctrl.minimizeFromMini();
    await ctrl.exit(ensureShown: true);
    expect(prefs.miniPlayerPosition, floatingPos);
    expect(prefs.miniPlayerPosition!.dx, greaterThan(-30000));
  });

  test('multi-monitor clamping preserves negative coordinates and rescues unplugged screen',
      () {
    const areas = [
      Rect.fromLTWH(0, 0, 1920, 1040),
      Rect.fromLTWH(-1920, 0, 1920, 1040),
    ];

    // Secondary monitor on left keeps negative X.
    final leftPos = MiniPlayerController.clampMiniPositionToWorkAreas(
      const Offset(-400, 900),
      MiniPlayerController.miniSize,
      areas,
    );
    expect(leftPos.dx, -400);
    expect(leftPos.dy, 900);

    // Off-screen unplugged right monitor (x=2800) falls back to primary bottom-right.
    final rescued = MiniPlayerController.clampMiniPositionToWorkAreas(
      const Offset(2800, 500),
      MiniPlayerController.miniSize,
      areas,
    );
    expect(rescued.dx, 1920 - 380 - 24);
    expect(rescued.dy, 1040 - 78 - 24);
  });

  test('prefs device-bound guard excludes mini position but keeps behaviour modes',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = Prefs(await SharedPreferences.getInstance());

    await prefs.setMiniPlayerPosition(const Offset(120, 240));
    await prefs.setPortablePref('lw_mini_pos_x', 999.0);
    expect(prefs.miniPlayerPosition, const Offset(120, 240));
    expect(Prefs.isDeviceBoundPref('lw_mini_pos_x'), isTrue);
    expect(Prefs.isDeviceBoundPref('lw_mini_pos_y'), isTrue);

    await prefs.setMinimizeToMiniMode('invalid');
    expect(prefs.minimizeToMiniMode, 'track');
    await prefs.setMiniTaskbarMode('invalid');
    expect(prefs.miniTaskbarMode, 'smart');

    expect(
      filterSettings(settingsSearchEntries, 'miniplayer')
          .map((e) => e.id)
          .contains('general.behaviour'),
      isTrue,
    );
  });

  test('stale native minimize falls back to bypassed OS minimize', () async {
    final (container, window, _) = await _createHarness(
      initialPrefs: {'lw_minimize_to_mini_mode': 'playing'},
      hasTrack: true,
      isPlaying: true,
    );
    addTearDown(container.dispose);

    // Pause right after native code intercepted, before Dart dispatch runs.
    container.read(_testPlaybackProvider.notifier).state = (
      hasTrack: true,
      isPlaying: false,
    );
    await container.read(miniPlayerProvider.notifier).handleMinimizeRequest();

    expect(container.read(miniPlayerProvider).isMini, isFalse);
    expect(window.minimized, isTrue);
    expect(container.read(miniPlayerProvider.notifier).handleOsWindowMinimized(),
        isFalse);
  });

  test('auth loss during in-flight enter() reconciles back to full window',
      () async {
    final (container, window, _) = await _createHarness(
      hasTrack: true,
      isPlaying: true,
    );
    addTearDown(container.dispose);

    final pauseEnter = Completer<void>();
    window.maximized = true;
    window.onUnmaximize = () => pauseEnter.future;

    final ctrl = container.read(miniPlayerProvider.notifier);
    final entering = ctrl.enter();
    await Future<void>.delayed(Duration.zero);

    // User signs out while enter() is awaiting window preparation.
    container.read(_testInsideProvider.notifier).state = false;
    pauseEnter.complete();
    await entering;
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(container.read(miniPlayerProvider).isMini, isFalse);
    expect(window.alwaysOnTop, isFalse);
    expect(window.skipTaskbar, isFalse);
    expect(window.maximized, isTrue);
  });

  test('onWindowRestored during exit() does not reapply mini flags to full shell',
      () async {
    final (container, window, _) = await _createHarness(hasTrack: true);
    addTearDown(container.dispose);

    final ctrl = container.read(miniPlayerProvider.notifier);
    await ctrl.enter();
    await ctrl.minimizeFromMini();

    final pauseRestore = Completer<void>();
    Future<void>? concurrentRestore;
    window.onRestore = () {
      // Simulate OS onWindowRestore firing right as exit() restores the HWND.
      concurrentRestore = ctrl.onWindowRestored();
      return pauseRestore.future;
    };

    final exiting = ctrl.exit(ensureShown: true);
    await Future<void>.delayed(Duration.zero);
    pauseRestore.complete();
    await exiting;
    await concurrentRestore;

    expect(container.read(miniPlayerProvider).isMini, isFalse);
    expect(window.alwaysOnTop, isFalse);
    expect(window.skipTaskbar, isFalse);
  });

  test('external OS minimize of miniplayer restores smart taskbar visibility',
      () async {
    final (container, window, _) = await _createHarness(hasTrack: true);
    addTearDown(container.dispose);

    final ctrl = container.read(miniPlayerProvider.notifier);
    await ctrl.enter();
    expect(window.skipTaskbar, isTrue);

    window.minimized = true;
    expect(ctrl.handleOsWindowMinimized(), isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(container.read(miniPlayerProvider).minimizedFromMini, isTrue);
    expect(window.skipTaskbar, isFalse);

    window.minimized = false;
    await ctrl.onWindowRestored();
    expect(window.skipTaskbar, isTrue);
  });

  test('syncFromPrefs during exit() does not re-hide full shell from taskbar',
      () async {
    final (container, window, _) = await _createHarness(
      hasTrack: true,
      isPlaying: true,
    );
    addTearDown(container.dispose);

    final ctrl = container.read(miniPlayerProvider.notifier);
    await ctrl.enter();
    expect(window.skipTaskbar, isTrue);

    final pauseClearTaskbar = Completer<void>();
    var blockedOnce = false;
    window.onSetSkipTaskbar = (val) {
      if (!val && !blockedOnce) {
        blockedOnce = true;
        // Playback flips while exit() is mid-way right after clearing skipTaskbar.
        container.read(_testPlaybackProvider.notifier).state = (
          hasTrack: true,
          isPlaying: false,
        );
        return pauseClearTaskbar.future;
      }
      return Future<void>.value();
    };

    final exiting = ctrl.exit();
    await Future<void>.delayed(Duration.zero);
    pauseClearTaskbar.complete();
    await exiting;
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(container.read(miniPlayerProvider).isMini, isFalse);
    expect(window.skipTaskbar, isFalse);
  });
}
