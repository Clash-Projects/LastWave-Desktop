import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:synchronized/synchronized.dart';
import 'package:uuid/uuid.dart';

import '../../core/storage/secure_store.dart';
import 'spotify_web_player.dart';

/// Spotify web-player session keyed by an `sp_dc` cookie.
///
/// The cookie and the short-lived tokens stay in [SecureStore]. Playback
/// does not depend on this object: a missing session just returns null.
class SpotifySession {
  SpotifySession(this._store);

  final SecureStore _store;
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 20),
      headers: {
        'User-Agent': _userAgent,
        'Accept': 'application/json',
      },
    ),
  );
  final _clientLock = Lock();
  final _personalLock = Lock();

  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
  static const _clientUa =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36';
  static const _origin = 'https://open.spotify.com';
  static const _appVersion = '1.2.62.476.g2ad6e7f3';
  static const _clientId = 'd8a5ed958d274c2e8ee717e6a4b0971d';
  static const _graceMs = 60000;
  static const _minTokenLength = 100;

  Future<bool> hasSession() async {
    final sp = await _spDc();
    return sp != null && sp.isNotEmpty;
  }

  Future<void> saveSpDc(String raw) async {
    final clean = cleanSpDc(raw);
    if (clean.isEmpty) return;
    final blob = await _read();
    blob['sp_dc'] = clean;
    blob.remove('personal_token');
    blob.remove('personal_expires');
    await _write(blob);
  }

  Future<void> clear() => _store.writeSpotifySession(null);

  Future<String?> clientToken() => _clientLock.synchronized(() async {
        final blob = await _read();
        final cached = blob['client_token'] as String?;
        final expires = _asInt(blob['client_expires']);
        final now = DateTime.now().millisecondsSinceEpoch;
        if (cached != null &&
            cached.isNotEmpty &&
            now < expires - _graceMs) {
          return cached;
        }
        try {
          final deviceId = await _deviceId(blob);
          final body = {
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
          };
          final res = await _dio.post<dynamic>(
            'https://clienttoken.spotify.com/v1/clienttoken',
            data: body,
            options: Options(headers: {
              'User-Agent': _clientUa,
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            }),
          );
          final map = res.data;
          if (map is Map) {
            final granted = map['granted_token'];
            if (granted is Map) {
              final token = granted['token']?.toString() ?? '';
              if (token.isNotEmpty) {
                final seconds =
                    _asInt(granted['expires_after_seconds'], fallback: 7200);
                blob['client_token'] = token;
                blob['client_expires'] = now + seconds * 1000;
                await _write(blob);
                return token;
              }
            }
          }
        } catch (_) {}
        return cached;
      });

  Future<String?> personalToken() => _personalLock.synchronized(() async {
        final blob = await _read();
        final spdc = blob['sp_dc'] as String?;
        if (spdc == null || spdc.isEmpty) return null;
        final cached = blob['personal_token'] as String?;
        final expires = _asInt(blob['personal_expires']);
        final now = DateTime.now().millisecondsSinceEpoch;
        if (cached != null &&
            cached.isNotEmpty &&
            now < expires - _graceMs) {
          return cached;
        }
        try {
          final totp = await _totp(spdc);
          if (totp == null) return cached;
          final transport = await _requestToken(spdc, totp, 'transport');
          final init = _usable(transport)
              ? null
              : await _requestToken(spdc, totp, 'init');
          final chosen = _usable(transport)
              ? transport
              : (_usable(init) ? init : null);
          if (chosen == null) return cached;
          final token = chosen['accessToken']?.toString() ?? '';
          final exp = _asInt(
            chosen['accessTokenExpirationTimestampMs'],
            fallback: now + 3600000,
          );
          blob['personal_token'] = token;
          blob['personal_expires'] = exp;
          await _write(blob);
          return token;
        } catch (_) {
          return cached;
        }
      });

  bool _usable(Map<String, dynamic>? response) {
    if (response == null) return false;
    if (response['isAnonymous'] == true) return false;
    final token = response['accessToken']?.toString() ?? '';
    return token.length >= _minTokenLength;
  }

  Future<Map<String, dynamic>?> _requestToken(
    String spdc,
    _Totp totp,
    String reason,
  ) async {
    final url = '$_origin/api/token?reason=$reason&productType=web-player'
        '&totp=${totp.client}&totpServer=${totp.server}&totpVer=${totp.version}';
    try {
      final res = await _dio.get<dynamic>(
        url,
        options: Options(headers: {
          'User-Agent': _userAgent,
          'Accept': 'application/json',
          'Cookie': 'sp_dc=$spdc',
          'App-platform': 'WebPlayer',
          'Spotify-App-Version': _appVersion,
          'Origin': _origin,
          'Referer': '$_origin/',
        }),
      );
      final data = res.data;
      if (data is Map) {
        return data.map((k, v) => MapEntry(k.toString(), v));
      }
    } catch (_) {}
    return null;
  }

  Future<_Totp?> _totp(String spdc) async {
    final secret = await SpotifyWebPlayer.secret(_dio);
    if (secret == null) return null;
    final codes = secret.value.codeUnits;
    final buffer = StringBuffer();
    for (var i = 0; i < codes.length; i++) {
      final decoded = codes[i] ^ ((i % 33) + 9);
      buffer.write(decoded);
    }
    final key = ascii.encode(buffer.toString());
    final server = await _serverTime(spdc);
    final client = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return _Totp(
      client: _otp(key, client),
      server: _otp(key, server),
      version: secret.version,
    );
  }

  Future<int> _serverTime(String spdc) async {
    try {
      final res = await _dio.get<dynamic>(
        '$_origin/api/server-time',
        options: Options(headers: {
          'User-Agent': _userAgent,
          'Cookie': 'sp_dc=$spdc',
          'App-platform': 'WebPlayer',
          'Spotify-App-Version': _appVersion,
          'Origin': _origin,
          'Referer': '$_origin/',
          'Accept': 'application/json',
        }),
      );
      final data = res.data;
      if (data is Map && data['serverTime'] != null) {
        return _asInt(data['serverTime']);
      }
    } catch (_) {}
    return DateTime.now().millisecondsSinceEpoch ~/ 1000;
  }

  String _otp(List<int> secret, int timestampSeconds) {
    final counter = timestampSeconds ~/ 30;
    final bytes = List<int>.filled(8, 0);
    var value = counter;
    for (var i = 7; i >= 0; i--) {
      bytes[i] = value & 0xff;
      value >>= 8;
    }
    final digest = Hmac(sha1, secret).convert(bytes).bytes;
    final offset = digest.last & 0x0f;
    final binary = ((digest[offset] & 0x7f) << 24) |
        ((digest[offset + 1] & 0xff) << 16) |
        ((digest[offset + 2] & 0xff) << 8) |
        (digest[offset + 3] & 0xff);
    return (binary % 1000000).toString().padLeft(6, '0');
  }

  Future<String> _deviceId(Map<String, dynamic> blob) async {
    final existing = blob['device_id'] as String?;
    if (existing != null && existing.isNotEmpty) return existing;
    final generated = const Uuid().v4();
    blob['device_id'] = generated;
    await _write(blob);
    return generated;
  }

  Future<String?> _spDc() async {
    final blob = await _read();
    final sp = blob['sp_dc'] as String?;
    if (sp == null || sp.isEmpty) return null;
    return sp;
  }

  Future<Map<String, dynamic>> _read() async {
    final raw = await _store.readSpotifySession();
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v));
      }
    } catch (_) {}
    return {};
  }

  Future<void> _write(Map<String, dynamic> blob) =>
      _store.writeSpotifySession(jsonEncode(blob));

  static int _asInt(Object? value, {int fallback = 0}) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value') ?? fallback;
  }
}

class _Totp {
  final String client;
  final String server;
  final int version;
  const _Totp({
    required this.client,
    required this.server,
    required this.version,
  });
}

/// Strips a pasted cookie jar down to the `sp_dc` value.
String cleanSpDc(String raw) {
  var value = raw.trim();
  if (value.isEmpty) return '';
  final named = RegExp(
    r'(?:^|[;\s])sp_dc=([^;\s]+)',
    caseSensitive: false,
  ).firstMatch(value);
  if (named != null) return named.group(1)!.trim();
  if (value.toLowerCase().startsWith('sp_dc=')) {
    value = value.substring(6);
  }
  return value.split(';').first.trim();
}

final spotifySessionProvider = Provider<SpotifySession>((ref) {
  return SpotifySession(ref.watch(secureStoreProvider));
});
