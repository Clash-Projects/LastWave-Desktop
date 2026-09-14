import 'dart:convert';

/// Parses YouTube `api/jnn/v1` BotGuard responses.
///
/// Direct Dart port of LastWave-native `ChallengeParser.kt`.
String parseCreateChallenge(String rawResponse) {
  final outer = jsonDecode(rawResponse) as List;
  List challenge;
  if (outer.length > 1 && outer[1] is String) {
    final decoded = _descramble(outer[1] as String);
    challenge = jsonDecode(decoded) as List;
  } else {
    challenge = outer[0] as List;
  }
  final program = challenge[4] as String;
  final globalName = challenge[5] as String;
  String? interpreterJs;
  final interp = challenge[1];
  if (interp is List) {
    for (final e in interp) {
      if (e is String) {
        interpreterJs = e;
        break;
      }
    }
  }

  String? interpreterUrl;
  final interpUrl = challenge[2];
  if (interpUrl is List) {
    for (final e in interpUrl) {
      if (e is String) {
        interpreterUrl = e;
        break;
      }
    }
  }

  return jsonEncode({
    'program': program,
    'globalName': globalName,
    'interpreterJavascript': {
      'privateDoNotAccessOrElseSafeScriptWrappedValue':
          interpreterJs,
      'privateDoNotAccessOrElseTrustedResourceUrlWrappedValue':
          interpreterUrl,
    },
  });
}

/// Returns (tokenU8 JS literal, lifetimeSeconds).
(String, int) parseIntegrityToken(String rawResponse) {
  final arr = jsonDecode(rawResponse) as List;
  final tokenU8 = _base64ToJsUint8Array(arr[0] as String);
  final lifetimeSeconds = (arr[1] as num).toInt();
  return (tokenU8, lifetimeSeconds);
}

/// `new Uint8Array([...])` literal for an identifier string.
String stringToJsUint8Array(String identifier) {
  final bytes = utf8.encode(identifier);
  return 'new Uint8Array([${bytes.join(',')}])';
}

/// JS `Uint8Array.toString()` CSV → URL-safe unpadded base64.
String commaSeparatedBytesToBase64(String commaBytes) {
  final bytes = commaBytes
      .split(',')
      .map((e) => int.parse(e.trim()) & 0xFF)
      .toList();
  return base64Url.encode(bytes).replaceAll('=', '');
}

String _descramble(String base64Payload) {
  final bytes = _base64ToBytes(base64Payload);
  return utf8.decode(
      bytes.map((b) => (b + 97) & 0xFF).toList(),
      allowMalformed: true);
}

String _base64ToJsUint8Array(String base64Value) {
  final bytes = _base64ToBytes(base64Value);
  return 'new Uint8Array([${bytes.join(',')}])';
}

List<int> _base64ToBytes(String base64Value) {
  var normalized = base64Value
      .replaceAll('-', '+')
      .replaceAll('_', '/')
      .replaceAll('.', '=');
  normalized =
      normalized.replaceAll(RegExp(r'[^A-Za-z0-9+/=]'), '');
  final pad = (4 - normalized.length % 4) % 4;
  normalized += '=' * pad;
  return base64.decode(normalized);
}
