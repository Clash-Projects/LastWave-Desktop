import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Regression guard for the v1.0.0 macOS "launches but has no internet"
/// bug. That release shipped `com.apple.security.app-sandbox` with no
/// `com.apple.security.network.client`, so the kernel denied every
/// outbound socket: the window, SQLite, prefs and UI all kept working
/// (pure local file I/O) while every request died at `connect()`.
///
/// Windows and Linux have no equivalent sandbox in this project, which
/// is exactly why only macOS was affected. These are pure filesystem
/// checks so they run on every CI runner, and they fail the build before
/// a tag can ship another sandboxed-without-network bundle.
const List<String> _entitlementFiles = [
  'macos/Runner/DebugProfile.entitlements',
  'macos/Runner/Release.entitlements',
];

/// Entitlement keys granted `<true/>` in an entitlements plist.
Set<String> _granted(String path) {
  final xml = File(path).readAsStringSync();
  final granted = <String>{};
  final pattern = RegExp(r'<key>([^<]+)</key>\s*<(true|false)\s*/>');
  for (final m in pattern.allMatches(xml)) {
    if (m.group(2) == 'true') granted.add(m.group(1)!.trim());
  }
  return granted;
}

String _pbxproj() =>
    File('macos/Runner.xcodeproj/project.pbxproj').readAsStringSync();

void main() {
  test('every entitlements file grants outgoing network access', () {
    for (final path in _entitlementFiles) {
      expect(File(path).existsSync(), isTrue, reason: '$path is missing');
      final granted = _granted(path);
      expect(
        granted,
        contains('com.apple.security.app-sandbox'),
        reason: '$path must keep the app sandbox enabled',
      );
      expect(
        granted,
        contains('com.apple.security.network.client'),
        reason: '$path grants no outbound network, so the app will '
            'launch but behave as if it has no internet on macOS',
      );
    }
  });

  test('every signing config resolves to a network-granting file', () {
    final refs = RegExp(r'CODE_SIGN_ENTITLEMENTS\s*=\s*([^;]+);')
        .allMatches(_pbxproj())
        .map((m) => m.group(1)!.trim())
        .toSet();
    expect(refs, isNotEmpty,
        reason: 'no CODE_SIGN_ENTITLEMENTS found; this guard would pass '
            'vacuously and stop protecting anything');
    for (final ref in refs) {
      final path = 'macos/$ref'.replaceAll('\\', '/');
      expect(File(path).existsSync(), isTrue,
          reason: 'pbxproj references $ref but the file does not exist');
      expect(_granted(path), contains('com.apple.security.network.client'),
          reason: '$ref grants no outbound network');
    }
  });

  test('release builds sign with Release.entitlements', () {
    expect(_pbxproj(),
        contains('CODE_SIGN_ENTITLEMENTS = Runner/Release.entitlements;'));
  });

  test('App Transport Security is never globally disabled', () {
    final plist = File('macos/Runner/Info.plist').readAsStringSync();
    expect(plist, isNot(contains('NSAllowsArbitraryLoads')),
        reason: 'every API endpoint is HTTPS, so this must never be '
            'needed; Dart uses BoringSSL, not NSURLSession');
  });
}
