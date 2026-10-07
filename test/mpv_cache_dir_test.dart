import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/player/mpv_paths.dart';

void main() {
  test('mpv cache dir lives under the app temp dir', () {
    final path = mpvCacheDirPath();
    expect(path.endsWith('mpv-cache'), isTrue);
    expect(path.contains('lastwave'), isTrue);
  });

  test('ensureDirExists creates missing dirs and never throws', () async {
    final dir = Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}lastwave-test-cache-probe');
    if (await dir.exists()) await dir.delete(recursive: true);
    await ensureDirExists(dir.path);
    expect(await dir.exists(), isTrue);
    await ensureDirExists(dir.path); // idempotent
    await ensureDirExists('');
    await dir.delete(recursive: true);
  });
}
