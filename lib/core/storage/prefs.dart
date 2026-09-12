import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Settings + session persistence.
///
/// Key names mirror LastWave-native `SettingsPreferences` /
/// `SessionPreferences` (`lw_*`) so behaviour stays comparable.
class Prefs {
  final SharedPreferences _sp;
  Prefs(this._sp);

  static Future<Prefs> load() async =>
      Prefs(await SharedPreferences.getInstance());

  // -- Last.fm session (OAuth only; API keys come from .env) --------------
  String get sessionKey => _sp.getString('lw_sessionkey') ?? '';
  String get username => _sp.getString('lw_username') ?? '';
  bool get guestMode => _sp.getBool('lw_guest_mode') ?? false;
  bool get isAuthenticated =>
      username.isNotEmpty && !_isGuestSession;

  bool get _isGuestSession =>
      guestMode || sessionKey.isEmpty && username.isEmpty;

  Future<void> saveSession({
    required String sessionKey,
    required String username,
  }) async {
    await _sp.setString('lw_sessionkey', sessionKey);
    await _sp.setString('lw_username', username);
    await _sp.setBool('lw_guest_mode', false);
  }

  Future<void> signOut() async {
    await _sp.remove('lw_sessionkey');
    await _sp.remove('lw_username');
    await _sp.setBool('lw_guest_mode', true);
  }

  // -- Audio quality (mirrors Android quality tiers) ---------------------
  /// -1 = YouTube only, 5 = 320k MP3, 6 = 16/44.1 FLAC,
  /// 7 = 24/96, 27 = 24/192.
  static const allowedQualities = [-1, 5, 6, 7, 27];

  bool get preferLossless =>
      _sp.getBool('lw_prefer_lossless_streaming') ?? true;
  int get losslessQuality => _clampQuality(
      _sp.getInt('lw_lossless_quality') ?? 27);
  int get downloadQuality => _clampQuality(
      _sp.getInt('lw_download_quality') ?? 27);

  static int _clampQuality(int q) =>
      allowedQualities.contains(q) ? q : 27;

  Future<void> setPreferLossless(bool v) =>
      _sp.setBool('lw_prefer_lossless_streaming', v);
  Future<void> setLosslessQuality(int q) =>
      _sp.setInt('lw_lossless_quality', _clampQuality(q));
  Future<void> setDownloadQuality(int q) =>
      _sp.setInt('lw_download_quality', _clampQuality(q));

  // -- Playback behaviour -------------------------------------------------
  bool get crossfadeEnabled =>
      _sp.getBool('lw_crossfade_enabled') ?? false;
  int get crossfadeSeconds {
    final v = _sp.getInt('lw_crossfade_seconds') ?? 5;
    return v.clamp(1, 12);
  }

  Future<void> setCrossfade(bool enabled, [int? seconds]) async {
    await _sp.setBool('lw_crossfade_enabled', enabled);
    if (seconds != null) {
      await _sp.setInt('lw_crossfade_seconds', seconds.clamp(1, 12));
    }
  }

  bool get bitPerfect => _sp.getBool('lw_bit_perfect') ?? false;
  Future<void> setBitPerfect(bool v) =>
      _sp.setBool('lw_bit_perfect', v);

  bool get downloadLyrics => _sp.getBool('lw_download_lyrics') ?? true;
  Future<void> setDownloadLyrics(bool v) =>
      _sp.setBool('lw_download_lyrics', v);

  // -- Lyrics --------------------------------------------------------------
  bool get wordByWord => _sp.getBool('lw_word_by_word') ?? true;
  Future<void> setWordByWord(bool v) =>
      _sp.setBool('lw_word_by_word', v);

  String get lyricsAnimation =>
      _sp.getString('lw_lyrics_animation') ?? 'apple_fluid';
  Future<void> setLyricsAnimation(String v) =>
      _sp.setString('lw_lyrics_animation', v);

  // -- Appearance ------------------------------------------------------------
  bool get amoled => _sp.getBool('lw_amoled') ?? false;
  Future<void> setAmoled(bool v) => _sp.setBool('lw_amoled', v);

  String get accentMode => _sp.getString('lw_accent_mode') ?? 'manual';
  Future<void> setAccentMode(String v) =>
      _sp.setString('lw_accent_mode', v);

  int get accentColor => _sp.getInt('lw_accent') ?? 0xFFE03030;
  Future<void> setAccentColor(int v) => _sp.setInt('lw_accent', v);

  bool get dynamicNowPlaying =>
      _sp.getBool('lw_dynamic_now_playing') ?? false;
  Future<void> setDynamicNowPlaying(bool v) =>
      _sp.setBool('lw_dynamic_now_playing', v);

  bool get liquidGlass => _sp.getBool('lw_liquid_glass') ?? false;
  Future<void> setLiquidGlass(bool v) =>
      _sp.setBool('lw_liquid_glass', v);

  bool get wavySeekbar => _sp.getBool('lw_wavy_seekbar') ?? true;
  Future<void> setWavySeekbar(bool v) =>
      _sp.setBool('lw_wavy_seekbar', v);

  // -- Scrobbler --------------------------------------------------------------
  bool get scrobblerEnabled =>
      _sp.getBool('lw_scrobbler_enabled') ?? false;
  bool get scrobbleNowPlaying =>
      _sp.getBool('lw_submit_now_playing') ?? true;
  int get scrobblePercent {
    final v = _sp.getInt('lw_scrobble_percent') ?? 50;
    return v.clamp(25, 90);
  }

  Future<void> setScrobbler({
    bool? enabled,
    bool? nowPlaying,
    int? percent,
  }) async {
    if (enabled != null) {
      await _sp.setBool('lw_scrobbler_enabled', enabled);
    }
    if (nowPlaying != null) {
      await _sp.setBool('lw_submit_now_playing', nowPlaying);
    }
    if (percent != null) {
      await _sp.setInt('lw_scrobble_percent', percent.clamp(25, 90));
    }
  }
}

final prefsProvider = Provider<Prefs>((_) {
  throw UnimplementedError('Prefs not initialised — override in main()');
});
