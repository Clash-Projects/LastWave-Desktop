import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/storage/prefs.dart';
import 'package:lastwave_desktop/features/performance/performance_controller.dart';
import 'package:lastwave_desktop/features/settings/ui_scale.dart';
import 'package:lastwave_desktop/ui/app_shell/wave_hotkeys.dart';
import 'package:lastwave_desktop/ui/components/buttons.dart';
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

  group('LWTooltip positioning under scale', () {
    testWidgets('LWTooltip configures useMousePosition: false to prevent scale drift', (tester) async {
      await tester.pumpWidget(
        const FluentApp(
          home: ScaffoldPage(
            content: LWTooltip(
              message: 'Attached Tooltip',
              child: SizedBox(width: 32, height: 32),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final tooltipWidget = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltipWidget.useMousePosition, isFalse);
    });
  });

  group('PerformancePromptDismissedProvider', () {
    test('dismissing prompt updates reactive state and persists to prefs', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await Prefs.load();
      final container = ProviderContainer(
        overrides: [
          prefsProvider.overrideWithValue(prefs),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(performancePromptDismissedProvider), isFalse);
      expect(prefs.performancePromptDismissed, isFalse);

      await container.read(performancePromptDismissedProvider.notifier).dismiss();
      expect(container.read(performancePromptDismissedProvider), isTrue);
      expect(prefs.performancePromptDismissed, isTrue);
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

    testWidgets('Real-time reactivity: uiScaleProvider updates transform dynamically without app restart', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final localPrefs = await Prefs.load();
      final container = ProviderContainer(
        overrides: [
          prefsProvider.overrideWithValue(localPrefs),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: FluentApp(
            builder: (context, child) {
              return Consumer(
                builder: (context, ref, _) {
                  final uiScale = ref.watch(uiScaleProvider);
                  Widget root = child ?? const SizedBox();
                  if ((uiScale - 1.0).abs() >= 0.001) {
                    root = Transform.scale(
                      key: const ValueKey('wave-ui-scale-transform'),
                      scale: uiScale,
                      child: root,
                    );
                  }
                  return root;
                },
              );
            },
            home: const SizedBox(key: ValueKey('test-home')),
          ),
        ),
      );

      final transformFinder = find.byKey(const ValueKey('wave-ui-scale-transform'));

      // Initially at 1.0 (standard): no scale transform applied
      expect(transformFinder, findsNothing);

      // Change scale in real-time
      await container.read(uiScaleProvider.notifier).setScale(1.25);
      await tester.pump();

      // Instantly renders with Transform scale 1.25 without app restart
      expect(transformFinder, findsOneWidget);
      final Transform transformWidget = tester.widget(transformFinder);
      expect(transformWidget.transform.getMaxScaleOnAxis(), closeTo(1.25, 0.001));

      // Reset in real-time
      await container.read(uiScaleProvider.notifier).reset();
      await tester.pump();

      // Transform removed immediately
      expect(transformFinder, findsNothing);
    });
  });
}
