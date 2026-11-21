import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/updates/update_service.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('lw_appimage'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('the update replaces the launched AppImage at the same path', () async {
    final current = File(p.join(dir.path, 'LastWave.AppImage'))
      ..writeAsStringSync('old');
    final downloaded = File(p.join(dir.path, 'lastwave_2.2.0_x86_64.AppImage'))
      ..writeAsStringSync('new');

    final ok = await replaceAppImageInPlace(
      downloaded: downloaded.path,
      current: current.path,
    );

    expect(ok, isTrue);
    expect(current.readAsStringSync(), 'new');
    expect(downloaded.existsSync(), isFalse);
    expect(File('${current.path}.update').existsSync(), isFalse);
  });

  test('an unwritable target leaves everything as it was', () async {
    final downloaded = File(p.join(dir.path, 'new.AppImage'))
      ..writeAsStringSync('new');
    final ok = await replaceAppImageInPlace(
      downloaded: downloaded.path,
      current: p.join(dir.path, 'missing-dir', 'LastWave.AppImage'),
    );
    expect(ok, isFalse);
    expect(downloaded.existsSync(), isTrue);
  });
}
