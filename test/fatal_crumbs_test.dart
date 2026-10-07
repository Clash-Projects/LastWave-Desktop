import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/error/fatal_crumbs.dart';

void main() {
  test('fatal crumb carries type and single-line message', () {
    final line = fatalCrumb(StateError('bad state here'));
    expect(line.startsWith('FATAL StateError: '), isTrue);
    expect(line, contains('bad state here'));
    expect(line.contains('\n'), isFalse);
  });

  test('fatal crumb bounds long messages and notes the app frame', () {
    final long = List.filled(600, 'x').join();
    final stack = StackTrace.fromString(
        '#0 main (dart:async)\n#1 playback (package:lastwave_desktop/foo.dart:1:2)');
    final line = fatalCrumb(ArgumentError(long), stack);
    expect(line.length, lessThan(700));
    expect(line.endsWith('... @ #1 playback (package:lastwave_desktop/foo.dart:1:2)'),
        isTrue);
  });

  test('fatal crumb without stack has no frame suffix', () {
    expect(fatalCrumb('plain string').endsWith('@'), isFalse);
  });
}
