import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/ui/theme/motion.dart';

void main() {
  testWidgets('outgoing track controls are inert during a track swap', (
    tester,
  ) async {
    final firstFocus = FocusNode();
    final secondFocus = FocusNode();
    addTearDown(firstFocus.dispose);
    addTearDown(secondFocus.dispose);
    var taps = 0;
    late StateSetter update;
    var title = 'First track';

    await tester.pumpWidget(
      FluentApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return Center(
              child: WaveTrackSwap(
                child: Button(
                  key: ValueKey(title),
                  focusNode: title == 'First track' ? firstFocus : secondFocus,
                  onPressed: () => taps++,
                  child: Text(title),
                ),
              ),
            );
          },
        ),
      ),
    );

    firstFocus.requestFocus();
    await tester.pumpAndSettle();
    expect(firstFocus.hasFocus, isTrue);

    update(() => title = 'Second track');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));

    expect(find.text('First track'), findsOneWidget);
    expect(find.text('First track').hitTestable(), findsNothing);
    expect(firstFocus.hasFocus, isFalse);
    expect(firstFocus.canRequestFocus, isFalse);
    expect(secondFocus.canRequestFocus, isTrue);
    await tester.tap(find.text('Second track'));
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(find.text('First track'), findsNothing);
  });

  testWidgets('reduced motion shows only the current track immediately', (
    tester,
  ) async {
    Widget host(String title) => FluentApp(
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Center(
          child: WaveTrackSwap(child: Text(title, key: ValueKey(title))),
        ),
      ),
    );

    await tester.pumpWidget(host('First track'));
    await tester.pumpWidget(host('Second track'));
    expect(find.text('First track'), findsNothing);
    final current = find.text('Second track');
    expect(current, findsOneWidget);
    final fade = find.ancestor(of: current, matching: find.byType(FadeTransition));
    expect(
      tester.widgetList<FadeTransition>(fade).every((f) => f.opacity.value == 1),
      isTrue,
    );
  });
}
