import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/ui/settings/diagnostics_actions.dart';

void main() {
  test('Windows 11 builds are labelled Windows 11', () {
    expect(
      windowsVersionLabel('"Windows 10 Home Single Language" 10.0 (Build 26300)'),
      '"Windows 11 Home Single Language" 10.0 (Build 26300)',
    );
    expect(
      windowsVersionLabel('"Windows 10 Pro" 10.0 (Build 19045)'),
      '"Windows 10 Pro" 10.0 (Build 19045)',
    );
    expect(windowsVersionLabel('Linux 6.9'), 'Linux 6.9');
  });
}
