import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/diagnostics/diagnostics_log.dart';
import '../../core/network/dio_factory.dart';
import '../../core/storage/prefs.dart';
import '../../core/storage/secure_store.dart';
import 'spotify_web_player.dart';

/// Outcome of exchanging the stored `sp_dc` cookie for a token.
enum SpotifySessionCheck {
  /// The cookie is a signed-in session.
  ok,

  /// No cookie stored.
  missing,

  /// Spotify answered, but with a guest session or a refusal: the cookie
  /// is expired / from an ended session and must be replaced.
  refused,

  /// The exchange could not be attempted (offline, player unreadable).
  unreachable,
}

/// Spotify session: the `sp_dc` cookie plus the tokens minted from it.
///
/// Port of LastWave-Native `SpotifyAuthRepository`. Both sign-in routes
/// (system WebView and pasted cookie) end in [connectWithSpDc]; storing a
/// cookie is NOT the same as having a session, so every connect exchanges
/// it for a token before reporting success.
class SpotifyAuth extends ChangeNotifier {
  SpotifyAuth(this._store, this._prefs, {Dio? dio})
    : _dio = dio ?? DioFactory.create();

  final SecureStore _store;
  final Prefs _prefs;
  final Dio _dio;

  Dio get dio => _dio;

  static const _origin = 'https://open.spotify.com';
  static const _appVersion = '1.2.62.476.g2ad6e7f3';
  static const _clientId = 'd8a5ed958d274c2e8ee717e6a4b0971d';
  static const _clientTokenUrl =
      'https://clienttoken.spotify.com/v1/clienttoken';
  static const _serverTimeUrl = '$_origin/api/server-time';
  static const _sessionTokenUrl = '$_origin/api/token';
  static const _secretsDictUrl =
      'https://raw.githubusercontent.com/xyloflake/spot-secrets-go/refs/heads/main/secrets/secretDict.json';
  static const _clientTokenUa =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36';

  /// A real session token is long and opaque; a stub is not.
  static const _minPersonalTokenLength = 100;
  static const _graceMs = 60 * 1000;

  String? _spdc;
  bool _spdcLoaded = false;
  String? _personal;
  int _personalExp = 0;
  String? _client;
  int _clientExp = 0;
  Future<String?>? _personalInflight;
  Future<String?>? _clientInflight;

  bool _connected = false;

  /// Whether a cookie is stored (and was not found to be dead).
  bool get connected => _connected;

  /// Loads the stored cookie. Call once at startup.
  Future<void> load() async {
    _spdc = await _store.readSpotifySpDc();
    _spdcLoaded = true;
    _connected = (_spdc ?? '').isNotEmpty;
    notifyListeners();
  }

  Future<String?> spdc() async {
    if (!_spdcLoaded) await load();
    return (_spdc ?? '').isEmpty ? null : _spdc;
  }

  /// Accepts `sp_dc=…; …`, a whole Cookie header or the bare value.
  static String cleanSpDc(String raw) {
    var v = raw.trim();
    final m = RegExp(r'sp_dc=([^;\s]+)').firstMatch(v);
    if (m != null) v = m.group(1)!;
    v = v.replaceAll('"', '').replaceAll("'", '').trim();
    return v;
  }

  /// Stores [raw] and verifies it can be exchanged for a real session.
  /// A cookie Spotify refuses is dropped again, so a dead session never
  /// looks like a connected one.
  Future<SpotifySessionCheck> connectWithSpDc(String raw) async {
    final clean = cleanSpDc(raw);
    if (clean.isEmpty) return SpotifySessionCheck.missing;
    final previous = _spdc;
    _spdc = clean;
    _spdcLoaded = true;
    _personal = null;
    _personalExp = 0;
    final result = await verify();
    if (result == SpotifySessionCheck.ok) {
      await _store.writeSpotifySpDc(clean);
      _connected = true;
    } else {
      _spdc = previous;
      _connected = (previous ?? '').isNotEmpty;
      _personal = null;
      _personalExp = 0;
    }
    notifyListeners();
    return result;
  }

  Future<void> disconnect() async {
    _spdc = null;
    _personal = null;
    _personalExp = 0;
    _client = null;
    _clientExp = 0;
    _connected = false;
    await _store.writeSpotifySpDc(null);
    notifyListeners();
  }

  /// Exchanges the cookie for a token; reports what Spotify said.
  Future<SpotifySessionCheck> verify() async {
    final cookie = await spdc();
    if (cookie == null) return SpotifySessionCheck.missing;
    try {
      final totp = await _totp(cookie);
      if (totp == null) {
        DiagnosticsLog.info('spotify auth stage=otp-secret ok=false');
        return SpotifySessionCheck.unreachable;
      }
      var sawAnswer = false;
      for (final reason in const ['transport', 'init']) {
        final res = await _requestPersonal(cookie, totp, reason);
        if (res == null) continue;
        sawAnswer = true;
        DiagnosticsLog.info(
          'spotify auth reason=$reason anonymous=${res['isAnonymous']} '
          'tokenLen=${(res['accessToken'] as String?)?.length ?? 0}',
        );
        if (_usable(res)) {
          _storeToken(res);
          return SpotifySessionCheck.ok;
        }
      }
      return sawAnswer
          ? SpotifySessionCheck.refused
          : SpotifySessionCheck.unreachable;
    } catch (_) {
      return SpotifySessionCheck.unreachable;
    }
  }

  void _storeToken(Map<String, dynamic> res) {
    _personal = res['accessToken'] as String?;
    final exp = res['accessTokenExpirationTimestampMs'];
    _personalExp = exp is num
        ? exp.toInt()
        : DateTime.now().millisecondsSinceEpoch + 3600 * 1000;
  }

  static bool _usable(Map<String, dynamic> res) {
    final token = res['accessToken'];
    return token is String &&
        res['isAnonymous'] != true &&
        token.length >= _minPersonalTokenLength;
  }

  /// Active web-player access token for the signed-in account, or null.
  Future<String?> personalToken() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if ((_personal ?? '').isNotEmpty && now < _personalExp - _graceMs) {
      return Future.value(_personal);
    }
    return _personalInflight ??= _refreshPersonal().whenComplete(
      () => _personalInflight = null,
    );
  }

  Future<String?> _refreshPersonal() async {
    final cookie = await spdc();
    if (cookie == null) return null;
    final result = await verify();
    if (result == SpotifySessionCheck.refused) {
      // The stored cookie is no longer a signed-in session: say so
      // instead of caching an hour of silent failures.
      _connected = false;
      notifyListeners();
      return null;
    }
    return result == SpotifySessionCheck.ok ? _personal : null;
  }

  /// Client token (identifies the app), cached until near expiry.
  Future<String?> clientToken() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if ((_client ?? '').isNotEmpty && now < _clientExp - _graceMs) {
      return Future.value(_client);
    }
    return _clientInflight ??= _refreshClient().whenComplete(
      () => _clientInflight = null,
    );
  }

  Future<String> _deviceId() async {
    final existing = _prefs.spotifyDeviceId;
    if (existing.isNotEmpty) return existing;
    final id = const Uuid().v4();
    await _prefs.setSpotifyDeviceId(id);
    return id;
  }

  Future<String?> _refreshClient() async {
    try {
      final deviceId = await _deviceId();
      final res = await _dio.post<String>(
        _clientTokenUrl,
        data: jsonEncode({
          'client_data': {
            'client_version': _appVersion,
            'client_id': _clientId,
            'js_sdk_data': {
              'device_brand': 'Apple',
              'device_model': 'unknown',
              'os': 'macos',
              'os_version': '10.15.7',
              'device_id': deviceId,
              'device_type': 'computer',
            },
          },
        }),
        options: Options(
          responseType: ResponseType.plain,
          headers: const {
            'User-Agent': _clientTokenUa,
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          validateStatus: (_) => true,
        ),
      );
      if ((res.statusCode ?? 0) ~/ 100 != 2) return _client;
      final body = jsonDecode(res.data ?? '{}');
      final granted = body is Map ? body['granted_token'] : null;
      final token = granted is Map ? granted['token'] : null;
      if (token is String && token.isNotEmpty) {
        final ttl = granted['expires_after_seconds'];
        _client = token;
        _clientExp =
            DateTime.now().millisecondsSinceEpoch +
            ((ttl is num ? ttl.toInt() : 7200) * 1000);
        return token;
      }
    } catch (_) {}
    return _client;
  }

  // -- one-time password --------------------------------------------------

  Future<_Totp?> _totp(String cookie) async {
    final secret = await _readSecret();
    if (secret == null) return null;

    // The secret's characters, each xor'd with ((index % 33) + 9), are
    // written out as decimal text; that text is the HMAC key.
    final keyText = StringBuffer();
    final units = secret.value.codeUnits;
    for (var i = 0; i < units.length; i++) {
      keyText.write(units[i] ^ ((i % 33) + 9));
    }
    final key = ascii.encode(keyText.toString());

    var serverSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    try {
      final res = await _dio.get<String>(
        _serverTimeUrl,
        options: Options(
          responseType: ResponseType.plain,
          headers: _webHeaders(cookie),
          validateStatus: (_) => true,
        ),
      );
      if ((res.statusCode ?? 0) ~/ 100 == 2) {
        final body = jsonDecode(res.data ?? '{}');
        final t = body is Map ? body['serverTime'] : null;
        if (t is num) serverSeconds = t.toInt();
      }
    } catch (_) {}

    final clientSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return _Totp(
      otpClient: generateOtp(key, clientSeconds),
      otpServer: generateOtp(key, serverSeconds),
      version: secret.version,
    );
  }

  /// RFC 4226/6238 HMAC-SHA1 one-time password, 6 digits, 30 s step.
  @visibleForTesting
  static String generateOtp(List<int> key, int timestampSeconds) {
    final counter = timestampSeconds ~/ 30;
    final bytes = ByteData(8)..setUint64(0, counter, Endian.big);
    final mac = Hmac(sha1, key).convert(bytes.buffer.asUint8List()).bytes;
    final offset = mac.last & 0x0f;
    final binary =
        ((mac[offset] & 0x7f) << 24) |
        ((mac[offset + 1] & 0xff) << 16) |
        ((mac[offset + 2] & 0xff) << 8) |
        (mac[offset + 3] & 0xff);
    return (binary % 1000000).toString().padLeft(6, '0');
  }

  /// The secret the player is carrying now; the published copy is only a
  /// fallback because the process that updates it has stalled before.
  Future<SpotifySecret?> _readSecret() async {
    final script = await SpotifyWebPlayer.script(_dio);
    if (script != null) {
      final found = SpotifyWebPlayer.secrets(script);
      if (found.isNotEmpty) return found.first;
    }
    try {
      final res = await _dio.get<String>(
        _secretsDictUrl,
        options: Options(
          responseType: ResponseType.plain,
          validateStatus: (c) => c != null && c >= 200 && c < 300,
        ),
      );
      final map = jsonDecode(res.data ?? '{}');
      if (map is! Map || map.isEmpty) return null;
      final latest = map.keys
          .map((k) => int.tryParse('$k') ?? 0)
          .reduce((a, b) => a > b ? a : b);
      final cipher = map['$latest'];
      if (cipher is! List) return null;
      return SpotifySecret(
        String.fromCharCodes(cipher.whereType<num>().map((n) => n.toInt())),
        latest,
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, String> _webHeaders(String cookie) => {
    'User-Agent': SpotifyWebPlayer.userAgent,
    'Accept': 'application/json',
    'Cookie': 'sp_dc=$cookie',
    'App-platform': 'WebPlayer',
    'Spotify-App-Version': _appVersion,
    'Origin': _origin,
    'Referer': '$_origin/',
  };

  Future<Map<String, dynamic>?> _requestPersonal(
    String cookie,
    _Totp totp,
    String reason,
  ) async {
    final url =
        '$_sessionTokenUrl?reason=$reason&productType=web-player'
        '&totp=${totp.otpClient}&totpServer=${totp.otpServer}'
        '&totpVer=${totp.version}';
    try {
      final res = await _dio.get<String>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          headers: _webHeaders(cookie),
          validateStatus: (_) => true,
        ),
      );
      if ((res.statusCode ?? 0) ~/ 100 != 2) {
        DiagnosticsLog.info(
          'spotify auth reason=$reason http=${res.statusCode}',
        );
        return null;
      }
      final body = jsonDecode(res.data ?? '{}');
      return body is Map ? Map<String, dynamic>.from(body) : null;
    } catch (_) {
      return null;
    }
  }
}

class _Totp {
  final String otpClient;
  final String otpServer;
  final int version;
  const _Totp({
    required this.otpClient,
    required this.otpServer,
    required this.version,
  });
}

/// App-scoped Spotify session. [SpotifyAuth.load] is kicked off lazily.
final spotifyAuthProvider = ChangeNotifierProvider<SpotifyAuth>((ref) {
  final auth = SpotifyAuth(
    ref.watch(secureStoreProvider),
    ref.watch(prefsProvider),
  );
  auth.load();
  return auth;
});
