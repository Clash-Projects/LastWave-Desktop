import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/artwork/animated_artwork_session.dart';
import 'package:lastwave_desktop/core/storage/prefs.dart';
import 'package:lastwave_desktop/features/performance/performance_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences sp;
  late Prefs prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    sp = await SharedPreferences.getInstance();
    prefs = Prefs(sp);
  });

  test('PerformanceController toggles and persists state', () {
    final container = ProviderContainer(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
      ],
    );

    expect(container.read(performanceModeProvider), isFalse);
    expect(prefs.performanceMode, isFalse);

    // Toggle ON
    container.read(performanceModeProvider.notifier).toggle();
    expect(container.read(performanceModeProvider), isTrue);
    expect(prefs.performanceMode, isTrue);

    // Toggle OFF
    container.read(performanceModeProvider.notifier).toggle();
    expect(container.read(performanceModeProvider), isFalse);
    expect(prefs.performanceMode, isFalse);
  });

  test('performanceOptimizationsProvider reflects state correctly', () {
    final container = ProviderContainer(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
      ],
    );

    // Initially OFF
    var opts = container.read(performanceOptimizationsProvider);
    expect(opts.length, equals(5));
    expect(opts.every((o) => !o.active), isTrue);

    // Turn ON
    container.read(performanceModeProvider.notifier).setPerformanceMode(true);
    opts = container.read(performanceOptimizationsProvider);
    expect(opts.every((o) => o.active), isTrue);
    expect(opts.first.title, equals('Glass Blur & Shaders'));
    expect(opts.first.subtitle, contains('Zero GPU lag'));
  });

  test('hardware detection provides boolean value safely', () {
    final container = ProviderContainer(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
      ],
    );

    final isModest = container.read(isModestHardwareProvider);
    expect(isModest, isA<bool>());
  });

  test('Performance Mode gates AnimatedArtworkSession without touching libmpv',
      () async {
    await prefs.setPerformanceMode(true);
    final container = ProviderContainer(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
      ],
    );
    addTearDown(container.dispose);

    final session = container.read(animatedArtworkSessionProvider);
    // Attaching or opening while Performance Mode is active must not allocate
    // a native player or mark a clip ready.
    session.attach('https://example.com/canvas.mp4');
    await session.open('https://example.com/canvas.mp4');
    expect(session.controller, isNull);
    expect(session.ready, isFalse);

    // Turning Performance Mode ON mid-session clears readiness without throwing.
    container.read(performanceModeProvider.notifier).setPerformanceMode(false);
    container.read(performanceModeProvider.notifier).setPerformanceMode(true);
    expect(session.ready, isFalse);
  });
}
