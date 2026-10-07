import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/addons/dash_assembler.dart';

Dio _hangingDio({int delayMs = 300}) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) async {
        await Future<void>.delayed(Duration(milliseconds: delayMs));
        handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: [1, 2, 3]));
      },
    ),
  );
  return dio;
}

void main() {
  test('segment fetch honors a total deadline instead of wedging', () async {
    final got = <int>[];
    final sw = Stopwatch()..start();
    final ok = await DashAssembler.fetchSegments(
      _hangingDio(),
      mediaTemplate: 'https://cdn.example/seg-\$Number\$.m4s',
      startNumber: 0,
      count: 50,
      onSegment: (i, bytes) => got.add(i),
      totalTimeout: const Duration(milliseconds: 150),
    );
    sw.stop();
    expect(ok, isFalse);
    // 50 segments x 300ms would take 15s sequential; the deadline
    // must cut it short so the caller falls back instead of wedging.
    expect(sw.elapsedMilliseconds, lessThan(5000));
  });

  test('healthy fetch still completes under a generous deadline',
      () async {
    final got = <int>[];
    final ok = await DashAssembler.fetchSegments(
      _hangingDio(delayMs: 10),
      mediaTemplate: 'https://cdn.example/seg-\$Number\$.m4s',
      startNumber: 0,
      count: 4,
      onSegment: (i, bytes) => got.add(i),
      totalTimeout: const Duration(seconds: 20),
    );
    expect(ok, isTrue);
    expect(got.length, 4);
  });
}


