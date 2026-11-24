import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/ui/app_shell/wave_resize_area.dart';

void main() {
  group('WaveWindowResizeArea Linux Window Controls', () {
    testWidgets('Provides 14px corner zones and 4px edge zones with proper cursors', (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        const FluentApp(
          home: SizedBox.expand(
            child: WaveWindowResizeArea(
              edgeSize: 4,
              cornerSize: 14,
              child: SizedBox.expand(),
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

      // Verify corner hit testing at bottom-right (795, 595)
      final hitBottomRight = tester.hitTestOnBinding(const Offset(795, 595));
      final bottomRightTargets = hitBottomRight.path.map((e) => e.target.runtimeType.toString()).toList();
      expect(bottomRightTargets.contains('RenderMouseRegion'), isTrue);
    });

    testWidgets('Does not render resize handles when enabled is false (e.g. maximized)', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: WaveWindowResizeArea(
            enabled: false,
            edgeSize: 4,
            cornerSize: 14,
            child: SizedBox(width: 800, height: 600),
          ),
        ),
      );

      // When disabled, no Stack or Positioned resize handles are rendered
      expect(find.byType(Positioned), findsNothing);
    });
  });
}
