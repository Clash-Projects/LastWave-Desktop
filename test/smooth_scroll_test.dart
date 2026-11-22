import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/design_system/fluent/lw_scrollbar.dart';

void main() {
  testWidgets('wheel notches glide as one smooth, monotonic motion',
      (tester) async {
    final controller = ScrollController();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ScrollConfiguration(
          behavior: const WaveScrollBehavior(),
          child: ListView.builder(
            controller: controller,
            itemCount: 200,
            itemExtent: 50,
            itemBuilder: (_, i) => Text('$i'),
          ),
        ),
      ),
    );

    final center = tester.getCenter(find.byType(ListView));
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    Future<void> notch() =>
        tester.sendEventToBinding(pointer.scroll(const Offset(0, 100)));

    // Three fast notches: the target stacks to 300.
    pointer.hover(center);
    await notch();
    await tester.pump(const Duration(milliseconds: 16));
    await notch();
    await tester.pump(const Duration(milliseconds: 16));
    await notch();

    final offsets = <double>[];
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      offsets.add(controller.offset);
    }
    // Never moves backwards (the old per-notch restart stalled, but the
    // glide must also never overshoot and come back).
    for (var i = 1; i < offsets.length; i++) {
      expect(offsets[i], greaterThanOrEqualTo(offsets[i - 1]));
    }
    expect(controller.offset, closeTo(300, 0.5));
  });
}
