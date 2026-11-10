import 'dart:async';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../ui/components/buttons.dart';
import '../../ui/theme/tokens.dart';
import '../innertube/yt_web_login.dart';
import '../spotify/spotify_web_login.dart';

enum MobileCookieLoginProvider { youtubeMusic, spotify }

/// Presents the service's own sign-in page in an app-owned WKWebView.
///
/// The cookie store is read through the native WebView cookie manager. Raw
/// cookie values are never displayed or logged; only the minimum session
/// material required by the existing service connector is returned.
Future<String?> showMobileCookieLogin(
  BuildContext context, {
  required MobileCookieLoginProvider provider,
}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => _MobileCookieLoginDialog(provider: provider),
  );
}

class _MobileCookieLoginDialog extends StatefulWidget {
  final MobileCookieLoginProvider provider;

  const _MobileCookieLoginDialog({required this.provider});

  @override
  State<_MobileCookieLoginDialog> createState() =>
      _MobileCookieLoginDialogState();
}

class _MobileCookieLoginDialogState extends State<_MobileCookieLoginDialog> {
  // YouTube Music rejects the default WKWebView/Safari identity on some iOS
  // releases. Present a current desktop Chrome-compatible identity while
  // retaining WebKit's native cookie store for session capture. This is a
  // compatibility hint only; it does not replace the underlying WebKit engine.
  static const _youtubeUserAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/143.0.0.0 Safari/537.36';

  static const _pollInterval = Duration(seconds: 2);

  Timer? _poller;
  BuildContext? _popupContext;
  String? _pendingCookie;
  String? _reissuedYouTubeUrl;
  String _currentUrl = '';
  bool _loading = true;
  bool _checkingCookies = false;
  String _status = 'Sign in below. LastWave will detect the session automatically.';

  bool get _isYouTube =>
      widget.provider == MobileCookieLoginProvider.youtubeMusic;

  String get _initialUrl => _isYouTube
      ? 'https://music.youtube.com/'
      : 'https://accounts.spotify.com/en/login';

  @override
  void initState() {
    super.initState();
    _currentUrl = _initialUrl;
    _poller = Timer.periodic(_pollInterval, (_) {
      unawaited(_captureSession());
    });
  }

  @override
  void dispose() {
    _poller?.cancel();
    super.dispose();
  }

  void _updateUrl(
    WebUri? url, [
    InAppWebViewController? controller,
  ]) {
    if (url == null || !mounted) return;
    final current = url.toString();
    setState(() {
      _currentUrl = current;
      _loading = false;
      _status = YtWebLogin.isBlankUrl(current) || YtWebLogin.isErrorUrl(current)
          ? 'The sign-in page did not load. Check your connection and reload.'
          : 'Checking for a signed-in session…';
    });
    if (controller != null) unawaited(_inspectYouTubePage(controller));
    unawaited(_captureSession());
  }


  /// Keeps YouTube Universal Links inside WKWebView during Google sign-in.
  ///
  /// iOS may hand a user-gesture navigation to m.youtube.com/signin to the
  /// installed YouTube app. Reissuing the same first-party GET navigation
  /// from the WebView keeps the redirect in this WebKit session so its
  /// YouTube-scoped cookies can be observed by the existing session importer.
  Future<NavigationActionPolicy> _handleYouTubeUniversalLink(
    InAppWebViewController controller,
    NavigationAction action,
  ) async {
    if (!_isYouTube || !Platform.isIOS || !action.isForMainFrame) {
      return NavigationActionPolicy.ALLOW;
    }

    final request = action.request;
    final url = request.url;
    final host = url?.host.toLowerCase() ?? '';
    final isYouTubeHost =
        host == 'youtube.com' || host.endsWith('.youtube.com');
    final method = (request.method ?? 'GET').toUpperCase();
    if (!isYouTubeHost || method != 'GET' || url == null) {
      return NavigationActionPolicy.ALLOW;
    }

    final urlString = url.toString();
    if (_reissuedYouTubeUrl == urlString) {
      _reissuedYouTubeUrl = null;
      return NavigationActionPolicy.ALLOW;
    }

    _reissuedYouTubeUrl = urlString;
    await controller.loadUrl(urlRequest: request);
    return NavigationActionPolicy.CANCEL;
  }

  /// Reuses the page-state diagnostics from YtWebLogin in the iOS WKWebView.
  /// No User-Agent spoofing is applied: Google must see the real WebKit client.
  Future<void> _inspectYouTubePage(InAppWebViewController controller) async {
    if (!_isYouTube || !mounted) return;
    try {
      final raw = await controller.evaluateJavascript(
        source:
            'document.body ? document.body.innerText.slice(0, 1200) : ""',
      ).timeout(const Duration(seconds: 5));
      final pageText = raw?.toString() ?? '';
      if (pageText.isEmpty || !mounted) return;
      final blocked = YtWebLogin.isBrowserBlockedPage(pageText);
      final unsupported = YtWebLogin.isUnsupportedBrowserPage(pageText);
      final passkeyStalled = YtWebLogin.isPasskeyVerificationStall(pageText);
      if (blocked || unsupported || passkeyStalled) {
        setState(() {
          _status = blocked
              ? 'Google blocked this embedded sign-in. Use the cookies.txt import option.'
              : unsupported
                  ? 'YouTube Music says this embedded browser is unsupported. Use Safari to complete sign-in, then import the session cookies.'
                  : 'Google sign-in is waiting for passkey verification. Complete the prompt and return to YouTube Music.';
        });
      }
    } catch (_) {
      // The document may be navigating; the next load/poll will inspect it.
    }
  }

  Future<List<Cookie>> _cookiesFor(String url) async {
    try {
      return await CookieManager.instance().getCookies(url: WebUri(url));
    } catch (_) {
      return const <Cookie>[];
    }
  }

  Future<void> _captureSession() async {
    if (_checkingCookies || !mounted || _pendingCookie != null) return;
    final host = Uri.tryParse(_currentUrl)?.host.toLowerCase() ?? '';

    if (_isYouTube) {
      // Do not accept the Google account page as a completed login. The
      // YouTube-scoped cookies are created after returning to Music.
      if (host != 'music.youtube.com' && host != 'www.youtube.com') return;
    } else if (!SpotifyWebLogin.isPostAuth(_currentUrl)) {
      return;
    }

    _checkingCookies = true;
    try {
      final urls = _isYouTube
          ? const [
              'https://music.youtube.com/',
              'https://accounts.google.com/',
            ]
          : const [
              'https://open.spotify.com/',
              'https://accounts.spotify.com/',
            ];
      final jar = <Cookie>[];
      for (final url in urls) {
        jar.addAll(await _cookiesFor(url));
      }

      if (!mounted || jar.isEmpty) return;

      if (_isYouTube) {
        final header = YtWebLogin.buildCookieHeader(
          jar.map(
            (cookie) => YtJarCookie(
              name: cookie.name.toString(),
              value: cookie.value?.toString() ?? '',
              domain: cookie.domain ?? '',
            ),
          ),
        );
        if (header != null && header.isNotEmpty && mounted) {
          _completeWithCookie(header);
        }
      } else {
        for (final cookie in jar) {
          final name = cookie.name.toString().replaceAll('\x00', '').trim();
          final domain =
              (cookie.domain ?? '').replaceAll('\x00', '').toLowerCase();
          final value =
              cookie.value?.toString().replaceAll('\x00', '').trim() ?? '';
          if (name == 'sp_dc' &&
              domain.contains('spotify.com') &&
              value.isNotEmpty &&
              mounted) {
            _completeWithCookie(value);
            break;
          }
        }
      }
    } catch (_) {
      // A cookie store can briefly be unavailable while WKWebView is
      // committing a navigation. The next poll retries without surfacing
      // credential values or transient native errors.
    } finally {
      _checkingCookies = false;
    }
  }

  void _completeWithCookie(String cookie) {
    if (!mounted || _pendingCookie != null) return;
    _poller?.cancel();
    final popupContext = _popupContext;
    if (popupContext != null && popupContext.mounted) {
      _pendingCookie = cookie;
      Navigator.of(popupContext).pop();
      return;
    }
    Navigator.of(context).pop(cookie);
  }

  /// Websites occasionally open a separate login/consent window. Render
  /// that WKWebView as a nested dialog while keeping it in the same
  /// WebKit cookie store as the parent sign-in window.
  Future<bool?> _openPopup(CreateWindowAction action) async {
    if (!mounted || action.request.url == null) return false;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (popupContext) {
        _popupContext = popupContext;
        final size = MediaQuery.sizeOf(popupContext);
        final popupHeight = (size.height * 0.62).clamp(240.0, 620.0).toDouble();
        return ContentDialog(
          constraints: BoxConstraints(
            maxWidth: 680,
            maxHeight: (size.height * 0.86).clamp(340.0, 760.0).toDouble(),
          ),
          title: const Text('Continue sign-in'),
          content: SizedBox(
            width: (size.width * 0.86).clamp(240.0, 640.0).toDouble(),
            height: popupHeight,
            child: ClipRRect(
              borderRadius: WaveRadius.controlsRadius,
              child: InAppWebView(
                windowId: action.windowId,
                initialSettings: InAppWebViewSettings(
                  javaScriptEnabled: true,
                  domStorageEnabled: true,
                  preferredContentMode: _isYouTube
                            ? UserPreferredContentMode.DESKTOP
                            : UserPreferredContentMode.RECOMMENDED,
                  userAgent: _isYouTube ? _youtubeUserAgent : null,
                  useShouldOverrideUrlLoading: _isYouTube && Platform.isIOS,
                  supportMultipleWindows: false,
                  javaScriptCanOpenWindowsAutomatically: false,
                ),
                shouldOverrideUrlLoading: (controller, navigationAction) =>
                    _handleYouTubeUniversalLink(controller, navigationAction),
                onLoadStart: (controller, url) => _updateUrl(url, controller),
                onLoadStop: (controller, url) => _updateUrl(url, controller),
                onUpdateVisitedHistory: (controller, url, _) => _updateUrl(url, controller),
                onCloseWindow: (_) {
                  if (popupContext.mounted) {
                    Navigator.of(popupContext).maybePop();
                  }
                },
              ),
            ),
          ),
          actions: [
            WaveButton(
              onPressed: () => Navigator.of(popupContext).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );

    _popupContext = null;
    final captured = _pendingCookie;
    _pendingCookie = null;
    if (captured != null && mounted) {
      Navigator.of(context).pop(captured);
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final height = (size.height * 0.68).clamp(260.0, 680.0).toDouble();
    final width = (size.width * 0.88).clamp(260.0, 680.0).toDouble();
    final title = _isYouTube ? 'Sign in to YouTube Music' : 'Sign in to Spotify';

    return ContentDialog(
      constraints: BoxConstraints(
        maxWidth: 720,
        maxHeight: (size.height * 0.9).clamp(360.0, 820.0).toDouble(),
      ),
      title: Text(title),
      content: SizedBox(
        width: width,
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Use the service’s normal sign-in page. LastWave only reads its '
              'session cookies after sign-in and does not display or log them. '
              'If Google blocks the embedded page, close this window and use '
              'the cookies.txt import option instead.',
              style: WaveType.meta.copyWith(
                color: waveTextSecondary(context),
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: ClipRRect(
                borderRadius: WaveRadius.controlsRadius,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    InAppWebView(
                      initialUrlRequest: URLRequest(url: WebUri(_initialUrl)),
                      initialSettings: InAppWebViewSettings(
                        javaScriptEnabled: true,
                        domStorageEnabled: true,
                        preferredContentMode: _isYouTube
                            ? UserPreferredContentMode.DESKTOP
                            : UserPreferredContentMode.RECOMMENDED,
                  userAgent: _isYouTube ? _youtubeUserAgent : null,
                        useShouldOverrideUrlLoading: _isYouTube && Platform.isIOS,
                        supportZoom: true,
                        allowsInlineMediaPlayback: true,
                        mediaPlaybackRequiresUserGesture: false,
                        supportMultipleWindows: true,
                        javaScriptCanOpenWindowsAutomatically: true,
                      ),
                      shouldOverrideUrlLoading: (controller, navigationAction) =>
                          _handleYouTubeUniversalLink(controller, navigationAction),
                      onLoadStart: (controller, url) => _updateUrl(url, controller),
                      onCreateWindow: (_, action) => _openPopup(action),
                      onLoadStop: (controller, url) => _updateUrl(url, controller),
                      onUpdateVisitedHistory: (controller, url, _) => _updateUrl(url, controller),
                      onProgressChanged: (_, progress) {
                        if (mounted) setState(() => _loading = progress < 100);
                      },
                    ),
                    if (_loading)
                      const Align(
                        alignment: Alignment.topCenter,
                        child: ProgressRing(),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _status,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: WaveType.meta.copyWith(
                color: waveTextSecondary(context),
              ),
            ),
          ],
        ),
      ),
      actions: [
        WaveButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
