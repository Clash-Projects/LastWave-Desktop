import 'package:fluent_ui/fluent_ui.dart';
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
}
