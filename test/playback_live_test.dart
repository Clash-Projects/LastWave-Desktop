import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:lastwave_desktop/core/network/dio_factory.dart';
import 'package:lastwave_desktop/core/storage/secure_store.dart';
import 'package:lastwave_desktop/features/innertube/innertube_api.dart';

void main() {
  test('Qaafirana resolves and advances in the packaged MPV backend', () async {
    MediaKit.ensureInitialized(
      libmpv: File('build/windows/x64/runner/Release/libmpv-2.dll').absolute.path,
    );
    final tube = InnerTubeMusicApi(DioFactory.create(), SecureStore());
    final match = await tube.findBestMatchOrNull('Qaafirana', 'Arijit Singh');
    expect(match, isNotNull);
    final stream = await tube.resolveAudioStream(match!.videoId);
    expect(stream, isNotNull);
    final player = Player();
    addTearDown(player.dispose);
    await player.setVolume(0);
    final advanced = player.stream.position.firstWhere(
      (position) => position >= const Duration(seconds: 3),
    ).timeout(const Duration(seconds: 45));
    await player.open(Media(stream!.url, httpHeaders: stream.requestHeaders));
    await advanced;
    expect(player.state.duration, greaterThan(Duration.zero));
  }, skip: !Platform.isWindows || !const bool.fromEnvironment('LIVE_PLAYBACK'),
     timeout: const Timeout(Duration(minutes: 3)));
}
