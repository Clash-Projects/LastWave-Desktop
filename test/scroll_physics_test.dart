import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/design_system/fluent/lw_scrollbar.dart';

void main() {
  test('WaveScrollBehavior includes mouse and trackpad in dragDevices', () {
    const behavior = WaveScrollBehavior();
    expect(behavior.dragDevices, contains(PointerDeviceKind.mouse));
    expect(behavior.dragDevices, contains(PointerDeviceKind.trackpad));
    expect(behavior.dragDevices, contains(PointerDeviceKind.touch));
  });

  testWidgets(
      'WaveScrollBehavior returns smooth bouncy/always scrollable physics',
      (tester) async {
    const behavior = WaveScrollBehavior();
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          final physics = behavior.getScrollPhysics(context);
          expect(physics, isA<BouncingScrollPhysics>());
          expect(physics.parent, isA<AlwaysScrollableScrollPhysics>());
          return const SizedBox.shrink();
        },
      ),
    );
  });
}
