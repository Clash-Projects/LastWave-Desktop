import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

/// Coarse failure classes for outbound requests.
///
/// Exists because the previous logging could only print
/// `HTTP <code> <method> <host><path>`, which makes a kernel-level
/// socket denial (macOS App Sandbox without `network.client`) look
/// exactly like a 404. This distinguishes the layers a user can act on.
enum NetFailure { dns, connect, tls, timeout, redirect, cert, http, unknown }

String _label(NetFailure f) {
  switch (f) {
    case NetFailure.dns:
      return 'dns';
    case NetFailure.connect:
      return 'connect';
    case NetFailure.tls:
      return 'tls';
    case NetFailure.timeout:
      return 'timeout';
    case NetFailure.redirect:
      return 'redirect';
    case NetFailure.cert:
      return 'cert';
    case NetFailure.http:
      return 'http';
    case NetFailure.unknown:
      return 'unknown';
  }
}

/// `scheme://host/path` and nothing else.
///
/// Query strings and bodies are dropped on purpose: Last.fm `2.0/`
/// POSTs carry `api_key`/`api_sig` in the body and InnerTube carries
/// visitor data in the query, and none of that may reach a log file.
String safeTarget(Uri uri) => '${uri.scheme}://${uri.host}${uri.path}';

/// Secret-free append-only network log at `<temp>/lastwave/net.log`.
///
/// Writes in release builds too: the failures that matter most
/// (sandbox denials, DNS, TLS) are invisible on the user's machine
/// unless they are recorded on their machine.
class NetLog {
  NetLog._();

  static const int _maxBytes = 512 * 1024;
  static File? _file;
  static bool _attempted = false;

  static File? _target() {
    if (!_attempted) {
      _attempted = true;
      try {
        final dir = Directory(
          '${Directory.systemTemp.path}${Platform.pathSeparator}lastwave',
        );
        if (!dir.existsSync()) dir.createSync(recursive: true);
        final f = File(
          '${dir.path}${Platform.pathSeparator}net.log',
        );
        if (f.existsSync() && f.lengthSync() > _maxBytes) f.deleteSync();
        _file = f;
      } catch (_) {
        _file = null;
      }
    }
    return _file;
  }

  static void write(String line) {
    final f = _target();
    if (f == null) return;
    try {
      if (f.lengthSync() > _maxBytes) f.deleteSync();
      f.writeAsStringSync(
        '${DateTime.now().toIso8601String()} $line\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {}
  }

  /// Classify and record a failed request.
  static NetFailure failure(DioException e, {String? stage}) {
    final kind = classify(e);
    final code = e.response?.statusCode;
    write([
      'FAIL ${_label(kind)} ${safeTarget(e.requestOptions.uri)}',
      if (stage != null) 'stage=$stage',
      if (code != null) 'status=$code',
      'type=${e.type.name}',
      'cause=${e.error.runtimeType}',
    ].join(' '));
    return kind;
  }

  static void note(String line) => write('NOTE $line');

  static NetFailure classify(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return NetFailure.timeout;
      case DioExceptionType.badCertificate:
        return NetFailure.cert;
      case DioExceptionType.badResponse:
        final code = e.response?.statusCode ?? 0;
        if (code >= 300 && code < 400) return NetFailure.redirect;
        return NetFailure.http;
      case DioExceptionType.connectionError:
        return _socket(e.error);
      case DioExceptionType.cancel:
        return NetFailure.unknown;
      case DioExceptionType.unknown:
        return _socket(e.error);
      // `default` rather than relying on enum exhaustiveness: a newer dio
      // that adds a DioExceptionType must not break the build here.
      default:
        return _socket(e.error);
    }
  }

  /// macOS surfaces a blocked sandbox socket as a plain `SocketException`,
  /// so DNS text markers are the only way to tell the two apart.
  static NetFailure _socket(Object? err) {
    if (err is HandshakeException || err is TlsException) {
      return NetFailure.tls;
    }
    if (err is TimeoutException) return NetFailure.timeout;
    if (err is SocketException) {
      final text =
          '${err.message} ${err.osError?.message ?? ''}'.toLowerCase();
      const dnsMarkers = [
        'failed host lookup',
        'nodename nor servname',
        'name or service not known',
        'no address associated',
        'temporary failure in name resolution',
        'could not resolve',
        'getaddrinfo',
      ];
      for (final m in dnsMarkers) {
        if (text.contains(m)) return NetFailure.dns;
      }
      return NetFailure.connect;
    }
    return NetFailure.unknown;
  }
}

class NetProbeResult {
  const NetProbeResult(this.step, this.ok, this.detail);
  final String step;
  final bool ok;
  final String detail;
}

/// Minimal connectivity self-test used to tell "no internet" apart from
/// "this one host is down". Walks the layers in order and reports each
/// one separately, using only endpoints the app itself talks to (no
/// third-party services, no credentials).
class NetProbe {
  NetProbe._();

  static const String _dnsHost = 'music.youtube.com';

  /// InnerTube bootstrap scrape (`innertube_api.dart`).
  static const String _bootstrap = 'https://music.youtube.com/';

  /// Unauthenticated metadata fallback (`innertube_api.dart`).
  static const String _appApi =
      'https://www.youtube.com/oembed?url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3DdQw4w9WgXcQ&format=json';

  static Future<List<NetProbeResult>> run() async {
    final out = <NetProbeResult>[];

    try {
      final addrs =
          await InternetAddress.lookup(_dnsHost).timeout(const Duration(seconds: 5));
      out.add(NetProbeResult(
        'dns',
        addrs.isNotEmpty,
        addrs.isEmpty ? 'no addresses' : '${addrs.length} address(es)',
      ));
    } catch (e) {
      out.add(NetProbeResult('dns', false, '${e.runtimeType}'));
    }

    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
      followRedirects: true,
      validateStatus: (s) => s != null && s < 400,
    ));

    try {
      final res = await dio.get<dynamic>(_bootstrap);
      out.add(NetProbeResult('https', true, 'status=${res.statusCode}'));
      out.add(NetProbeResult(
        'redirect',
        !res.isRedirect,
        res.isRedirect
            ? 'still 3xx after maxRedirects'
            : 'final ${safeTarget(res.realUri)}',
      ));
    } catch (e) {
      final detail = e is DioException
          ? _label(NetLog.classify(e))
          : '${e.runtimeType}';
      out.add(NetProbeResult('https', false, detail));
      out.add(const NetProbeResult('redirect', false, 'not exercised'));
    }

    try {
      final res = await dio.get<dynamic>(_appApi);
      out.add(NetProbeResult('app-api', res.statusCode == 200, 'status=${res.statusCode}'));
    } catch (e) {
      final detail = e is DioException
          ? _label(NetLog.classify(e))
          : '${e.runtimeType}';
      out.add(NetProbeResult('app-api', false, detail));
    }

    return out;
  }

  /// Run and record the breakdown to [NetLog].
  static Future<List<NetProbeResult>> runAndLog() async {
    final results = await run();
    for (final r in results) {
      NetLog.write('PROBE ${r.step} ${r.ok ? 'ok' : 'FAIL'} ${r.detail}');
    }
    NetLog.write('PROBE ${results.any((r) => !r.ok) ? 'DEGRADED' : 'CLEAR'}');
    return results;
  }
}
