import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/ui/navigation/route_origin.dart';

void main() {
  test('carries the point the route was opened from', () {
    WaveRouteOrigin.record(const Offset(200, 100));
    final origin = WaveRouteOrigin.consume();
    expect(origin, isNotNull);
    expect(origin!.position, const Offset(200, 100));
  });

  test('an anchor is consumed once', () {
    WaveRouteOrigin.record(const Offset(10, 10));
    expect(WaveRouteOrigin.consume(), isNotNull);
    expect(
      WaveRouteOrigin.consume(),
      isNull,
      reason: 'a second route in the same gesture must not inherit the anchor',
    );
  });

  test('a stale anchor is dropped rather than inherited', () async {
    WaveRouteOrigin.record(const Offset(10, 10));
    await Future<void>.delayed(
      WaveRouteOrigin.ttl + const Duration(milliseconds: 80),
    );
    expect(
      WaveRouteOrigin.consume(),
      isNull,
      reason: 'hotkeys / deep links must fall back to the plain crossfade',
    );
  });

  test('alignment anchors on the pressed height, centred horizontally', () {
    WaveRouteOrigin.record(const Offset(400, 300));
    final centre = WaveRouteOrigin.consume()!.alignmentIn(const Size(800, 600));
    expect(centre.x, closeTo(0, 0.001));
    expect(centre.y, closeTo(0, 0.001));

    WaveRouteOrigin.record(const Offset(1200, 900));
    final bottom = WaveRouteOrigin.consume()!.alignmentIn(const Size(800, 600));
    expect(
      bottom.x,
      0.0,
      reason: 'a horizontal anchor translates the page sideways as it scales, '
          'so the destination appeared to slide in from the side that was '
          'pressed instead of growing out of it',
    );
    expect(bottom.y, 1.0);
  });

  test('alignment clamps a press from outside the frame', () {
    WaveRouteOrigin.record(const Offset(-40, 5000));
    expect(
      WaveRouteOrigin.consume()!.alignmentIn(const Size(800, 600)),
      const Alignment(0, 1.0),
    );
  });

  test('a degenerate size falls back to centred', () {
    WaveRouteOrigin.record(const Offset(10, 10));
    expect(
      WaveRouteOrigin.consume()!.alignmentIn(Size.zero),
      Alignment.center,
    );
  });
}
