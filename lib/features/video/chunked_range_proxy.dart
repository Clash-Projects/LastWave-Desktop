import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

/// A loopback HTTP proxy that turns the player's open-ended range requests
/// into bounded ones, the way every working YouTube client does.
///
/// googlevideo throttles an open-ended `Range: bytes=0-` and answers HTTP 403
/// to some client profiles (iOS, visionOS) unless every request carries an
/// end. yt-dlp downloads in 10 MiB ranges, NewPipe reads through a ranged
/// data source, and LastWave-Native wraps its player in
/// `ChunkedRangeDataSource` for exactly this reason. libmpv's ffmpeg HTTP
/// layer has no such option: it opens `bytes=0-` and keeps that one request
/// for the whole file, so high-resolution streams either stall or are
/// refused and only the smallest picture ever plays.
///
/// The player opens `http://127.0.0.1:<port>/v/<id>` instead; each request
/// is answered by reading the real URL in [chunkBytes] pieces, with the next
/// piece already requested while the current one is being delivered.
class ChunkedRangeProxy {
  ChunkedRangeProxy({this.chunkBytes = 2 * 1024 * 1024});

  /// In-process instance: the fallback when the proxy isolate cannot start.
  /// The app normally goes through [RangeProxy.shared].
  static final ChunkedRangeProxy shared = ChunkedRangeProxy();

  final int chunkBytes;

  HttpServer? _server;
  Future<HttpServer>? _starting;
  final Map<String, _Source> _sources = {};
  int _seq = 0;

  static const int _maxSources = 12;

  /// Registers [url] and returns the loopback URL to give the player.
  Future<Uri> register(
    String url, {
    Map<String, String> headers = const {},
  }) async {
    final server = await _ensureServer();
    final id = '${++_seq}';
    _sources[id] = _Source(Uri.parse(url), Map.of(headers));
    while (_sources.length > _maxSources) {
      final oldest = _sources.keys.first;
      _sources.remove(oldest)?.dispose();
    }
    return Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: server.port,
      path: '/v/$id',
    );
  }

  void release(Uri local) {
    final segments = local.pathSegments;
    if (segments.length == 2 && segments.first == 'v') {
      _sources.remove(segments[1])?.dispose();
    }
  }

  Future<void> close() async {
    for (final s in _sources.values) {
      s.dispose();
    }
    _sources.clear();
    final server = _server;
    _server = null;
    _starting = null;
    await server?.close(force: true);
  }

  Future<HttpServer> _ensureServer() {
    final existing = _server;
    if (existing != null) return Future.value(existing);
    return _starting ??= HttpServer.bind(InternetAddress.loopbackIPv4, 0).then((
      server,
    ) {
      _server = server;
      server.listen(_handle, onError: (_) {});
      return server;
    });
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    var aborted = false;
    unawaited(res.done.then((_) {}, onError: (_) => aborted = true));
    final segments = req.uri.pathSegments;
    final source = segments.length == 2 && segments.first == 'v'
        ? _sources[segments[1]]
        : null;
    if (source == null) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }
    try {
      await _serve(req, source, () => aborted);
    } catch (e) {
      if (kDebugMode) debugPrint('[range-proxy] $e');
      // Leave the upstream clean: a half-read response would otherwise hold
      // its connection and confuse the next request.
      source.resetClient();
      try {
        await res.close();
      } catch (_) {}
    }
  }

  Future<void> _serve(
    HttpRequest req,
    _Source source,
    bool Function() aborted,
  ) async {
    final res = req.response;
    final wanted = _parseRange(req.headers.value(HttpHeaders.rangeHeader));
    final isHead = req.method == 'HEAD';

    // Anything addressed from the end, and HEAD, needs the total size.
    var start = wanted?.start ?? 0;
    int? requestedEnd = wanted?.end;
    if (wanted != null && wanted.suffix != null || isHead) {
      final total = await source.total(chunkBytes);
      if (total == null) {
        res.statusCode = HttpStatus.badGateway;
        await res.close();
        return;
      }
      if (wanted?.suffix != null) {
        start = (total - wanted!.suffix!).clamp(0, total - 1);
        requestedEnd = total - 1;
      }
      if (isHead) {
        res.statusCode = HttpStatus.ok;
        res.headers
          ..set(HttpHeaders.acceptRangesHeader, 'bytes')
          ..set(HttpHeaders.contentLengthHeader, '$total')
          ..set(HttpHeaders.contentTypeHeader, source.contentType);
        await res.close();
        return;
      }
    }

    final firstEnd = requestedEnd == null
        ? start + chunkBytes - 1
        : (start + chunkBytes - 1 < requestedEnd
              ? start + chunkBytes - 1
              : requestedEnd);
    final first = await source.open(start, firstEnd);
    if (first.statusCode != HttpStatus.partialContent &&
        first.statusCode != HttpStatus.ok) {
      res.statusCode = first.statusCode;
      await first.drain<void>();
      await res.close();
      return;
    }
    final total = source.noteResponse(first, start);
    if (total != null && start >= total) {
      res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
      await first.drain<void>();
      await res.close();
      return;
    }
    final lastByte = requestedEnd != null
        ? (total != null && requestedEnd > total - 1 ? total - 1 : requestedEnd)
        : (total != null ? total - 1 : null);

    res.statusCode = wanted == null ? HttpStatus.ok : HttpStatus.partialContent;
    res.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set(HttpHeaders.contentTypeHeader, source.contentType);
    if (lastByte != null) {
      res.headers.set(
        HttpHeaders.contentLengthHeader,
        '${lastByte - start + 1}',
      );
      if (wanted != null) {
        res.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$lastByte/${total ?? '*'}',
        );
      }
    }

    var chunkStart = start;
    var chunkEnd = lastByte != null && firstEnd > lastByte
        ? lastByte
        : firstEnd;
    HttpClientResponse current = first;
    while (true) {
      if (aborted()) {
        source.resetClient();
        return;
      }
      final expected = chunkEnd - chunkStart + 1;
      // With no known end, assume there may be more: running off the end is
      // answered with 416 or a short chunk and stops the loop below.
      final hasMore = lastByte == null ? true : chunkEnd < lastByte;
      Future<HttpClientResponse>? next;
      var nextStart = 0;
      var nextEnd = 0;
      if (hasMore) {
        // Ask for the next piece while this one is still being delivered.
        nextStart = chunkEnd + 1;
        final reach = nextStart + chunkBytes - 1;
        nextEnd = lastByte == null || reach < lastByte ? reach : lastByte;
        next = source.open(nextStart, nextEnd);
        // A prefetch that fails must not surface as an unhandled error.
        unawaited(next.then((_) {}, onError: (_) {}));
      }
      var delivered = 0;
      await res.addStream(
        current.map((data) {
          delivered += data.length;
          return data;
        }),
      );
      // A short chunk is the end of the file (or a server that cut it off).
      if (delivered < expected || !hasMore) break;
      current = await next!;
      if (current.statusCode != HttpStatus.partialContent &&
          current.statusCode != HttpStatus.ok) {
        await current.drain<void>();
        break;
      }
      chunkStart = nextStart;
      chunkEnd = nextEnd;
    }
    await res.close();
  }

  /// `bytes=a-b`, `bytes=a-` or `bytes=-n`; null when absent or unusable.
  static ({int start, int? end, int? suffix})? _parseRange(String? header) {
    if (header == null) return null;
    final m = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header.trim());
    if (m == null) return null;
    final a = m.group(1)!;
    final b = m.group(2)!;
    if (a.isEmpty && b.isEmpty) return null;
    if (a.isEmpty) return (start: 0, end: null, suffix: int.parse(b));
    final start = int.parse(a);
    final end = b.isEmpty ? null : int.parse(b);
    if (end != null && end < start) return null;
    return (start: start, end: end, suffix: null);
  }
}

class _Source {
  _Source(this.uri, this.headers);

  final Uri uri;
  final Map<String, String> headers;
  HttpClient? _client;
  int? _total;
  String contentType = 'video/mp4';

  HttpClient get _http => _client ??= HttpClient()
    ..autoUncompress = false
    ..connectionTimeout = const Duration(seconds: 8)
    ..idleTimeout = const Duration(seconds: 20);

  /// One bounded request, `Range: bytes=start-end`.
  Future<HttpClientResponse> open(int start, int end) async {
    final req = await _http.getUrl(uri).timeout(const Duration(seconds: 10));
    headers.forEach(req.headers.set);
    req.headers
      ..set(HttpHeaders.rangeHeader, 'bytes=$start-$end')
      ..set(HttpHeaders.acceptEncodingHeader, 'identity');
    return req.close().timeout(const Duration(seconds: 15));
  }

  /// Records the size and type the server reported; returns the total
  /// length when it is known.
  int? noteResponse(HttpClientResponse res, int requestedStart) {
    final type = res.headers.contentType?.mimeType;
    if (type != null && type.isNotEmpty) contentType = type;
    final cr = res.headers.value(HttpHeaders.contentRangeHeader);
    if (cr != null) {
      final m = RegExp(r'/(\d+)$').firstMatch(cr);
      if (m != null) _total = int.parse(m.group(1)!);
    } else if (res.statusCode == HttpStatus.ok && res.contentLength >= 0) {
      _total = res.contentLength;
    }
    return _total;
  }

  Future<int?> total(int probeBytes) async {
    if (_total != null) return _total;
    final res = await open(0, 0);
    noteResponse(res, 0);
    await res.drain<void>();
    return _total;
  }

  void resetClient() {
    _client?.close(force: true);
    _client = null;
  }

  void dispose() => resetClient();
}

/// [ChunkedRangeProxy] running in its own isolate.
///
/// A 4K stream is 3–4 MB/s; relaying it on the UI isolate made every byte
/// compete with layout and painting, and the whole app (and the picture
/// itself) stuttered. In a background isolate the relay never touches the
/// UI thread. Same API as the in-process proxy, which it falls back to if
/// the isolate cannot start.
class RangeProxy {
  RangeProxy._();

  static final RangeProxy shared = RangeProxy._();

  /// Bigger pieces mean fewer round trips at 4K bitrates (yt-dlp uses
  /// 10 MiB); 4 MiB still starts quickly.
  static const int _chunkBytes = 4 * 1024 * 1024;

  SendPort? _commands;
  Future<bool>? _starting;
  final Map<int, Completer<String>> _pending = {};
  final Set<String> _fallbackUrls = {};
  int _request = 0;
  ChunkedRangeProxy? _fallback;

  Future<bool> _start() async {
    final replies = ReceivePort();
    final ready = Completer<bool>();
    replies.listen((message) {
      if (message is SendPort) {
        _commands = message;
        if (!ready.isCompleted) ready.complete(true);
      } else if (message is List && message.length == 3) {
        _pending.remove(message[1])?.complete(message[2] as String);
      }
    });
    try {
      await Isolate.spawn(
        _isolateMain,
        replies.sendPort,
        debugName: 'range-proxy',
      );
      return await ready.future.timeout(const Duration(seconds: 5));
    } catch (_) {
      replies.close();
      return false;
    }
  }

  Future<Uri> register(
    String url, {
    Map<String, String> headers = const {},
  }) async {
    final ok = await (_starting ??= _start());
    final commands = _commands;
    if (ok && commands != null) {
      final id = ++_request;
      final reply = Completer<String>();
      _pending[id] = reply;
      commands.send(['register', id, url, Map<String, String>.of(headers)]);
      try {
        return Uri.parse(
          await reply.future.timeout(const Duration(seconds: 5)),
        );
      } catch (_) {
        _pending.remove(id);
      }
    }
    final fallback = _fallback ??= ChunkedRangeProxy(chunkBytes: _chunkBytes);
    final local = await fallback.register(url, headers: headers);
    _fallbackUrls.add(local.toString());
    return local;
  }

  void release(Uri local) {
    if (_fallbackUrls.remove(local.toString())) {
      _fallback?.release(local);
      return;
    }
    _commands?.send(['release', local.toString()]);
  }

  static void _isolateMain(SendPort replies) {
    final proxy = ChunkedRangeProxy(chunkBytes: _chunkBytes);
    final commands = ReceivePort();
    replies.send(commands.sendPort);
    commands.listen((message) async {
      if (message is! List || message.isEmpty) return;
      switch (message[0]) {
        case 'register':
          final local = await proxy.register(
            message[2] as String,
            headers: Map<String, String>.from(message[3] as Map),
          );
          replies.send(['registered', message[1], local.toString()]);
        case 'release':
          proxy.release(Uri.parse(message[1] as String));
      }
    });
  }
}
