import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/prefs.dart';
import '../innertube/webview_profile.dart';
import 'jam_client.dart';

/// Above this many browser guests the host's upload (~128 kbps each) and
/// per-guest Opus encoding start to matter.
const jamBrowserGuestWarnAt = 8;

class JamBrowserState {
  final bool on;
  final bool starting;

  /// Browser guests currently receiving audio peer-to-peer.
  final int connected;
  final String error;
  const JamBrowserState({
    this.on = false,
    this.starting = false,
    this.connected = 0,
    this.error = '',
  });
}

/// Host side of Jam "Browser Guest Mode".
///
/// The app's own audio output (native WASAPI process loopback, Windows only,
/// no microphone) arrives as PCM on a loopback socket and is forwarded to a
/// hidden WebView2 page, which sends it to each browser guest over WebRTC.
/// Only SDP signaling goes through the Jam server; audio is peer-to-peer.
class JamBrowserStream extends StateNotifier<JamBrowserState> {
  JamBrowserStream(this._ref) : super(const JamBrowserState()) {
    _ref.listen<JamSnapshot>(jamControllerProvider, (prev, next) {
      final lost = next.phase != JamPhase.active ||
          !next.isMainHost ||
          next.radio ||
          (prev?.webGuests == true && !next.webGuests);
      if ((state.on || state.starting) && lost) stop(tellServer: false);
    });
    _signals = _ref
        .read(jamControllerProvider.notifier)
        .rtcSignals
        .listen((s) {
      if (state.on) _toPage({'t': 'signal', 'from': s.from, 'data': s.data});
    });
  }

  static const _native = MethodChannel('lastwave/app_audio');
  static bool get supported => Platform.isWindows;

  final Ref _ref;
  late final StreamSubscription<JamRtcSignal> _signals;
  final String _token = List.generate(
      16, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  HttpServer? _http;
  ServerSocket? _pcmServer;
  Socket? _pcm;
  WebSocket? _page;
  Webview? _webview;
  Completer<void>? _pageReady;

  JamController get _jam => _ref.read(jamControllerProvider.notifier);

  Future<void> start() async {
    if (state.on || state.starting) return;
    if (!supported) {
      state = const JamBrowserState(
          error: 'Browser guests need LastWave for Windows 10 (2004) or newer.');
      return;
    }
    if (_ref.read(prefsProvider).wasapiExclusive) {
      state = const JamBrowserState(
          error: 'Turn off WASAPI exclusive mode first: exclusive output '
              'skips the Windows mixer, so there is no audio to share.');
      return;
    }
    state = const JamBrowserState(starting: true);
    try {
      await _ensureHostPage();
      await _native.invokeMethod<bool>(
          'start', {'port': _pcmServer!.port, 'token': _token});
      if (!state.starting) {
        // Left the room or lost host while starting.
        await _native.invokeMethod<void>('stop');
        return;
      }
      _jam.setWebGuests(true);
      state = const JamBrowserState(on: true);
    } catch (e) {
      await stop(tellServer: false);
      state = JamBrowserState(error: 'Could not start browser streaming: ${_reason(e)}');
    }
  }

  Future<void> stop({bool tellServer = true}) async {
    final wasOn = state.on;
    state = const JamBrowserState();
    _toPage({'t': 'stop'});
    try {
      await _native.invokeMethod<void>('stop');
    } catch (_) {}
    _pcm?.destroy();
    _pcm = null;
    if (tellServer && wasOn) _jam.setWebGuests(false);
  }

  String _reason(Object e) => e is PlatformException
      ? (e.message ?? e.code)
      : e is TimeoutException
          ? 'the streaming engine did not start'
          : '$e';

  void _toPage(Map<String, dynamic> msg) {
    try {
      _page?.add(jsonEncode(msg));
    } catch (_) {}
  }

  /// Local server + hidden page, created once and reused for the app run
  /// (recreating WebView2 windows flashes the taskbar, see PoTokenEngine).
  Future<void> _ensureHostPage() async {
    if (_pcmServer == null) {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen(_onPcmClient);
      _pcmServer = server;
    }
    if (_http == null) {
      final html = await rootBundle.loadString('assets/jam_host.html');
      final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      http.listen((req) => _onHttp(req, html));
      _http = http;
    }
    if (_page != null) return;
    final ready = _pageReady = Completer<void>();
    if (_webview == null) {
      final folder = await webviewUserDataFolder('jam');
      final webview = await WebviewWindow.create(
        configuration: CreateConfiguration(
          title: 'LastWave Jam Host',
          titleBarHeight: 0,
          windowWidth: 2,
          windowHeight: 2,
          windowPosX: -32000,
          windowPosY: -32000,
          useWindowPositionAndSize: true,
          userDataFolderWindows:
              folder.isEmpty ? 'webview_window_WebView2' : folder,
        ),
      );
      _webview = webview;
      try {
        await webview.setWebviewWindowVisibility(false);
      } catch (_) {}
    }
    _webview!.launch('http://127.0.0.1:${_http!.port}/host?k=$_token');
    await ready.future.timeout(const Duration(seconds: 15));
  }

  Future<void> _onHttp(HttpRequest req, String html) async {
    // The token keeps other local pages/processes off these endpoints.
    if (req.uri.queryParameters['k'] != _token) {
      req.response.statusCode = HttpStatus.forbidden;
      await req.response.close();
      return;
    }
    if (req.uri.path == '/host') {
      req.response.headers.contentType = ContentType.html;
      req.response.write(html);
      await req.response.close();
      return;
    }
    if (req.uri.path == '/pcm' && WebSocketTransformer.isUpgradeRequest(req)) {
      final ws = await WebSocketTransformer.upgrade(req);
      _page?.close();
      _page = ws;
      ws.listen(
        (data) {
          if (data is String) _onPage(data);
        },
        onDone: () {
          if (_page == ws) _page = null;
          if (state.on) stop();
        },
        onError: (_) {},
      );
      return;
    }
    req.response.statusCode = HttpStatus.notFound;
    await req.response.close();
  }

  void _onPage(String text) {
    final Map<String, dynamic> m;
    try {
      m = (jsonDecode(text) as Map).cast<String, dynamic>();
    } catch (_) {
      return;
    }
    switch (m['t']) {
      case 'ready':
        final ready = _pageReady;
        if (ready != null && !ready.isCompleted) ready.complete();
      case 'signal':
        final to = m['to']?.toString() ?? '';
        final data = m['data'];
        if (to.isNotEmpty && data is Map) {
          _jam.sendRtcSignal(to, data.cast<String, dynamic>());
        }
      case 'peers':
        if (state.on) {
          state = JamBrowserState(
              on: true, connected: (m['connected'] as num?)?.toInt() ?? 0);
        }
      case 'error':
        final ready = _pageReady;
        final message = m['message']?.toString() ?? 'streaming failed';
        if (ready != null && !ready.isCompleted) {
          ready.completeError(message);
        } else {
          stop().then((_) => state = JamBrowserState(error: message));
        }
    }
  }

  /// Native capture connects here and sends `token\n` followed by raw
  /// 48 kHz stereo s16 PCM; forwarded to the page in whole frames.
  void _onPcmClient(Socket s) {
    var authed = false;
    final carry = BytesBuilder(copy: false);
    s.listen(
      (chunk) {
        carry.add(chunk);
        var all = carry.takeBytes();
        if (!authed) {
          final nl = all.indexOf(10);
          if (nl < 0) {
            if (all.length > 64) s.destroy();
            carry.add(all);
            return;
          }
          if (_pcm != null || ascii.decode(all.sublist(0, nl), allowInvalid: true) != _token) {
            s.destroy();
            return;
          }
          authed = true;
          _pcm = s;
          all = Uint8List.sublistView(all, nl + 1);
        }
        final whole = all.length - all.length % 4;
        if (whole > 0) {
          try {
            _page?.add(Uint8List.sublistView(all, 0, whole));
          } catch (_) {}
        }
        if (whole < all.length) carry.add(Uint8List.fromList(all.sublist(whole)));
      },
      onDone: () {
        if (_pcm == s) _pcm = null;
      },
      onError: (_) {},
      cancelOnError: true,
    );
  }

  @override
  void dispose() {
    _signals.cancel();
    stop(tellServer: false);
    _page?.close();
    _http?.close(force: true);
    _pcmServer?.close();
    super.dispose();
  }
}

final jamBrowserStreamProvider =
    StateNotifierProvider<JamBrowserStream, JamBrowserState>(
        (ref) => JamBrowserStream(ref));
