import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/lyrics/lyric_clock_controller.dart';
import 'package:lastwave_desktop/features/lyrics/lyric_texture_cache.dart';

class _FakeImage implements ui.Image {
  @override
  int get width => 100;
  @override
  int get height => 50;
  @override
  void dispose() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('LyricClockController stops ticker during gaps > 80ms and wakes up', (tester) async {
    final fakeImg = _FakeImage();
    final baked = BakedLyricLine(
      lineIndex: 0,
      logicalSize: const Size(200, 40),
      rowHeight: 40,
      dpr: 1.0,
      activeSharpImage: fakeImg,
      inactiveBlurredImage: fakeImg,
      words: const [
        BakedWordBox(startMs: 1000, endMs: 2000, x0: 0, x1: 50, rowIndex: 0),
        // 500ms gap here (> 80ms)
        BakedWordBox(startMs: 2500, endMs: 3500, x0: 55, x1: 100, rowIndex: 0),
      ],
    );

    late LyricClockController controller;

    await tester.pumpWidget(
      TestVsycWidget(
        onCreated: (vsync) {
          controller = LyricClockController(vsync: vsync);
        },
      ),
    );

    controller.setActiveBakedLine(baked);

    // Initial position at 0 ms (gap before word 0 is 1000ms > 80ms)
    controller.syncPlayback(isPlaying: true, isVisible: true, audioMs: 0);

    // Should stop ticker and schedule timer for gap
    expect(controller.isTickerActive, isFalse);

    // Sync to active word 1 (1500 ms)
    controller.syncPlayback(isPlaying: true, isVisible: true, audioMs: 1500);
    // At active singing, ticker should be running
    expect(controller.isTickerActive, isTrue);

    // Position advances to 50% through word 1:
    expect(controller.sweepNotifier.value.sweepXLogical, greaterThan(20.0));
    expect(controller.sweepNotifier.value.sweepXLogical, lessThan(30.0));

    controller.dispose();
  });
}

class TestVsycWidget extends StatefulWidget {
  final void Function(TickerProvider vsync) onCreated;
  const TestVsycWidget({super.key, required this.onCreated});

  @override
  State<TestVsycWidget> createState() => _TestVsycWidgetState();
}

class _TestVsycWidgetState extends State<TestVsycWidget>
    with SingleTickerProviderStateMixin {
  @override
  void initState() {
    super.initState();
    widget.onCreated(this);
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}
