import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/app/window_maximize.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('window_manager');
  final calls = <String>[];
  var maximized = false;

  setUp(() {
    calls.clear();
    maximized = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'isMaximized':
          return maximized;
        case 'maximize':
          calls.add('maximize');
          maximized = true;
        case 'unmaximize':
          calls.add('unmaximize');
          maximized = false;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('toggle maximizes a restored window and reports the new state',
      () async {
    final controller = WindowMaximizeController();

    await controller.toggle();

    expect(calls, ['maximize']);
    expect(controller.state, isTrue);
  });

  test('toggle restores a maximized window', () async {
    maximized = true;
    final controller = WindowMaximizeController()..sync(true);

    await controller.toggle();

    expect(calls, ['unmaximize']);
    expect(controller.state, isFalse);
  });

  test('sync mirrors native maximize changes', () {
    final controller = WindowMaximizeController();

    controller.sync(true);

    expect(controller.state, isTrue);
  });
}
