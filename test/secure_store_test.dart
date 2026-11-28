import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/storage/secure_store.dart';

class _FailingSecureStorage extends FlutterSecureStorage {
  const _FailingSecureStorage();

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    throw PlatformException(
      code: 'Unexpected security result code',
      message: 'errSecMissingEntitlement',
      details: -34018,
    );
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    throw PlatformException(
      code: 'Unexpected security result code',
      message: 'errSecMissingEntitlement',
      details: -34018,
    );
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    throw PlatformException(
      code: 'Unexpected security result code',
      message: 'errSecMissingEntitlement',
      details: -34018,
    );
  }

  @override
  Future<void> deleteAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    throw PlatformException(
      code: 'Unexpected security result code',
      message: 'errSecMissingEntitlement',
      details: -34018,
    );
  }
}

void main() {
  test('persists cookies across restarts when OS keychain throws (-34018)',
      () async {
    final tempDir = Directory.systemTemp.createTempSync('lastwave_sec_test_');
    addTearDown(() => tempDir.deleteSync(recursive: true));

    final firstRun = SecureStore(const _FailingSecureStorage(), () async => tempDir);
    await firstRun.writeYtCookies('SAPISID=abc; __Secure-3PSID=xyz');
    await firstRun.writeYtActive('{"email":"u@example.com","pageId":""}');
    await firstRun.writeSpotifySpDc('sp_dc_token');

    final reopened = SecureStore(const _FailingSecureStorage(), () async => tempDir);
    expect(await reopened.readYtCookies(), 'SAPISID=abc; __Secure-3PSID=xyz');
    expect(await reopened.readYtActive(), '{"email":"u@example.com","pageId":""}');
    expect(await reopened.readSpotifySpDc(), 'sp_dc_token');

    await reopened.writeYtCookies(null);
    final afterDelete = SecureStore(const _FailingSecureStorage(), () async => tempDir);
    expect(await afterDelete.readYtCookies(), isNull);
    expect(await afterDelete.readSpotifySpDc(), 'sp_dc_token');

    await afterDelete.clearAll();
    final afterClear = SecureStore(const _FailingSecureStorage(), () async => tempDir);
    expect(await afterClear.readSpotifySpDc(), isNull);
  });
}
