import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/ui/app_shell/branch_switcher.dart';

/// Branch child that survives a switch only if its element is kept alive —
/// the whole point of the container.
class _KeepAlive extends StatefulWidget {
  const _KeepAlive(this.label);
  final String label;

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive> {
  int taps = 0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => setState(() => taps++),
      child: Text('${widget.label}:$taps'),
    );
  }
}

Widget _host(int index, {bool reducedMotion = false}) {
  return FluentApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reducedMotion),
      child: WaveBranchSwitcher(
        currentIndex: index,
        children: const [_KeepAlive('a'), _KeepAlive('b')],
      ),
    ),
  );
}

void main() {
  testWidgets('settles on the active branch only', (tester) async {
    await tester.pumpWidget(_host(0));
    expect(find.text('a:0'), findsOneWidget);
    expect(find.text('b:0'), findsNothing,
        reason: 'inactive branches stay offstage');
  });

  testWidgets('fades the incoming branch under the outgoing one',
      (tester) async {
    await tester.pumpWidget(_host(0));
    await tester.pumpWidget(_host(1));
    await tester.pump();

    // Mid-flight both branches are painted, the incoming one not yet opaque.
    final mid = tester.widget<Opacity>(
      find
          .ancestor(of: find.text('b:0'), matching: find.byType(Opacity))
          .first,
    );
    expect(mid.opacity, lessThan(1.0));
    expect(find.text('a:0'), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.text('b:0'), findsOneWidget);
    expect(find.text('a:0'), findsNothing);
  });

  testWidgets('keeps branch state across a switch', (tester) async {
    await tester.pumpWidget(_host(0));
    await tester.tap(find.text('a:0'));
    await tester.pump();
    expect(find.text('a:1'), findsOneWidget);

    await tester.pumpWidget(_host(1));
    await tester.pumpAndSettle();
    expect(find.text('a:1'), findsNothing);

    await tester.pumpWidget(_host(0));
    await tester.pumpAndSettle();
    expect(find.text('a:1'), findsOneWidget,
        reason: 'wrapper shape must not change between frames, or the branch '
            'element is rebuilt and its state is lost');
  });

  testWidgets('reduce motion switches instantly', (tester) async {
    await tester.pumpWidget(_host(0, reducedMotion: true));
    await tester.pumpWidget(_host(1, reducedMotion: true));
    expect(find.text('b:0'), findsOneWidget);
    expect(find.text('a:0'), findsNothing);
  });
}
