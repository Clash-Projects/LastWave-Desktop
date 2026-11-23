import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/storage/prefs.dart';
import 'package:lastwave_desktop/features/settings/ui_scale.dart';
import 'package:lastwave_desktop/ui/app_shell/wave_hotkeys.dart';
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
}
