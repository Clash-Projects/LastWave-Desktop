import 'dart:convert';
import 'dart:io' show HttpDate;

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
  /// Published copies of the secret dictionary. raw.githubusercontent.com
  /// is blocked on some networks (several ISPs in India among them), which
  /// made sign-in fail every time for those users; jsDelivr serves the same
  /// file from another domain.
  static const _secretsDictUrls = [
    'https://raw.githubusercontent.com/xyloflake/spot-secrets-go/refs/heads/main/secrets/secretDict.json',
    'https://cdn.jsdelivr.net/gh/xyloflake/spot-secrets-go@main/secrets/secretDict.json',
  ];

  /// Last-resort copy of the current player secrets, used only if the live
  /// player page and both remote dictionary mirrors are all unreachable.
  static final _fallbackSecrets = <SpotifySecret>[
    SpotifySecret(
      String.fromCharCodes(const [
        44, 55, 47, 42, 70, 40, 34, 114, 76, 74, 50, 111, 120,
        97, 75, 76, 94, 102, 43, 69, 49, 120, 118, 80, 64, 78,
      ]),
      61,
    ),
    SpotifySecret(
      String.fromCharCodes(const [
        79, 109, 69, 123, 90, 65, 46, 74, 94, 34, 58, 48, 70,
        71, 92, 85, 122, 63, 91, 64, 87, 87,
      ]),
      60,
    ),
    SpotifySecret(
      String.fromCharCodes(const [
        123, 105, 79, 70, 110, 59, 52, 125, 60, 49, 80, 70, 89,
        75, 80, 86, 63, 53, 123, 37, 117, 49, 52, 93, 77, 62,
        47, 86, 48, 104, 68, 72,
      ]),
      59,
    ),
  ];

  /// Secrets tried per sign-in before giving up (two requests each).
  static const _maxSecretAttempts = 4;
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

  /// Accepts `sp_dc=…; …`, a whole Cookie header, the bare value, or a row
  /// copied from the browser's cookie table (`sp_dc`, TAB, `AQ…`, TAB, domain
  /// …), which used to be stored whole and could never sign in.
  static String cleanSpDc(String raw) {
    var v = raw.trim();
    final m = RegExp(r'sp_dc\s*=\s*([^;\s]+)').firstMatch(v);
    if (m != null) {
      v = m.group(1)!;
    } else {
      final row = RegExp(r'(?:^|\s)sp_dc\s+(\S+)').firstMatch(v);
      if (row != null) v = row.group(1)!;
    }
    v = v.replaceAll('"', '').replaceAll("'", '').trim();
    // Copy-paste can drag in invisible characters (zero-width space, BOM).
    v = v.replaceAll(RegExp(r'[\s\u200B-\u200D\uFEFF]'), '');
    if (v.contains('%')) {
      try {
        v = Uri.decodeComponent(v);
      } catch (_) {}
    }
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
      final serverSeconds = await _serverSeconds(cookie);
      var sawAnswer = false;
      var tried = 0;
      // A secret Spotify has rotated away from gets an anonymous answer, so
      // one stale source used to look like a dead cookie: try the next.
      await for (final secret in _secretCandidates()) {
        if (tried++ >= _maxSecretAttempts) break;
        final totp = _totpFor(secret, serverSeconds);
        for (final reason in const ['transport', 'init']) {
          final res = await _requestPersonal(cookie, totp, reason);
          if (res == null) continue;
          sawAnswer = true;
          DiagnosticsLog.info(
            'spotify auth reason=$reason totpVer=${secret.version} '
            'anonymous=${res['isAnonymous']} '
            'tokenLen=${(res['accessToken'] as String?)?.length ?? 0}',
          );
          if (_usable(res)) {
            _storeToken(res);
            await _rememberSecret(secret);
            return SpotifySessionCheck.ok;
          }
        }
      }
      if (tried == 0) {
        DiagnosticsLog.info('spotify auth stage=otp-secret ok=false');
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

  /// Per-install anonymous device id (also the web player's `sp_t`).
  Future<String> deviceId() => _deviceId();

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

  /// Spotify's clock. Falls back to the response's `Date` header, then to
  /// the local clock: a PC whose clock is off by more than a step used to
  /// send a wrong `totpServer` whenever `server-time` failed.
  Future<int> _serverSeconds(String cookie) async {
    final headers = _webHeaders(cookie);
    try {
      final res = await _dio.get<String>(
        _serverTimeUrl,
        options: Options(
          responseType: ResponseType.plain,
          headers: headers,
          validateStatus: (_) => true,
        ),
      );
      if ((res.statusCode ?? 0) ~/ 100 == 2) {
        final body = jsonDecode(res.data ?? '{}');
        final t = body is Map ? body['serverTime'] : null;
        if (t is num) return t.toInt();
      }
      final date = res.headers.value('date');
      if (date != null) {
        return HttpDate.parse(date).millisecondsSinceEpoch ~/ 1000;
      }
    } catch (_) {
      final fallback = await SpotifyWebPlayer.curlGet(
        _serverTimeUrl,
        headers: headers,
        timeoutSeconds: 15,
      );
      if (fallback != null && fallback.status ~/ 100 == 2) {
        try {
          final body = jsonDecode(fallback.body);
          final t = body is Map ? body['serverTime'] : null;
          if (t is num) return t.toInt();
        } catch (_) {}
      }
    }
    return DateTime.now().millisecondsSinceEpoch ~/ 1000;
  }

  _Totp _totpFor(SpotifySecret secret, int serverSeconds) {
    // The secret's characters, each xor'd with ((index % 33) + 9), are
    // written out as decimal text; that text is the HMAC key.
    final keyText = StringBuffer();
    final units = secret.value.codeUnits;
    for (var i = 0; i < units.length; i++) {
      keyText.write(units[i] ^ ((i % 33) + 9));
    }
    final key = ascii.encode(keyText.toString());
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

  /// Secrets to try, best first, fetched lazily (a later source is only
  /// read when the earlier ones did not sign in): the one that last worked,
  /// what the player carries now, then the published dictionary from each
  /// mirror, newest version first. Duplicates are skipped.
  Stream<SpotifySecret> _secretCandidates() async* {
    final seen = <String>{};
    bool fresh(SpotifySecret s) => seen.add('${s.version}:${s.value}');

    final remembered = decodeStoredSecret(_prefs.spotifyOtpSecret);
    if (remembered != null && fresh(remembered)) yield remembered;

    for (final s in await SpotifyWebPlayer.playerSecrets(_dio)) {
      if (fresh(s)) yield s;
    }

    for (final url in _secretsDictUrls) {
      for (final s in await _readSecretDict(url)) {
        if (fresh(s)) yield s;
      }
    }

    for (final s in _fallbackSecrets) {
      if (fresh(s)) yield s;
    }
  }

  Future<List<SpotifySecret>> _readSecretDict(String url) async {
    try {
      final res = await _dio.get<String>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          receiveTimeout: const Duration(seconds: 15),
          validateStatus: (c) => c != null && c >= 200 && c < 300,
        ),
      );
      return parseSecretDict(res.data ?? '');
    } catch (_) {
      final fallback = await SpotifyWebPlayer.curlGet(url, timeoutSeconds: 15);
      if (fallback != null && fallback.status >= 200 && fallback.status < 300) {
        return parseSecretDict(fallback.body);
      }
      DiagnosticsLog.info(
        'spotify auth secretDict unreachable host=${Uri.parse(url).host}',
      );
      return const [];
    }
  }

  /// `{"<version>": [char codes], …}` → secrets, newest first.
  @visibleForTesting
  static List<SpotifySecret> parseSecretDict(String body) {
    try {
      final map = jsonDecode(body);
      if (map is! Map) return const [];
      final out = <SpotifySecret>[];
      for (final e in map.entries) {
        final version = int.tryParse('${e.key}');
        final cipher = e.value;
        if (version == null || cipher is! List || cipher.isEmpty) continue;
        out.add(SpotifySecret(
          String.fromCharCodes(cipher.whereType<num>().map((n) => n.toInt())),
          version,
        ));
      }
      out.sort((a, b) => b.version.compareTo(a.version));
      return out;
    } catch (_) {
      return const [];
    }
  }

  @visibleForTesting
  static SpotifySecret? decodeStoredSecret(String raw) {
    if (raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw);
      if (m is! Map) return null;
      final v = m['v'];
      final c = m['c'];
      if (v is! num || c is! List || c.isEmpty) return null;
      return SpotifySecret(
        String.fromCharCodes(c.whereType<num>().map((n) => n.toInt())),
        v.toInt(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _rememberSecret(SpotifySecret s) => _prefs.setSpotifyOtpSecret(
        jsonEncode({'v': s.version, 'c': s.value.codeUnits}),
      );

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
    final headers = _webHeaders(cookie);
    try {
      final res = await _dio.get<String>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          headers: headers,
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
    } on DioException catch (e) {
      DiagnosticsLog.info(
        'spotify auth reason=$reason dio-error=${e.type.name} '
        'err=${e.error?.runtimeType}',
      );
    } catch (e) {
      DiagnosticsLog.info('spotify auth reason=$reason err=${e.runtimeType}');
      return null;
    }
    final fallback = await SpotifyWebPlayer.curlGet(
      url,
      headers: headers,
      timeoutSeconds: 15,
    );
    if (fallback == null) return null;
    if (fallback.status ~/ 100 != 2) {
      DiagnosticsLog.info(
        'spotify auth reason=$reason via=curl http=${fallback.status}',
      );
      return null;
    }
    try {
      final body = jsonDecode(fallback.body);
      return body is Map ? Map<String, dynamic>.from(body) : null;
    } catch (e) {
      DiagnosticsLog.info(
        'spotify auth reason=$reason via=curl err=${e.runtimeType}',
      );
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
