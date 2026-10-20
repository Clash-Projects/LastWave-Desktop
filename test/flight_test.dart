import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/ui/navigation/flight.dart';

/// The cover flight is armed from the pressed card and replayed by the
/// destination header. These cover the contract between the two: what arms,
/// what consumes, what is refused (duplicate ids, stale arms, reduce motion).
void main() {
  setUp(WaveFlight.reset);

  Widget app(Widget child, {bool reduceMotion = false}) {
    return FluentApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: child,
      ),
    );
  }

  testWidgets('arms only for detail routes', (tester) async {
    late BuildContext cardContext;
    await tester.pumpWidget(app(
      Center(
        child: Builder(builder: (context) {
          cardContext = context;
          return const SizedBox(width: 160, height: 160);
        }),
      ),
    ));

    WaveFlight.arm(cardContext, '/now');
    expect(WaveFlight.isArmed, isFalse);

    WaveFlight.arm(cardContext, '/home');
    expect(WaveFlight.isArmed, isFalse);

    WaveFlight.arm(cardContext, '/album/abc?title=T');
    expect(WaveFlight.isArmed, isTrue);
  });

  testWidgets('refuses a rail-sized or page-sized box', (tester) async {
    late BuildContext tiny;
    late BuildContext huge;
    await tester.pumpWidget(app(
      Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Builder(builder: (c) {
            tiny = c;
            return const SizedBox(width: 20, height: 20);
          }),
          Builder(builder: (c) {
            huge = c;
            return const SizedBox(width: 540, height: 540);
          }),
        ]),
      ),
    ));

    WaveFlight.arm(tiny, '/album/abc');
    expect(WaveFlight.isArmed, isFalse);

    WaveFlight.arm(huge, '/album/abc');
    expect(WaveFlight.isArmed, isFalse);
  });

  testWidgets('destination claims its own id and flies exactly once',
      (tester) async {
    late BuildContext source;
    await tester.pumpWidget(app(
      Center(
        child: Builder(builder: (context) {
          source = context;
          return const SizedBox(width: 160, height: 160);
        }),
      ),
    ));
    WaveFlight.arm(source, '/album/right');
    expect(WaveFlight.isArmed, isTrue);

    // A header for a different album must leave the arm alone.
    await tester.pumpWidget(app(
      const WaveFlightTarget(
        key: ValueKey('wrong'),
        kind: 'album',
        id: 'wrong',
        child: SizedBox(width: 200, height: 200),
      ),
    ));
    await tester.pump();
    expect(WaveFlight.isArmed, isTrue);

    await tester.pumpWidget(app(
      const WaveFlightTarget(
        key: ValueKey('right'),
        kind: 'album',
        id: 'right',
        child: SizedBox(width: 200, height: 200),
      ),
    ));
    await tester.pump();
    expect(WaveFlight.isArmed, isFalse);

    // The overlay carries the flight while it runs, then hands back to the
    // header's own cover.
    expect(find.byType(WaveFlightTarget), findsOneWidget);
    await tester.pumpAndSettle();
    await tester.pumpWidget(app(
      const WaveFlightTarget(
        kind: 'album',
        id: 'right',
        child: SizedBox(width: 200, height: 200),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduce motion never flies', (tester) async {
    late BuildContext source;
    await tester.pumpWidget(app(
      Center(
        child: Builder(builder: (context) {
          source = context;
          return const SizedBox(width: 160, height: 160);
        }),
      ),
      reduceMotion: true,
    ));
    WaveFlight.arm(source, '/artist/Someone');
    expect(WaveFlight.isArmed, isTrue);

    await tester.pumpWidget(app(
      const WaveFlightTarget(
        kind: 'artist',
        id: 'Someone',
        radius: 84,
        child: SizedBox(width: 168, height: 168),
      ),
      reduceMotion: true,
    ));
    await tester.pumpAndSettle();
    expect(WaveFlight.isArmed, isFalse);
    expect(tester.takeException(), isNull);
  });
}
