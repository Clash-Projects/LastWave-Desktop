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

  /// clashflac-compatible backend base URL, e.g. https://your-backend.com
  static String get losslessBackendUrl =>
      _decode(secrets.kLosslessBackendUrl)
          .replaceAll(RegExp(r'/+$'), '');

  static String get losslessApiKey =>
      _decode(secrets.kLosslessApiKey);

  /// Tidal HiFi-API proxy (search + decrypted stream URLs).
  static String get tidalBackendUrl =>
      _decode(secrets.kBackendBUrl).replaceAll(RegExp(r'/+$'), '');

  static String get tidalApiKey => _decode(secrets.kBackendBKey);

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

  static bool get hasLosslessBackend =>
      losslessBackendUrl.isNotEmpty && losslessApiKey.isNotEmpty;

  static bool get hasTidalBackend =>
      tidalBackendUrl.isNotEmpty && tidalApiKey.isNotEmpty;

  static bool get hasAnyLosslessCatalog =>
      hasLosslessBackend || hasTidalBackend;

  /// About-screen catalog list. Never includes URLs or keys.
  static String get losslessCatalogLabel {
    final parts = <String>[
      if (hasLosslessBackend) 'Qobuz',
      if (hasTidalBackend) 'Tidal',
    ];
    return parts.isEmpty ? 'not configured' : parts.join(' · ');
  }

  /// Non-sensitive diagnostics only — never includes secret values.
  static Map<String, bool> get configuredFlags => {
        'losslessBackend': hasLosslessBackend,
        'tidalBackend': hasTidalBackend,
        'lyricsKey': lyricsApiKey.isNotEmpty,
        'lastfmOverride':
            _decode(secrets.kLastfmApiKey).isNotEmpty,
      };
}
