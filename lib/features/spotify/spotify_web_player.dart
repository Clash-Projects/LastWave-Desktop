import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform, Process;

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
      '(KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36';

  static const _playerPage = 'https://open.spotify.com/';
  static const _cacheTtl = Duration(hours: 6);
  static const _maxScripts = 4;

  /// The operation that asks for a track's canvas.
  static const canvasOperation = 'canvas';

  /// The operation that searches for tracks (was `searchTracks`).
  static const searchOperation = 'assistedCurationSearch';
  static const libraryOperation = 'libraryV3';

  /// The web player's Home feed query.
  static const homeOperation = 'home';
  static const fetchPlaylistOperation = 'fetchPlaylist';

  static String? _script;
  static DateTime? _readAt;
  static Future<String?>? _inflight;

  /// Most bundles scanned when looking for an operation hash.
  static const _maxHashScripts = 24;

  static final Map<String, String> _hashes = {};

  /// [operation]'s hash from whichever player bundle declares it. [script]
  /// only keeps the first matching bundle, and route chunks such as Home
  /// declare their queries elsewhere. Cached for the app session.
  static Future<String?> findHash(Dio dio, String operation) async {
    final cached = _hashes[operation];
    if (cached != null) return cached;
    final main = await script(dio);
    var hash = main == null ? null : queryHash(main, operation);
    if (hash == null) {
      final page = await _get(dio, _playerPage);
      if (page != null) {
        for (final bundle in scripts(page).take(_maxHashScripts)) {
          final body = await _get(dio, bundle);
          if (body == null) continue;
          hash = queryHash(body, operation);
          if (hash != null) break;
        }
      }
    }
    DiagnosticsLog.info('spotify player op=$operation hash=${hash != null}');
    if (hash != null) _hashes[operation] = hash;
    return hash;
  }

  static List<SpotifySecret>? _secrets;
  static DateTime? _secretsAt;
  static Future<List<SpotifySecret>>? _secretsInflight;

  /// Most bundles scanned for the one-time-password secrets.
  static const _maxSecretScripts = 24;

  /// The one-time-password secrets the player carries, newest first.
  ///
  /// [script] stops at the first bundle with *either* the GraphQL hashes or
  /// the secrets, and only looks at four bundles; when the secrets sit in a
  /// later chunk the sign-in fell back to a single GitHub file, which some
  /// networks block, and failed every time. This looks through every
  /// bundle the page links (cached like [script]).
  static Future<List<SpotifySecret>> playerSecrets(Dio dio) {
    final at = _secretsAt;
    final cached = _secrets;
    if (cached != null &&
        cached.isNotEmpty &&
        at != null &&
        DateTime.now().difference(at) < _cacheTtl) {
      return Future.value(cached);
    }
    return _secretsInflight ??=
        _readSecrets(dio).whenComplete(() => _secretsInflight = null);
  }

  static bool _lastPageUnreadable = false;
  static bool _proxyChecked = false;
  static String? _winProxy;

  static Future<List<SpotifySecret>> _readSecrets(Dio dio) async {
    final main = await script(dio);
    if (main != null) {
      final found = secrets(main);
      if (found.isNotEmpty) return _keepSecrets(found);
    } else if (_lastPageUnreadable) {
      return const [];
    }
    final page = await _get(dio, _playerPage);
    if (page == null) return const [];
    for (final bundle in scripts(page).take(_maxSecretScripts)) {
      final body = await _get(dio, bundle);
      if (body == null) continue;
      final found = secrets(body);
      if (found.isNotEmpty) return _keepSecrets(found);
    }
    DiagnosticsLog.info('spotify player secrets=none');
    return const [];
  }

  static List<SpotifySecret> _keepSecrets(List<SpotifySecret> found) {
    _secrets = found;
    _secretsAt = DateTime.now();
    return found;
  }

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
      _lastPageUnreadable = true;
      DiagnosticsLog.info('spotify player page=unreadable');
      return null;
    }
    _lastPageUnreadable = false;
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
    final isPage = url == _playerPage;
    final headers = <String, String>{
      'User-Agent': userAgent,
      'Referer': _playerPage,
      'Accept': isPage
          ? 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
          : '*/*',
    };
    try {
      final res = await dio.get<String>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          headers: headers,
          receiveTimeout: const Duration(seconds: 40),
          validateStatus: (c) => c != null && c >= 200 && c < 300,
        ),
      );
      return res.data;
    } on DioException catch (e) {
      DiagnosticsLog.info(
        'spotify player get failed host=${Uri.tryParse(url)?.host} '
        'type=${e.type.name} http=${e.response?.statusCode} '
        'err=${e.error?.runtimeType}',
      );
    } catch (e) {
      DiagnosticsLog.info(
        'spotify player get failed host=${Uri.tryParse(url)?.host} '
        'err=${e.runtimeType}',
      );
    }
    final fallback = await curlGet(url, headers: headers, timeoutSeconds: 30);
    if (fallback != null && fallback.status >= 200 && fallback.status < 300) {
      return fallback.body;
    }
    return null;
  }

  /// Reads the Windows WinINET system proxy once, or null when disabled.
  /// Dart's [HttpClient] only checks `HTTP_PROXY`/`HTTPS_PROXY` env vars
  /// and ignores the Windows system proxy that browsers use.
  static Future<String?> _windowsSystemProxy() async {
    if (!Platform.isWindows) return null;
    if (_proxyChecked) return _winProxy;
    _proxyChecked = true;
    try {
      final enabled = await Process.run('reg', const [
        'query',
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
        '/v',
        'ProxyEnable',
      ]).timeout(const Duration(seconds: 3));
      if (enabled.exitCode != 0 ||
          !RegExp(
            r'ProxyEnable\s+REG_DWORD\s+0x1\b',
          ).hasMatch('${enabled.stdout}')) {
        return null;
      }
      final server = await Process.run('reg', const [
        'query',
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
        '/v',
        'ProxyServer',
      ]).timeout(const Duration(seconds: 3));
      if (server.exitCode != 0) return null;
      final m = RegExp(
        r'ProxyServer\s+REG_SZ\s+(.+)',
      ).firstMatch('${server.stdout}');
      final raw = m?.group(1)?.trim() ?? '';
      if (raw.isEmpty) return null;
      var picked = raw;
      if (raw.contains('=')) {
        final parts = <String, String>{};
        for (final entry in raw.split(';')) {
          final eq = entry.indexOf('=');
          if (eq > 0) {
            parts[entry.substring(0, eq).trim().toLowerCase()] = entry
                .substring(eq + 1)
                .trim();
          }
        }
        picked = parts['https'] ?? parts['http'] ?? parts['socks'] ?? '';
      }
      if (picked.isEmpty) return null;
      _winProxy = picked.contains('://') ? picked : 'http://$picked';
      DiagnosticsLog.info('spotify net win-proxy=detected');
    } catch (_) {}
    return _winProxy;
  }

  /// Fallback HTTP GET via Windows' built-in `curl.exe` (Schannel TLS,
  /// Windows certificate store, IPv4 fallback, and Windows system proxy).
  /// URL and headers are passed via stdin (`-K -`) so cookies/tokens never
  /// appear in process arguments.
  static Future<({int status, String body})?> curlGet(
    String url, {
    Map<String, String> headers = const {},
    int timeoutSeconds = 20,
  }) async {
    if (!Platform.isWindows) return null;
    final proxy = await _windowsSystemProxy();
    for (final ipv4 in const [false, true]) {
      final res = await _runCurl(
        url,
        headers: headers,
        timeoutSeconds: timeoutSeconds,
        proxy: proxy,
        ipv4: ipv4,
      );
      if (res != null) return res;
    }
    return null;
  }

  static String _curlEscape(String v) =>
      v.replaceAll(r'\', r'\\').replaceAll('"', r'\"');

  static Future<({int status, String body})?> _runCurl(
    String url, {
    required Map<String, String> headers,
    required int timeoutSeconds,
    required String? proxy,
    required bool ipv4,
  }) async {
    try {
      final args = <String>[
        '-sS',
        '-L',
        '--max-time',
        '$timeoutSeconds',
        if (ipv4) '-4',
        if (proxy != null) ...['--proxy', proxy],
        '-w',
        '\n%{http_code}',
        '-K',
        '-',
      ];
      final proc = await Process.start('curl.exe', args);
      final cfg = StringBuffer()..writeln('url = "${_curlEscape(url)}"');
      for (final e in headers.entries) {
        cfg.writeln('header = "${_curlEscape('${e.key}: ${e.value}')}"');
      }
      proc.stdin.write(cfg.toString());
      await proc.stdin.close();

      final stdoutFuture = proc.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      final stderrFuture = proc.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      final exitCode = await proc.exitCode.timeout(
        Duration(seconds: timeoutSeconds + 5),
        onTimeout: () {
          proc.kill();
          return -1;
        },
      );
      final out = await stdoutFuture;
      final err = await stderrFuture;
      if (exitCode != 0) {
        var brief = err.trim().split('\n').first;
        final q = brief.indexOf('?');
        if (q >= 0) brief = brief.substring(0, q);
        if (brief.length > 120) brief = brief.substring(0, 120);
        DiagnosticsLog.info(
          'spotify curl exit=$exitCode ipv4=$ipv4 err=$brief',
        );
        return null;
      }
      final split = out.lastIndexOf('\n');
      if (split < 0) return null;
      final status = int.tryParse(out.substring(split + 1).trim());
      if (status == null) return null;
      return (status: status, body: out.substring(0, split));
    } catch (e) {
      DiagnosticsLog.info('spotify curl error=${e.runtimeType}');
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
    _hashes.clear();
    _secrets = null;
    _secretsAt = null;
    _secretsInflight = null;
    _lastPageUnreadable = false;
    _proxyChecked = false;
    _winProxy = null;
  }
}

class SpotifySecret {
  final String value;
  final int version;
  const SpotifySecret(this.value, this.version);
}
