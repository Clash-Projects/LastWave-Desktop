import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/ui/theme/haze.dart';

/// The material matrix: a surface may *request* a filter (`enableBlur`), but
/// Solid mode and L1-at-low always win. The rail asks for a filter while it is
/// expanded, so it is the surface that made the override visible — it blurred
/// in Solid and at low intensity.
void main() {
  Widget harness({
    required WaveMaterialMode material,
    required WaveHazeIntensity intensity,
    required LwHazeLevel level,
    bool? enableBlur,
  }) {
    return FluentApp(
      themeMode: ThemeMode.dark,
      home: WaveHazeScope(
        material: material,
        intensity: intensity,
        child: Center(
          child: WaveHaze(
            level: level,
            enableBlur: enableBlur,
            child: const SizedBox(width: 120, height: 120),
          ),
        ),
      ),
    );
  }

  Future<bool> blurred(WidgetTester tester, Widget widget) async {
    await tester.pumpWidget(widget);
    return find.byType(BackdropFilter).evaluate().isNotEmpty;
  }

  testWidgets('solid mode never filters, whatever the surface asks for',
      (tester) async {
    for (final level in [LwHazeLevel.l1, LwHazeLevel.l2, LwHazeLevel.l3]) {
      expect(
        await blurred(
          tester,
          harness(
            material: WaveMaterialMode.solid,
            intensity: WaveHazeIntensity.high,
            level: level,
            enableBlur: true,
          ),
        ),
        isFalse,
        reason: '$level must stay static in solid mode',
      );
    }
  });

  testWidgets('low intensity keeps L1 static, L2 still frosts',
      (tester) async {
    expect(
      await blurred(
        tester,
        harness(
          material: WaveMaterialMode.haze,
          intensity: WaveHazeIntensity.low,
          level: LwHazeLevel.l1,
          enableBlur: true,
        ),
      ),
      isFalse,
    );
    expect(
      await blurred(
        tester,
        harness(
          material: WaveMaterialMode.haze,
          intensity: WaveHazeIntensity.low,
          level: LwHazeLevel.l2,
          enableBlur: true,
        ),
      ),
      isTrue,
    );
  });

  testWidgets('haze mode frosts L1 from medium up', (tester) async {
    expect(
      await blurred(
        tester,
        harness(
          material: WaveMaterialMode.haze,
          intensity: WaveHazeIntensity.medium,
          level: LwHazeLevel.l1,
          enableBlur: true,
        ),
      ),
      isTrue,
    );
  });

  testWidgets('a surface can still opt out', (tester) async {
    expect(
      await blurred(
        tester,
        harness(
          material: WaveMaterialMode.haze,
          intensity: WaveHazeIntensity.high,
          level: LwHazeLevel.l1,
          enableBlur: false,
        ),
      ),
      isFalse,
    );
  });
}
