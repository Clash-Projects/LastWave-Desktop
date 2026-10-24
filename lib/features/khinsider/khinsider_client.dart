/// Reads downloads.khinsider.com (no official API) for the "Video game
/// soundtracks" search mode. Pages are fetched with a plain GET; when
/// Cloudflare answers with a JavaScript challenge, the page is loaded in a
/// WebView window instead (which passes it), and its clearance cookie is
/// reused by the next plain GET with the same user agent.
///
/// Port of LastWave-Native's KhInsiderClient.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/stream_models.dart';
import '../../core/storage/prefs.dart';
import '../innertube/webview_profile.dart';
import 'khinsider_parser.dart';

class KhInsiderException implements Exception {
  final String message;
  const KhInsiderException(this.message);
  @override
  String toString() => message;
}

class KhInsiderClient {
  final Prefs _prefs;
  KhInsiderClient(this._prefs);

  /// Browser user agent; replaced by the WebView's own once it solved a
  /// challenge, so its clearance cookie stays valid.
  String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36';
  String _cookies = '';

  final _albumCache = <String, KhAlbum>{};
  final _fileCache = <String, Map<String, String>>{};
  List<(String, String)>? _platformCache;

  KhFormat get format =>
      _prefs.khinsiderFormat == 'mp3' ? KhFormat.mp3 : KhFormat.flac;

  Future<void> setFormat(KhFormat f) => _prefs.setKhinsiderFormat(f.extension);

  Future<List<KhAlbumSummary>> search(String query) async {
    final trimmed = query.trim();
    // KHInsider refuses searches shorter than three characters.
    if (trimmed.length < 3) return const [];
    final page = await _fetch(KhInsiderParser.searchUrl(trimmed));
    // An exact match redirects straight to the album page.
    if (KhInsiderParser.isAlbumPage(page.finalUrl)) {
      final id = KhInsiderParser.albumIdOf(page.finalUrl);
      final album = id == null
          ? null
          : KhInsiderParser.parseAlbum(id, page.html);
      if (album == null) return const [];
      _remember(_albumCache, album.id, album, 24);
      return [
        KhAlbumSummary(
          id: album.id,
          name: album.name,
          thumbnailUrl: album.coverUrl,
          platform: album.platforms.isEmpty ? null : album.platforms.first,
          type: album.type,
          year: album.year,
        ),
      ];
    }
    return KhInsiderParser.parseSearch(page.html);
  }

  Future<KhAlbumPage> albumList(KhBrowseList list, {int page = 1}) async {
    final html = (await _fetch(KhInsiderParser.listUrl(list.path, page))).html;
    final parsed = KhInsiderParser.parseAlbumPage(html, page);
    return list.paged
        ? parsed
        : KhAlbumPage(albums: parsed.albums, page: page, hasNext: false);
  }

  /// Every platform KHInsider lists; the menu's main platforms if the page
  /// can't be read.
  Future<List<(String, String)>> platforms() async {
    final cached = _platformCache;
    if (cached != null) return cached;
    List<(String, String)> parsed;
    try {
      parsed = KhInsiderParser.parsePlatforms(
        (await _fetch('${KhInsiderParser.baseUrl}/console-list')).html,
      );
    } catch (_) {
      parsed = const [];
    }
    if (parsed.isEmpty) return KhInsiderParser.mainPlatforms;
    return _platformCache = parsed;
  }

  Future<KhAlbum> album(String albumId, {bool forceRefresh = false}) async {
    final cached = _albumCache[albumId];
    if (!forceRefresh && cached != null) return cached;
    final page = await _fetch(KhInsiderParser.albumUrl(albumId));
    final album = KhInsiderParser.parseAlbum(albumId, page.html);
    if (album == null) throw KhInsiderException('Album not found: $albumId');
    _remember(_albumCache, albumId, album, 24);
    return album;
  }

  /// Direct file URL for a track page in the chosen format (MP3 when the
  /// album has no FLAC).
  Future<String> resolveFileUrl(String pagePath, {KhFormat? format}) async {
    var files = _fileCache[pagePath];
    if (files == null) {
      final page = await _fetch(KhInsiderParser.trackPageUrl(pagePath));
      files = KhInsiderParser.parseTrackFiles(page.html, page.finalUrl);
      if (files.isNotEmpty) _remember(_fileCache, pagePath, files, 400);
    }
    final url = KhInsiderParser.pickFile(files, format ?? this.format);
    if (url == null) throw KhInsiderException('No audio file on $pagePath');
    return url;
  }

  /// Player/downloader stream for a `khinsider://` playback URI.
  Future<ResolvedStream?> resolveStream(String playbackUri) async {
    final pagePath = KhInsiderParser.pagePathOf(playbackUri);
    if (pagePath == null) return null;
    final url = await resolveFileUrl(pagePath);
    final flac = url.split('?').first.toLowerCase().endsWith('.flac');
    return ResolvedStream(
      url: url,
      mimeType: flac ? 'audio/flac' : 'audio/mpeg',
      bitrateKbps: flac ? 1411 : 320,
      audioCodec: flac ? 'FLAC' : 'MP3',
      cacheKey: 'khinsider:$pagePath:${flac ? 'flac' : 'mp3'}',
      requestHeaders: fileRequestHeaders(),
      isLossless: flac,
    );
  }

  /// Headers to send with file requests (same browser identity as pages;
  /// the files live on another host, so no site cookie).
  Map<String, String> fileRequestHeaders() => {
    'User-Agent': _userAgent,
    'Referer': '${KhInsiderParser.baseUrl}/',
  };

  static void _remember<V>(Map<String, V> cache, String key, V value, int max) {
    cache.remove(key);
    cache[key] = value;
    if (cache.length > max) cache.remove(cache.keys.first);
  }

  Future<_Page> _fetch(String url) async {
    final direct = await _get(url);
    // Album and list pages often answer a plain dart:io GET with a block
    // page (or a JS check) that a real browser never sees: both go through
    // the WebView.
    if (!KhInsiderParser.isCloudflareChallenge(direct.html) &&
        !KhInsiderParser.isCloudflareBlock(direct.html)) {
      return direct;
    }
    // One browser navigation at a time.
    final previous = _browserQueue;
    final done = Completer<void>();
    _browserQueue = done.future;
    try {
      await previous;
      final page = await _browserGet(url);
      if (KhInsiderParser.isCloudflareBlock(page.html)) {
        throw const KhInsiderException(
          'KHInsider blocked this network (Cloudflare)',
        );
      }
      if (KhInsiderParser.isCloudflareChallenge(page.html)) {
        throw const KhInsiderException(
          'KHInsider is behind a Cloudflare check that could not be passed',
        );
      }
      return page;
    } finally {
      done.complete();
    }
  }

  Future<_Page> _get(String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers
        ..set('User-Agent', _userAgent)
        ..set(
          'Accept',
          'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        )
        ..set('Accept-Language', 'en-US,en;q=0.9');
      if (_cookies.isNotEmpty) req.headers.set('Cookie', _cookies);
      final res = await req.close().timeout(const Duration(seconds: 20));
      final body = await res
          .transform(const Utf8Decoder(allowMalformed: true))
          .join()
          .timeout(const Duration(seconds: 20));
      final ok = res.statusCode >= 200 && res.statusCode < 300;
      if (!ok &&
          !KhInsiderParser.isCloudflareChallenge(body) &&
          !KhInsiderParser.isCloudflareBlock(body)) {
        throw KhInsiderException('KHInsider HTTP ${res.statusCode}');
      }
      final finalUrl = res.redirects.isEmpty
          ? url
          : Uri.parse(url).resolveUri(res.redirects.last.location).toString();
      return _Page(body, finalUrl);
    } finally {
      client.close();
    }
  }

  Webview? _browser;
  Future<void> _browserQueue = Future.value();
  Timer? _browserIdle;

  /// One WebView window, kept while KHInsider is in use, that Cloudflare
  /// treats as the real browser it is. Shown only while a check is on
  /// screen (the user may have to tick a box), closed after two idle
  /// minutes.
  Future<Webview> _ensureBrowser() async {
    final existing = _browser;
    if (existing != null) return existing;
    if (!await WebviewWindow.isWebviewAvailable()) {
      throw const KhInsiderException(
        'KHInsider needs a browser check, but WebView2 is not available',
      );
    }
    final folder = await webviewUserDataFolder('khinsider');
    final w = await WebviewWindow.create(
      configuration: CreateConfiguration(
        title: 'KHInsider check',
        windowWidth: 480,
        windowHeight: 600,
        userDataFolderWindows: folder.isEmpty
            ? 'webview_window_WebView2'
            : folder,
      ),
    );
    unawaited(
      w.onClose.then((_) {
        if (identical(_browser, w)) _browser = null;
      }),
    );
    w.launch('about:blank', triggerOnUrlRequestEvent: false);
    await w.setWebviewWindowVisibility(false).catchError((_) {});
    return _browser = w;
  }

  /// Opens [url] in the browser window and returns its HTML once the page
  /// (not a Cloudflare check) has loaded. Keeps the window's cookies and
  /// user agent so the next direct request may pass on its own.
  Future<_Page> _browserGet(String url) async {
    _browserIdle?.cancel();
    final w = await _ensureBrowser();
    Future<String> js(String code) async =>
        _unquote(await w.evaluateJavaScript(code).catchError((_) => null));
    try {
      // Tag the page on screen so the poll can tell it from the new one.
      await js("document.documentElement.setAttribute('data-lw-old','1')");
      await js('window.location.href = ${jsonEncode(url)}');
      var shown = false;
      for (var attempt = 0; attempt < 90; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (!identical(_browser, w)) {
          throw const KhInsiderException('KHInsider check window was closed');
        }
        if (await js("document.documentElement.hasAttribute('data-lw-old')") ==
                'true' ||
            await js('document.readyState') != 'complete') {
          continue;
        }
        final html = await js('document.documentElement.outerHTML');
        if (html.isEmpty || KhInsiderParser.isCloudflareChallenge(html)) {
          // The check usually passes by itself; after ~3 s let the user see
          // (and tick) it.
          if (!shown && attempt >= 6) {
            shown = true;
            await w.setWebviewWindowVisibility(true).catchError((_) {});
          }
          continue;
        }
        if (shown) await w.setWebviewWindowVisibility(false).catchError((_) {});
        final ua = await js('navigator.userAgent');
        if (ua.isNotEmpty) _userAgent = ua;
        final cookies = await w.getAllCookies().catchError((_) => <Never>[]);
        _cookies = [
          for (final c in cookies)
            if (c.domain.contains('khinsider.com'))
              '${_cookiePart(c.name)}=${_cookiePart(c.value)}',
        ].where((c) => c.length > 1 && !_badCookie.hasMatch(c)).join('; ');
        final href = await js('window.location.href');
        return _Page(html, href.isEmpty ? url : href);
      }
      throw const KhInsiderException('KHInsider took too long to answer');
    } finally {
      _browserIdle = Timer(const Duration(minutes: 2), () {
        final idle = _browser;
        _browser = null;
        try {
          idle?.close();
        } catch (_) {}
      });
    }
  }

  /// The plugin's cookie names and values come NUL-padded (see
  /// YtWebLogin._normValue); dart:io refuses them in a header.
  static String _cookiePart(String raw) => raw.replaceAll('\x00', '').trim();
  static final _badCookie = RegExp(r'[\x00-\x1f\x7f;]');

  /// `evaluateJavaScript` returns JSON-encoded strings.
  static String _unquote(String? raw) {
    if (raw == null || raw == 'null') return '';
    try {
      final v = jsonDecode(raw);
      return v is String ? v : raw;
    } catch (_) {
      return raw;
    }
  }
}

class _Page {
  final String html;
  final String finalUrl;
  const _Page(this.html, this.finalUrl);
}

final khInsiderClientProvider = Provider<KhInsiderClient>(
  (ref) => KhInsiderClient(ref.watch(prefsProvider)),
);
