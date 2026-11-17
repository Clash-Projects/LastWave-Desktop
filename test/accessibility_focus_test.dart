import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/app/accessibility.dart';

Widget _page(FocusNode a, FocusNode b) => FluentApp(
      home: Column(
        children: [
          Button(focusNode: a, onPressed: () {}, child: const Text('First')),
          Button(focusNode: b, onPressed: () {}, child: const Text('Second')),
        ],
      ),
    );

void main() {
  setUp(() => AppFocusMemory.instance.start());

  testWidgets('returning to the window puts focus back on the last control',
      (tester) async {
    final a = FocusNode();
    final b = FocusNode();
    await tester.pumpWidget(_page(a, b));
    b.requestFocus();
    await tester.pump();

    // The window went to the background and focus was dropped.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(b.hasFocus, isFalse);

    AppFocusMemory.instance.restore();
    await tester.pump();
    await tester.pump();
    expect(b.hasPrimaryFocus, isTrue);
  });

  testWidgets('with no remembered control the first control takes focus',
      (tester) async {
    final a = FocusNode();
    final b = FocusNode();
    await tester.pumpWidget(_page(a, b));
    AppFocusMemory.instance.restore();
    await tester.pump();
    await tester.pump();
    expect(a.hasPrimaryFocus, isTrue);
  });

  testWidgets('unmounting the focused subtree during restore does not throw',
      (tester) async {
    final oldControl = FocusNode();
    final miniControl = FocusNode();
    final deadScope = FocusScopeNode();
    addTearDown(() {
      oldControl.dispose();
      miniControl.dispose();
      deadScope.dispose();
    });

    await tester.pumpWidget(
      FluentApp(
        home: Column(
          children: [
            FocusScope(
              node: deadScope,
              autofocus: true,
              child: Button(
                focusNode: oldControl,
                onPressed: () {},
                child: const Text('Shell'),
              ),
            ),
            Button(
              focusNode: miniControl,
              onPressed: () {},
              child: const Text('Mini'),
            ),
          ],
        ),
      ),
    );
    oldControl.requestFocus();
    await tester.pump();
    expect(oldControl.hasPrimaryFocus, isTrue);

    // Queue restore while deadScope / oldControl still hold focus, then unmount
    // deadScope before the post-frame restore runs (mirrors shell -> mini swap).
    AppFocusMemory.instance.restore();
    await tester.pumpWidget(
      FluentApp(
        home: Button(
          focusNode: miniControl,
          onPressed: () {},
          child: const Text('Mini'),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(miniControl.hasPrimaryFocus, isTrue);
  });

  testWidgets('restore & announce ignore deactivated ancestor contexts',
      (tester) async {
    final outerBtn = FocusNode();
    final innerScope = FocusScopeNode();
    late BuildContext capturedContext;
    var showInner = true;
    late void Function(VoidCallback) setHostState;
    addTearDown(() {
      outerBtn.dispose();
      innerScope.dispose();
    });

    await tester.pumpWidget(
      FluentApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            setHostState = setState;
            return Column(
              children: [
                Button(
                  focusNode: outerBtn,
                  onPressed: () {},
                  child: const Text('Outer'),
                ),
                if (showInner)
                  FocusScope(
                    node: innerScope,
                    autofocus: true,
                    child: Builder(
                      builder: (ctx) {
                        capturedContext = ctx;
                        return const SizedBox.shrink();
                      },
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
    innerScope.requestFocus();
    await tester.pump();

    // Schedule unmounting innerScope in a post-frame callback that fires after
    // restore() has already read primaryFocus as innerScope, or right before
    // restore()'s post-frame runs.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      setHostState(() => showInner = false);
    });
    AppFocusMemory.instance.restore();
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(() => AppAccessibility.announce(capturedContext, 'hi'),
        returnsNormally);
  });
}
