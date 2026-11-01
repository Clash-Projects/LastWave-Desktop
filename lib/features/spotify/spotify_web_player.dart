import 'dart:convert';

import 'package:dio/dio.dart';

/// Reads persisted-query hashes and the TOTP secret out of Spotify's
/// web player, the same way Android `SpotifyWebPlayer` does.
class SpotifyWebPlayer {
  SpotifyWebPlayer._();

  static const canvasOperation = 'canvas';
  static const searchOperation = 'assistedCurationSearch';
  static const _page = 'https://open.spotify.com/';
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
  static const _secretsUrl =
      'https://raw.githubusercontent.com/xyloflake/spot-secrets-go/refs/heads/main/secrets/secretDict.json';

  static String? _script;
  static DateTime? _readAt;
  static Future<String?>? _inflight;

  static Future<SpotifySecret?> secret(Dio dio) async {
    final script = await _load(dio);
    if (script != null) {
      final found = secrets(script);
      if (found.isNotEmpty) return found.first;
    }
    return _published(dio);
  }

  static Future<String?> queryHash(
    Dio dio,
    String operation, {
    bool force = false,
  }) async {
    final script = await _load(dio, force: force);
    if (script == null) return null;
    return hashOf(script, operation);
  }

  static Future<String?> _load(Dio dio, {bool force = false}) {
    final cached = _script;
    final at = _readAt;
    if (!force &&
        cached != null &&
        at != null &&
        DateTime.now().difference(at) < const Duration(hours: 6)) {
      return Future.value(cached);
    }
    final pending = _inflight;
    if (!force && pending != null) return pending;
    final run = _read(dio);
    _inflight = run;
    return run.whenComplete(() {
      if (identical(_inflight, run)) _inflight = null;
    });
  }

  static Future<String?> _read(Dio dio) async {
    final page = await _get(dio, _page);
    if (page == null) {
      _readAt = DateTime.now();
      return _script;
    }
    final bundles = RegExp(
      r'https://open\.spotifycdn\.com/cdn/build/[^"\s>]+\.(?:js|mjs)',
    ).allMatches(page).map((m) => m.group(0)!).toSet().take(12);
    for (final bundle in bundles) {
      final body = await _get(dio, bundle);
      if (body == null) continue;
      if (hashOf(body, canvasOperation) != null || secrets(body).isNotEmpty) {
        _script = body;
        _readAt = DateTime.now();
        return body;
      }
    }
    _readAt = DateTime.now();
    _script = null;
    return null;
  }

  static Future<String?> _get(Dio dio, String url) async {
    try {
      final res = await dio.get<String>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          headers: {
            'User-Agent': _ua,
            'Referer': _page,
          },
        ),
      );
      if (res.statusCode != null && res.statusCode! >= 400) return null;
      return res.data;
    } catch (_) {
      return null;
    }
  }

  static String? hashOf(String script, String operation) {
    final re = RegExp(
      '["\'](\\w+)["\']\\s*,\\s*["\']query["\']\\s*,\\s*["\']([0-9a-f]{64})["\']',
    );
    for (final match in re.allMatches(script)) {
      if (match.group(1) == operation) return match.group(2);
    }
    return null;
  }

  static List<SpotifySecret> secrets(String script) {
    final re = RegExp(
      "secret:\\s*(?:'((?:[^'\\\\]|\\\\.)*)'|\"((?:[^\"\\\\]|\\\\.)*)\")\\s*,\\s*version:\\s*(\\d+)",
    );
    final found = <SpotifySecret>[];
    for (final match in re.allMatches(script)) {
      final raw = (match.group(1) ?? '').isNotEmpty
          ? match.group(1)!
          : (match.group(2) ?? '');
      final version = int.tryParse(match.group(3) ?? '');
      if (raw.isEmpty || version == null) continue;
      found.add(SpotifySecret(_unescape(raw), version));
    }
    found.sort((a, b) => b.version.compareTo(a.version));
    return found;
  }

  static Map<String, dynamic>? _asMap(Object? data) {
    if (data is Map) {
      return data.map((k, v) => MapEntry(k.toString(), v));
    }
    if (data is String && data.trim().isNotEmpty) {
      try {
        final decoded = _asMap(jsonDecode(data));
        return decoded;
      } catch (_) {}
    }
    return null;
  }

  static String _unescape(String raw) {
    final out = StringBuffer();
    for (var i = 0; i < raw.length; i++) {
      final c = raw[i];
      if (c == '\\' && i + 1 < raw.length) {
        final next = raw[i + 1];
        out.write(switch (next) {
          'n' => '\n',
          'r' => '\r',
          't' => '\t',
          _ => next,
        });
        i++;
      } else {
        out.write(c);
      }
    }
    return out.toString();
  }

  static Future<SpotifySecret?> _published(Dio dio) async {
    try {
      final res = await dio.get<dynamic>(
        _secretsUrl,
        options: Options(headers: {'User-Agent': _ua}),
      );
      final data = _asMap(res.data);
      if (data == null) return null;
      var best = -1;
      List<int>? bytes;
      for (final entry in data.entries) {
        final version = int.tryParse(entry.key.toString()) ?? -1;
        final value = entry.value;
        if (version > best && value is List) {
          best = version;
          bytes = value.map((e) => (e as num).toInt()).toList();
        }
      }
      if (best < 0 || bytes == null) return null;
      return SpotifySecret(String.fromCharCodes(bytes), best);
    } catch (_) {
      return null;
    }
  }
}

class SpotifySecret {
  final String value;
  final int version;
  const SpotifySecret(this.value, this.version);
}
