import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Room code carried by a `lastwave://jam?code=ABC123` link, upper-cased,
/// or null when [link] is anything else.
String? jamCodeFromLink(String link) {
  final uri = Uri.tryParse(link.trim());
  if (uri == null || uri.scheme.toLowerCase() != 'lastwave') return null;
  if (uri.host.toLowerCase() != 'jam') return null;
  final code = (uri.queryParameters['code'] ?? '').trim().toUpperCase();
  return RegExp(r'^[A-Z0-9]{3,12}$').hasMatch(code) ? code : null;
}

/// In-app route a `lastwave://` link opens, or null for unknown links.
String? routeForLink(String link) {
  final code = jamCodeFromLink(link);
  return code == null ? null : '/jam?code=$code';
}

/// `lastwave://` links: the one in the launch arguments, plus links that a
/// second launch forwards to the running window (Windows, via the runner's
/// `lastwave/deeplink` channel). Links are never logged.
class DeepLinks {
  DeepLinks._();

  static const _channel = MethodChannel('lastwave/deeplink');
  static final _controller = StreamController<String>.broadcast();
  static String? _initial;

  static Stream<String> get stream => _controller.stream;

  /// The link this process was launched with, once.
  static String? takeInitial() {
    final link = _initial;
    _initial = null;
    return link;
  }

  static void start(List<String> args) {
    for (final arg in args) {
      if (routeForLink(arg) != null) {
        _initial = arg;
        break;
      }
    }
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'link' && call.arguments is String) {
        _controller.add(call.arguments as String);
      }
    });
    if (Platform.isWindows) _registerWindowsScheme();
  }

  /// Points `lastwave://` at this executable (per-user, no admin rights).
  /// Best-effort: a failure only means links open nothing.
  static Future<void> _registerWindowsScheme() async {
    try {
      final exe = Platform.resolvedExecutable;
      const root = r'HKCU\Software\Classes\lastwave';
      const commandKey = root + r'\shell\open\command';
      final command = '"$exe" "%1"';
      final current = await Process.run(
        'reg',
        ['query', commandKey, '/ve'],
      );
      if (current.exitCode == 0 && '${current.stdout}'.contains(command)) {
        return;
      }
      Future<void> add(String key, List<String> rest) =>
          Process.run('reg', ['add', key, ...rest, '/f']);
      await add(root, ['/ve', '/d', 'URL:LastWave']);
      await add(root, ['/v', 'URL Protocol', '/d', '']);
      await add(commandKey, ['/ve', '/d', command]);
    } catch (_) {}
  }
}
