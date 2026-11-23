import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
