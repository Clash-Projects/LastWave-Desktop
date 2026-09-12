import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Secure credential storage (session keys, cookies).
///
/// Uses OS keychain/credential-manager; falls back to in-memory on
/// platforms without a backend so the app keeps working.
class SecureStore {
  static const _sessionKey = 'lastwave.session_key';
  static const _ytCookies = 'lastwave.yt_cookies';

  final FlutterSecureStorage _storage;
  final Map<String, String> _memoryFallback = {};

  SecureStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  Future<String?> _read(String key) async {
    try {
      final v = await _storage.read(key: key);
      if (v != null) return v;
    } catch (_) {
      // fall through to memory
    }
    return _memoryFallback[key];
  }

  Future<void> _write(String key, String? value) async {
    if (value == null) {
      _memoryFallback.remove(key);
      try {
        await _storage.delete(key: key);
      } catch (_) {}
      return;
    }
    _memoryFallback[key] = value;
    try {
      await _storage.write(key: key, value: value);
    } catch (_) {}
  }

  Future<String?> readSessionKey() => _read(_sessionKey);
  Future<void> writeSessionKey(String? v) => _write(_sessionKey, v);

  Future<String?> readYtCookies() => _read(_ytCookies);
  Future<void> writeYtCookies(String? v) => _write(_ytCookies, v);

  Future<void> clearAll() async {
    _memoryFallback.clear();
    try {
      await _storage.deleteAll();
    } catch (_) {}
  }
}

final secureStoreProvider = Provider<SecureStore>((_) => SecureStore());
