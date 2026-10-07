import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/error/fatal_crumbs.dart';

void main() {
  test('runGuarded returns body value when clean', () {
    expect(runGuarded('probe', () => 42), 42);
  });

  test('runGuarded swallows sync throws and reports them', () {
    String? reported;
    final result = runGuarded<String>(
      'probe-scope',
      () => throw StateError('boom'),
      onError: (line) => reported = line,
    );
    expect(result, isNull);
    expect(reported, contains('probe-scope'));
    expect(reported, contains('StateError'));
    expect(reported, contains('boom'));
  });

  test('runGuardedAsync swallows async throws and reports them', () async {
    String? reported;
    final result = await runGuardedAsync<String>(
      'async-scope',
      () async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        throw ArgumentError('async boom');
      },
      onError: (line) => reported = line,
    );
    expect(result, isNull);
    expect(reported, contains('async-scope'));
    expect(reported, contains('async boom'));
  });

  test('runGuardedAsync passes through clean values', () async {
    expect(await runGuardedAsync('ok', () async => 'fine'), 'fine');
  });
}
