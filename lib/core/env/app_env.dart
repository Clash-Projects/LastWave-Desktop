import 'dart:convert';

import 'secrets.g.dart' as secrets;

/// Environment configuration.
///
/// Secrets are baked in at build time as XOR-obfuscated byte arrays
/// (`dart tool/obfuscate_secrets.dart` reads the gitignored `.env`
/// and generates `secrets.g.dart`), mirroring LastWave-native's
/// `obfuscateSecret()` / `decodeSecretBytes` scheme with the same
/// mask. They are decoded only in memory at runtime — every user of
/// the app gets lossless/lyrics/Last.fm access with no keys of
/// their own, and no plaintext secret ships in the binary.
///
/// Secrets are never logged (see [configuredFlags], booleans only).
class AppEnv {
  AppEnv._();

  /// Same mask as LastWave-native `SECRET_MASK`.
  static const _mask = [0x5A, 0x3F, 0x7E, 0x1B, 0x92, 0x4C, 0xA1, 0x6D];

  static String _decode(List<int> data) {
    if (data.isEmpty) return '';
    final bytes = List<int>.generate(
      data.length,
      (i) => data[i] ^ _mask[i % _mask.length],
    );
    try {
      return utf8.decode(bytes).trim();
    } catch (_) {
      return '';
    }
  }

  /// Addon one-way-lock secret (HMAC-SHA256 request proofs). Baked in
  /// like the other keys: never logged, never sent except as a keyed
  /// proof. Empty = addon calls fail closed server-side (404).
  static String get addonClientSecret =>
      _decode(secrets.kAddonClientSecret);

  static String get lyricsApiKey =>
      _decode(secrets.kLyricsApiKey);

  /// Last.fm app credentials — ONLY from `.env` (obfuscated at build
  /// time). No hardcoded keys anywhere in source: if `.env` lacks
  /// them, Last.fm features report "not configured" instead.
  static String get lastfmApiKey => _decode(secrets.kLastfmApiKey);

  static String get lastfmApiSecret =>
      _decode(secrets.kLastfmApiSecret);

  static bool get isLastFmConfigured =>
      lastfmApiKey.isNotEmpty && lastfmApiSecret.isNotEmpty;

  /// About-screen catalog list. Never includes URLs or keys.
  /// (Settings → Sources) are the only lossless catalog now.
  static String get losslessCatalogLabel => 'Addons';

  /// Non-sensitive diagnostics only — never includes secret values.
  static Map<String, bool> get configuredFlags => {
        'addonKey': addonClientSecret.isNotEmpty,
        'lyricsKey': lyricsApiKey.isNotEmpty,
        'lastfmOverride':
            _decode(secrets.kLastfmApiKey).isNotEmpty,
      };
}
