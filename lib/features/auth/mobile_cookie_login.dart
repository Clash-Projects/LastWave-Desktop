import 'dart:async';

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
  static const _pollInterval = Duration(seconds: 2);

  Timer? _poller;
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

  void _updateUrl(WebUri? url) {
    if (url == null || !mounted) return;
    setState(() {
      _currentUrl = url.toString();
      _loading = false;
      _status = 'Checking for a signed-in session…';
    });
    unawaited(_captureSession());
  }

  Future<List<Cookie>> _cookiesFor(String url) async {
    try {
      return await CookieManager.instance().getCookies(url: WebUri(url));
    } catch (_) {
      return const <Cookie>[];
    }
  }

  Future<void> _captureSession() async {
    if (_checkingCookies || !mounted) return;
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
          Navigator.of(context).pop(header);
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
            Navigator.of(context).pop(value);
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
              'session cookies after sign-in and does not display or log them.',
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
                        supportZoom: true,
                        allowsInlineMediaPlayback: true,
                        mediaPlaybackRequiresUserGesture: false,
                        supportMultipleWindows: true,
                      ),
                      onLoadStart: (_, url) => _updateUrl(url),
                      onLoadStop: (_, url) => _updateUrl(url),
                      onUpdateVisitedHistory: (_, url, _) => _updateUrl(url),
                      onProgressChanged: (_, progress) {
                        if (mounted) setState(() => _loading = progress < 100);
                      },
                    ),
                    if (_loading)
                      const Align(
                        alignment: Alignment.topCenter,
                        child: ProgressBar(),
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
