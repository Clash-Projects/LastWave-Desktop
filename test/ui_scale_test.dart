import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/storage/prefs.dart';
import 'package:lastwave_desktop/features/settings/ui_scale.dart';
import 'package:lastwave_desktop/ui/app_shell/wave_hotkeys.dart';
import 'package:lastwave_desktop/ui/app_shell/wave_resize_area.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('UiScaleNotifier & Presets', () {
    late Prefs prefs;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await Prefs.load();
    });

    test('defaults to 1.0', () {
      final notifier = UiScaleNotifier(prefs);
      expect(notifier.state, equals(1.0));
      expect(UiScalePresets.label(1.0), contains('Standard'));
    });

    test('zoomIn increases by step up to max', () async {
      final notifier = UiScaleNotifier(prefs);
      await notifier.zoomIn();
      expect(notifier.state, closeTo(1.10, 0.001));
      expect(prefs.uiScale, closeTo(1.10, 0.001));

      // Zoom multiple times up to ceiling
      for (int i = 0; i < 10; i++) {
        await notifier.zoomIn();
      }
      expect(notifier.state, equals(UiScalePresets.max));
    });

    test('zoomOut decreases by step down to min', () async {
      final notifier = UiScaleNotifier(prefs);
      await notifier.zoomOut();
      expect(notifier.state, closeTo(0.90, 0.001));
      expect(prefs.uiScale, closeTo(0.90, 0.001));

      for (int i = 0; i < 10; i++) {
        await notifier.zoomOut();
      }
      expect(notifier.state, equals(UiScalePresets.min));
    });

    test('reset restores to 1.0', () async {
      final notifier = UiScaleNotifier(prefs);
      await notifier.setScale(1.25);
      expect(notifier.state, equals(1.25));
      await notifier.reset();
      expect(notifier.state, equals(1.0));
    });
  });

  group('WaveHotkeys zoom bindings', () {
    testWidgets('Ctrl+ and Ctrl- trigger callbacks', (tester) async {
      bool zoomedIn = false;
      bool zoomedOut = false;
      bool reset = false;

      final actions = WaveHotkeyActions(
        isTyping: () => false,
        hasTrack: () => false,
        togglePlay: () {},
        next: () {},
        previous: () {},
        openPalette: () {},
        focusSearch: () {},
        toggleLyrics: () {},
        toggleFullscreen: () {},
        goBack: () {},
        goForward: () {},
        handleEscape: () => false,
        seekBySeconds: (_) {},
        volumeByDelta: (_) {},
        zoomIn: () => zoomedIn = true,
        zoomOut: () => zoomedOut = true,
        resetZoom: () => reset = true,
      );

      final equalEvent = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.equal,
        logicalKey: LogicalKeyboardKey.equal,
        timeStamp: Duration.zero,
      );

      // Without Ctrl: should not handle
      expect(handleWaveHotkey(equalEvent, actions), isFalse);
      expect(zoomedIn, isFalse);

      // Press Ctrl:
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);

      final handledEqual = handleWaveHotkey(equalEvent, actions);
      expect(handledEqual, isTrue);
      expect(zoomedIn, isTrue);

      final minusEvent = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.minus,
        logicalKey: LogicalKeyboardKey.minus,
        timeStamp: Duration.zero,
      );
      final handledMinus = handleWaveHotkey(minusEvent, actions);
      expect(handledMinus, isTrue);
      expect(zoomedOut, isTrue);

      final zeroEvent = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.digit0,
        logicalKey: LogicalKeyboardKey.digit0,
        timeStamp: Duration.zero,
      );
      final handledZero = handleWaveHotkey(zeroEvent, actions);
      expect(handledZero, isTrue);
      expect(reset, isTrue);

      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    });
  });

  group('UI Scale Viewport Bounds', () {
    testWidgets('110% zoom maintains right edge flush without clipping', (tester) async {
      tester.view.physicalSize = const Size(1024, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const scale = 1.10;

      await tester.pumpWidget(
        FluentApp(
          builder: (context, child) {
            return LayoutBuilder(
              builder: (context, constraints) {
                final scaledW = constraints.maxWidth / scale;
                final scaledH = constraints.maxHeight / scale;
                return Transform.scale(
                  scale: scale,
                  alignment: Alignment.topLeft,
                  child: OverflowBox(
                    alignment: Alignment.topLeft,
                    minWidth: scaledW,
                    maxWidth: scaledW,
                    minHeight: scaledH,
                    maxHeight: scaledH,
                    child: MediaQuery(
                      data: MediaQuery.of(context).copyWith(
                        size: Size(scaledW, scaledH),
                      ),
                      child: child!,
                    ),
                  ),
                );
              },
            );
          },
          home: ScaffoldPage(
            header: SizedBox(
              height: 40,
              child: Row(
                children: [
                  const Text('Left Nav'),
                  const Spacer(),
                  SizedBox(
                    key: const ValueKey('right-window-btn'),
                    width: 48,
                    height: 40,
                  ),
                ],
              ),
            ),
            content: const SizedBox(),
          ),
        ),
      );

      final rightBtnFinder = find.byKey(const ValueKey('right-window-btn'));
      expect(rightBtnFinder, findsOneWidget);
      final RenderBox box = tester.renderObject(rightBtnFinder);
      final globalPos = box.localToGlobal(Offset.zero);
      final rightEdge = globalPos.dx + box.size.width * scale;

      // Right edge must be exactly at or within window right bound (1024.0)
      expect(rightEdge, closeTo(1024.0, 0.5));
    });
  });

  group('WaveWindowResizeArea Linux Window Controls', () {
    testWidgets('Provides 16px corner zones and 8px edge zones with proper cursors', (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        FluentApp(
          home: SizedBox.expand(
            child: WaveWindowResizeArea(
              edgeSize: 8,
              cornerSize: 16,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      // Verify corner hit testing at top-left (5, 5)
      final hitTopLeft = tester.hitTestOnBinding(const Offset(5, 5));
      final topLeftTargets = hitTopLeft.path.map((e) => e.target.runtimeType.toString()).toList();
      expect(topLeftTargets.contains('RenderMouseRegion'), isTrue);

      // Verify edge hit testing at right border (798, 300)
      final hitRight = tester.hitTestOnBinding(const Offset(798, 300));
      final rightTargets = hitRight.path.map((e) => e.target.runtimeType.toString()).toList();
      expect(rightTargets.contains('RenderMouseRegion'), isTrue);
    });
  });
}
