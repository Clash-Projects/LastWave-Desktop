import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/player/player_state.dart';

void main() {
  test('the picked length survives the countdown', () {
    var state = const PlayerSnapshot();
    expect(state.sleepMinutes, isNull);

    state = state.copyWith(
      sleepRemaining: const Duration(minutes: 30),
      sleepMinutes: 30,
    );
    expect(state.sleepMinutes, 30);

    // The once-a-second tick only updates the time left.
    state = state.copyWith(sleepRemaining: const Duration(minutes: 29));
    expect(state.sleepRemaining, const Duration(minutes: 29));
    expect(state.sleepMinutes, 30);
  });

  test('turning the timer off clears both', () {
    final armed = const PlayerSnapshot().copyWith(
      sleepRemaining: const Duration(minutes: 15),
      sleepMinutes: 15,
    );
    final off = armed.copyWith(clearSleep: true);
    expect(off.sleepRemaining, isNull);
    expect(off.sleepMinutes, isNull);
  });
}
