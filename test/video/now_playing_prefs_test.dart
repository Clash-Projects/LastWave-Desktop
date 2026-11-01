import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/storage/prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<Prefs> fresh([Map<String, Object> values = const {}]) async {
    SharedPreferences.setMockInitialValues(values);
    return Prefs.load();
  }

  test('auto-hide defaults to 3 seconds', () async {
    expect((await fresh()).nowPlayingAutoHideSeconds, 3);
  });

  test('auto-hide keeps 1-10 and clamps outside it', () async {
    final prefs = await fresh();
    for (final entry in {1: 1, 5: 5, 10: 10, 11: 10, 99: 10}.entries) {
      await prefs.setNowPlayingAutoHideSeconds(entry.key);
      expect(prefs.nowPlayingAutoHideSeconds, entry.value);
    }
  });

  test('0 turns auto-hide off and stays off', () async {
    final prefs = await fresh();
    await prefs.setNowPlayingAutoHideSeconds(0);
    expect(prefs.nowPlayingAutoHideSeconds, 0);
    await prefs.setNowPlayingAutoHideSeconds(-4);
    expect(prefs.nowPlayingAutoHideSeconds, 0);
  });

  test('music video on by default; quality auto and remembered', () async {
    final prefs = await fresh();
    expect(prefs.musicVideoEnabled, isTrue);
    expect(prefs.musicVideoQuality, 0);
    await prefs.setMusicVideoQuality(1080);
    await prefs.setMusicVideoEnabled(false);
    final again = Prefs(await SharedPreferences.getInstance());
    expect(again.musicVideoQuality, 1080);
    expect(again.musicVideoEnabled, isFalse);
  });
}
