import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/ui/components/buttons.dart';

Widget _host({VoidCallback? onTap, double pressedScale = 0.97}) {
  return FluentApp(
    home: Center(
      child: WavePressable(
        onTap: onTap,
        pressedScale: pressedScale,
        child: const SizedBox(width: 80, height: 80),
      ),
    ),
  );
}

double _scale(WidgetTester tester) => tester
    .widget<AnimatedScale>(
      find.descendant(
        of: find.byType(WavePressable),
        matching: find.byType(AnimatedScale),
      ),
    )
    .scale;

MouseCursor _cursor(WidgetTester tester) => tester
    .widget<MouseRegion>(
      find.descendant(
        of: find.byType(WavePressable),
        matching: find.byType(MouseRegion),
      ),
    )
    .cursor;

void main() {
  testWidgets('dips under the press and restores on release', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_host(onTap: () => taps++));
    expect(_scale(tester), 1.0);

    final centre = tester.getCenter(find.byType(WavePressable));
    final gesture = await tester.startGesture(centre);
    await tester.pump(const Duration(milliseconds: 40));
    expect(_scale(tester), lessThan(1.0),
        reason: 'the card has to react before the route grows out of it');

    await gesture.up();
    await tester.pumpAndSettle();
    expect(_scale(tester), 1.0);
    expect(taps, 1);
  });

  testWidgets('a cancelled press does not leave the surface dipped',
      (tester) async {
    await tester.pumpWidget(_host(onTap: () {}));
    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(WavePressable)));
    await tester.pump(const Duration(milliseconds: 40));
    expect(_scale(tester), lessThan(1.0));

    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(_scale(tester), 1.0);
  });

  testWidgets('honours a per-surface dip', (tester) async {
    await tester.pumpWidget(_host(onTap: () {}, pressedScale: 0.985));
    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(WavePressable)));
    await tester.pumpAndSettle();
    expect(_scale(tester), 0.985);
    await gesture.up();
  });

  testWidgets('carries the pointer cursor only when it is tappable',
      (tester) async {
    await tester.pumpWidget(_host(onTap: () {}));
    expect(_cursor(tester), SystemMouseCursors.click);

    await tester.pumpWidget(_host());
    expect(_cursor(tester), MouseCursor.defer);
  });
}
