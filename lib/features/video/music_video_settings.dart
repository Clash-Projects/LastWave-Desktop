import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/prefs.dart';

/// Synced music video behind Now Playing (default on).
final musicVideoEnabledProvider =
    StateNotifierProvider<MusicVideoEnabledNotifier, bool>((ref) {
      return MusicVideoEnabledNotifier(ref.watch(prefsProvider));
    });

class MusicVideoEnabledNotifier extends StateNotifier<bool> {
  MusicVideoEnabledNotifier(this._prefs) : super(_prefs.musicVideoEnabled);
  final Prefs _prefs;

  void set(bool enabled) {
    state = enabled;
    _prefs.setMusicVideoEnabled(enabled);
  }
}

/// Preferred picture height, kept until the user changes it. 0 = Auto.
final musicVideoQualityProvider =
    StateNotifierProvider<MusicVideoQualityNotifier, int>((ref) {
      return MusicVideoQualityNotifier(ref.watch(prefsProvider));
    });

class MusicVideoQualityNotifier extends StateNotifier<int> {
  MusicVideoQualityNotifier(this._prefs) : super(_prefs.musicVideoQuality);
  final Prefs _prefs;

  void set(int height) {
    state = height;
    _prefs.setMusicVideoQuality(height);
  }
}

/// Choices offered in Settings, highest first after Auto.
const musicVideoQualityOptions = <(int, String)>[
  (0, 'Auto'),
  (2160, '2160p (4K)'),
  (1440, '1440p'),
  (1080, '1080p'),
  (720, '720p'),
  (480, '480p'),
  (360, '360p'),
];
