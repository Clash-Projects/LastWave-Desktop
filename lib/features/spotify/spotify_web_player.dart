import 'dart:async';

import 'package:dio/dio.dart';

import '../../core/diagnostics/diagnostics_log.dart';

/// What Spotify's web player is built on, read out of its own script.
///
/// Port of LastWave-Native `SpotifyWebPlayer`. Two things live in the
/// player's bundle and both move whenever Spotify rebuilds it, so a copy
/// of them goes stale and every request made with the copy starts being
/// refused (which looks exactly like "signed out" or "no canvas"):
///
/// 1. the **persisted-query hashes** — every GraphQL operation is named
///    by a hash that changes when the operation is rebuilt;
/// 2. the **one-time-password secret** (+ version) the token exchange is
///    signed with.
class SpotifyWebPlayer {
  SpotifyWebPlayer._();

  static const userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  static const _playerPage = 'https://open.spotify.com/';
  static const _cacheTtl = Duration(hours: 6);
  static const _maxScripts = 4;

  /// The operation that asks for a track's canvas.
  static const canvasOperation = 'canvas';

  /// The operation that searches for tracks (was `searchTracks`).
  static const searchOperation = 'assistedCurationSearch';
  static const libraryOperation = 'libraryV3';
  static const fetchPlaylistOperation = 'fetchPlaylist';

  static String? _script;
  static DateTime? _readAt;
  static Future<String?>? _inflight;

  /// The player's script, or null when it could not be read. Cached for a
  /// few hours: the player changes rarely and the bundle is megabytes.
  static Future<String?> script(Dio dio, {bool force = false}) {
    final at = _readAt;
    if (!force &&
        _script != null &&
        at != null &&
        DateTime.now().difference(at) < _cacheTtl) {
      return Future.value(_script);
    }
    return _inflight ??= _read(dio).whenComplete(() => _inflight = null);
  }

  static Future<String?> _read(Dio dio) async {
    final page = await _get(dio, _playerPage);
    if (page == null) {
      DiagnosticsLog.info('spotify player page=unreadable');
      return null;
    }
    final bundles = scripts(page);
    DiagnosticsLog.info('spotify player bundles=${bundles.length}');
    for (final bundle in bundles.take(_maxScripts)) {
      final body = await _get(dio, bundle);
      if (body == null) continue;
      if (queryHash(body, canvasOperation) != null ||
          secrets(body).isNotEmpty) {
        _script = body;
        _readAt = DateTime.now();
        DiagnosticsLog.info(
          'spotify player script ok secrets=${secrets(body).length} '
          'canvasHash=${queryHash(body, canvasOperation) != null}',
        );
        return body;
      }
    }
    DiagnosticsLog.info('spotify player script=no-hashes-or-secrets');
    return null;
  }

  static Future<String?> _get(Dio dio, String url) async {
    try {
      final res = await dio.get<String>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          headers: const {
            'User-Agent': userAgent,
            'Referer': _playerPage,
            'Accept': '*/*',
          },
          receiveTimeout: const Duration(seconds: 40),
          validateStatus: (c) => c != null && c >= 200 && c < 300,
        ),
      );
      return res.data;
    } catch (_) {
      return null;
    }
  }

  /// The player's script bundles, as linked from the player's page.
  static List<String> scripts(String html) =>
      {for (final m in _bundle.allMatches(html)) m.group(0)!}.toList();

  static final _bundle = RegExp(
    r'https://open\.spotifycdn\.com/cdn/build/web-player/'
    r'[A-Za-z0-9._~-]+\.(?:js|mjs)',
  );

  /// An operation's hash, as the player declares it:
  /// `"<name>","query","<64 hex>"`.
  static String? queryHash(String script, String operation) {
    for (final m in _operation.allMatches(script)) {
      if (m.group(1) == operation) return m.group(2);
    }
    for (final m in _operationNamed.allMatches(script)) {
      if (m.group(1) == operation) return m.group(2);
    }
    return null;
  }

  /// Alternate declaration shape: `name:"x",operation:"query",sha256Hash:"…"`.
  static final _operationNamed = RegExp(
    r'''name:\s*["'](\w+)["']\s*,\s*operation:\s*["']query["']\s*,\s*sha256Hash:\s*["']([0-9a-f]{64})["']''',
  );

  static final _operation = RegExp(
    r'''["'](\w+)["']\s*,\s*["']query["']\s*,\s*["']([0-9a-f]{64})["']''',
  );

  /// The one-time-password secrets the player carries, newest first.
  static List<SpotifySecret> secrets(String script) {
    final out = <SpotifySecret>[];
    for (final m in _secret.allMatches(script)) {
      final raw = m.group(1) ?? m.group(2) ?? '';
      final version = int.tryParse(m.group(3) ?? '');
      if (raw.isEmpty || version == null) continue;
      out.add(SpotifySecret(_unescape(raw), version));
    }
    out.sort((a, b) => b.version.compareTo(a.version));
    return out;
  }

  static final _secret = RegExp(
    r'''secret:\s*(?:'((?:[^'\\]|\\.)*)'|"((?:[^"\\]|\\.)*)")\s*,\s*version:\s*(\d+)''',
  );

  static String _unescape(String raw) {
    final out = StringBuffer();
    var i = 0;
    while (i < raw.length) {
      final c = raw[i];
      if (c == r'\' && i + 1 < raw.length) {
        final next = raw[i + 1];
        out.write(switch (next) {
          'n' => '\n',
          'r' => '\r',
          't' => '\t',
          _ => next,
        });
        i += 2;
      } else {
        out.write(c);
        i++;
      }
    }
    return out.toString();
  }

  /// Test hook: forget what was read.
  static void resetForTest() {
    _script = null;
    _readAt = null;
    _inflight = null;
  }
}

class SpotifySecret {
  final String value;
  final int version;
  const SpotifySecret(this.value, this.version);
}
