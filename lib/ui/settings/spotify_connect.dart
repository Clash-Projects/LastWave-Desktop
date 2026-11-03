import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../features/spotify/spotify_api.dart';
import '../../features/spotify/spotify_auth.dart';
import '../../features/spotify/spotify_web_login.dart';
import '../components/buttons.dart';
import '../components/inputs.dart';
import '../theme/tokens.dart';

/// The two Spotify sign-in routes. Both end in
/// [SpotifyAuth.connectWithSpDc], which exchanges the cookie for a real
/// session token before anything says "connected".

/// Route #1 — sign in inside the system WebView.
Future<void> spotifyConnectWithWebView(
  BuildContext context,
  WidgetRef ref,
) async {
  final cookie = await SpotifyWebLogin.signIn();
  if (!context.mounted) return;
  if (cookie == null) {
    switch (SpotifyWebLogin.lastFailure) {
      case SpotifySignInFailure.unavailable:
        await _notice(
          context,
          'Sign-in window unavailable',
          'No usable system WebView was found. Use "Paste sp_dc" instead.',
        );
      case SpotifySignInFailure.timeout:
        await _notice(
          context,
          'Sign-in timed out',
          'The Spotify sign-in was not completed. Try again, or use '
              '"Paste sp_dc".',
        );
      case SpotifySignInFailure.windowClosed:
      case SpotifySignInFailure.none:
        break; // cancelled by the user
    }
    return;
  }
  await _finish(context, ref, cookie);
}

/// Route #2 (recommended) — sign in with the user's normal browser, where
/// Google / Facebook / Apple logins and Spotify's captcha work, then paste
/// the `sp_dc` cookie. Embedded browsers are refused by Google and often
/// fail Spotify's captcha, so this is the dependable path.
Future<void> spotifyConnectViaBrowser(
  BuildContext context,
  WidgetRef ref,
) async {
  await launchUrl(
    Uri.parse('https://accounts.spotify.com/login'),
    mode: LaunchMode.externalApplication,
  );
  if (!context.mounted) return;
  await spotifyConnectWithCookie(context, ref);
}

/// Paste the `sp_dc` cookie from the user's own browser.
Future<void> spotifyConnectWithCookie(
  BuildContext context,
  WidgetRef ref,
) async {
  final controller = TextEditingController();
  final value = await showDialog<String>(
    context: context,
    builder: (dialogContext) => ContentDialog(
      constraints: const BoxConstraints(maxWidth: 520),
      title: const Text('Connect with sp_dc'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '1. Sign in at open.spotify.com in your own browser.\n'
            '2. Press F12 → Application (Firefox: Storage) → Cookies → '
            'https://open.spotify.com.\n'
            '3. Copy the Value of the "sp_dc" cookie and paste it below.',
            style: WaveType.meta.copyWith(
              color: waveTextSecondary(dialogContext),
            ),
          ),
          const SizedBox(height: 10),
          TextBox(
            controller: controller,
            decoration: waveInputDecoration(),
            placeholder: 'sp_dc value',
            obscureText: true,
            autofocus: true,
            onSubmitted: (v) => Navigator.of(dialogContext).pop(v),
          ),
        ],
      ),
      actions: [
        WaveButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Cancel'),
        ),
        WaveFilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(controller.text),
          child: const Text('Connect'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (value == null || value.trim().isEmpty) return;
  if (!context.mounted) return;
  await _finish(context, ref, value);
}

Future<void> _finish(BuildContext context, WidgetRef ref, String cookie) async {
  final auth = ref.read(spotifyAuthProvider);
  final result = await auth.connectWithSpDc(cookie);
  ref.invalidate(spotifyPlaylistsProvider);
  if (!context.mounted) return;
  switch (result) {
    case SpotifySessionCheck.ok:
      await _notice(
        context,
        'Spotify connected',
        'Your Spotify playlists now appear under Playlists, and Canvas can '
            'use your session.',
      );
    case SpotifySessionCheck.refused:
      await _notice(
        context,
        'Spotify refused the session',
        'The cookie was found but Spotify did not accept it as a signed-in '
            'session (expired or ended). Sign in again, or paste a fresh '
            'sp_dc.',
      );
    case SpotifySessionCheck.unreachable:
      await _notice(
        context,
        'Could not reach Spotify',
        'Check your connection and try again.',
      );
    case SpotifySessionCheck.missing:
      await _notice(context, 'No cookie', 'Nothing was entered.');
  }
}

Future<void> _notice(BuildContext context, String title, String message) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => ContentDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        WaveFilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}
