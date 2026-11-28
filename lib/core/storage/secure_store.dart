import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

/// Secure credential storage (session keys, cookies).
///
/// Uses OS keychain/credential-manager; falls back to an app-support
/// store when OS keychain fails (for example, macOS unsigned/ad-hoc builds
/// where Data Protection Keychain returns `-34018` `errSecMissingEntitlement`),
/// and in-memory if disk storage is unavailable.
class SecureStore {
  static const _sessionKey = 'lastwave.session_key';
  static const _ytCookies = 'lastwave.yt_cookies';
  static const _ytProfiles = 'lastwave.yt_profiles';
  static const _ytActive = 'lastwave.yt_active';
  static const _spotifySpDc = 'lastwave.spotify_sp_dc';
  static const _fallbackFileName = 'secure_store_fallback.json';

  final FlutterSecureStorage _storage;
  final Future<Directory> Function() _fallbackDirProvider;
  final Map<String, String> _memoryFallback = {};
  Map<String, String>? _diskFallback;
  Future<void> _ioQueue = Future<void>.value();

  SecureStore([
    FlutterSecureStorage? storage,
    Future<Directory> Function()? fallbackDirectory,
  ])  : _storage = storage ?? const FlutterSecureStorage(),
        _fallbackDirProvider =
            fallbackDirectory ?? getApplicationSupportDirectory;

  Future<File?> _fallbackFile() async {
    if (kIsWeb) return null;
    try {
      final dir = await _fallbackDirProvider();
      if (!await dir.exists()) await dir.create(recursive: true);
      return File(
          '${dir.path}${Platform.pathSeparator}$_fallbackFileName');
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, String>> _loadDiskFallback() async {
    final cached = _diskFallback;
    if (cached != null) return cached;
    final loaded = <String, String>{};
    try {
      final file = await _fallbackFile();
      if (file != null && await file.exists()) {
        final raw = await file.readAsString();
        if (raw.isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            for (final entry in decoded.entries) {
              if (entry.value != null) {
                loaded[entry.key.toString()] = entry.value.toString();
              }
            }
          }
        }
      }
    } catch (_) {}
    _diskFallback = loaded;
    return loaded;
  }

  Future<void> _enqueueDiskMutation(void Function(Map<String, String> map) mutate) {
    final next = _ioQueue.then((_) async {
      final map = await _loadDiskFallback();
      mutate(map);
      try {
        final file = await _fallbackFile();
        if (file == null) return;
        if (map.isEmpty) {
          if (await file.exists()) await file.delete();
        } else {
          await file.writeAsString(jsonEncode(map), flush: true);
        }
      } catch (_) {}
    });
    _ioQueue = next.catchError((_) {});
    return next;
  }

  Future<String?> _read(String key) async {
    try {
      final v = await _storage.read(key: key);
      if (v != null) return v;
    } catch (_) {
      // fall through to disk/memory fallback
    }
    if (_memoryFallback.containsKey(key)) return _memoryFallback[key];
    await _ioQueue;
    final disk = await _loadDiskFallback();
    return disk[key];
  }

  Future<void> _write(String key, String? value) async {
    if (value == null) {
      _memoryFallback.remove(key);
      try {
        await _storage.delete(key: key);
      } catch (_) {}
      await _enqueueDiskMutation((map) => map.remove(key));
      return;
    }
    _memoryFallback[key] = value;
    var keychainOk = false;
    try {
      await _storage.write(key: key, value: value);
      keychainOk = true;
    } catch (_) {}
    if (keychainOk) {
      // Keep keychain authoritative when it succeeds; prune any stale fallback.
      final existing = _diskFallback;
      if (existing != null && existing.containsKey(key)) {
        await _enqueueDiskMutation((map) => map.remove(key));
      }
    } else {
      await _enqueueDiskMutation((map) => map[key] = value);
    }
  }

  Future<String?> read(String key) => _read(key);
  Future<void> write(String key, String? value) => _write(key, value);
  Future<void> delete(String key) => _write(key, null);

  Future<String?> readSessionKey() => _read(_sessionKey);
  Future<void> writeSessionKey(String? v) => _write(_sessionKey, v);

  Future<String?> readYtCookies() => _read(_ytCookies);
  Future<void> writeYtCookies(String? v) => _write(_ytCookies, v);

  /// Multi-profile roster (`YtProfile.listToJson`) + active pointer
  /// (`{"email": ..., "pageId": ...}`). The active jar itself stays in
  /// [_ytCookies], so single-profile behavior is unchanged.
  Future<String?> readYtProfiles() => _read(_ytProfiles);
  Future<void> writeYtProfiles(String? v) =>
      _write(_ytProfiles, v);

  Future<String?> readYtActive() => _read(_ytActive);
  Future<void> writeYtActive(String? v) => _write(_ytActive, v);

  /// Spotify `sp_dc` session cookie (WebView sign-in or pasted).
  Future<String?> readSpotifySpDc() => _read(_spotifySpDc);
  Future<void> writeSpotifySpDc(String? v) => _write(_spotifySpDc, v);

  Future<void> clearAll() async {
    _memoryFallback.clear();
    try {
      await _storage.deleteAll();
    } catch (_) {}
    await _enqueueDiskMutation((map) => map.clear());
  }
}

final secureStoreProvider = Provider<SecureStore>((_) => SecureStore());
