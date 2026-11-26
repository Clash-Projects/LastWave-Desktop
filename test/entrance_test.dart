import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/ui/theme/motion.dart';

/// Entrances are one-shot: the group's staggered cascade runs when content
/// mounts and nothing that rebuilds afterwards may replay it.
///
/// This is the regression behind the side rail blinking its first six labels
/// on every expand/collapse: toggling clears the rail's row cache, those rows
/// rebuild *after* the cascade, and a group that had dropped its timeline left
/// them falling back to standalone entrances — which remount the row at
/// opacity 0 and fade it back in. Rows past the standalone cap (`index >= 6`,
/// Playlists / Downloads / Friends / Settings) never animated, which is exactly
/// the split that was reported.
void main() {
  Widget host(Widget child) => FluentApp(home: child);

  Finder fadedRows() => find.ancestor(
        of: find.text('Home'),
        matching: find.byType(Opacity),
      );

  testWidgets('the cascade still fades content on mount', (tester) async {
    await tester.pumpWidget(
      host(
        WaveEntranceGroup(
          child: WaveEntrance(index: 0, child: const Text('Home')),
        ),
      ),
    );

    final faded = tester.widgetList<Opacity>(fadedRows());
    expect(faded.any((o) => o.opacity < 1.0), isTrue);

    await tester.pumpAndSettle();
    expect(
      tester.widgetList<Opacity>(fadedRows()).where((o) => o.opacity < 1.0),
      isEmpty,
    );
  });

  testWidgets('a rebuild after the cascade does not replay the fade',
      (tester) async {
    late StateSetter rebuild;
    await tester.pumpWidget(
      host(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return WaveEntranceGroup(
              child: WaveEntrance(index: 0, child: const Text('Home')),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    // A finished cascade hands its children back untouched.
    expect(
      find.ancestor(
        of: find.text('Home'),
        matching: find.byType(TweenAnimationBuilder<double>),
      ),
      findsNothing,
    );

    rebuild(() {});
    await tester.pump();

    // The rebuild used to swap the row onto the standalone entrance, which
    // remounted it at opacity 0 and faded it back in.
    expect(
      find.ancestor(
        of: find.text('Home'),
        matching: find.byType(TweenAnimationBuilder<double>),
      ),
      findsNothing,
    );
    expect(
      tester.widgetList<Opacity>(fadedRows()).where((o) => o.opacity < 1.0),
      isEmpty,
    );
  });

  testWidgets('the entering child keeps its state through the fade',
      (tester) async {
    await tester.pumpWidget(
      host(
        WaveEntranceGroup(
          child: WaveEntrance(index: 0, child: const _Probe()),
        ),
      ),
    );
    final first = tester.state(find.byType(_Probe));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pumpAndSettle();
    // Same State object: the wrapper never changed shape, so no remount.
    expect(identical(tester.state(find.byType(_Probe)), first), isTrue);
  });

  testWidgets('a group staggers later sections without delaying the first',
      (tester) async {
    double opacityOf(String label) => tester.widgetList<Opacity>(find.ancestor(
          of: find.text(label),
          matching: find.byType(Opacity),
        )).first.opacity;

    await tester.pumpWidget(host(
      const WaveEntranceGroup(
        child: Column(
          children: [
            WaveEntrance(child: Text('First')),
            WaveEntrance(index: 2, child: Text('Middle')),
            WaveEntrance(index: 4, child: Text('Last')),
          ],
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 75));
    expect(opacityOf('First'), greaterThan(opacityOf('Middle')));
    expect(opacityOf('Middle'), greaterThan(0));
    expect(opacityOf('Last'), 0);

    await tester.pumpAndSettle();
    expect(opacityOf('Last'), 1);
  });
}

class _Probe extends StatefulWidget {
  const _Probe();
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  Widget build(BuildContext context) => const Text('Home');
}

