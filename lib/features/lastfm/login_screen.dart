import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../design_system/icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design_system/tokens.dart';
import 'auth_repository.dart';

/// Last.fm sign-in via browser OAuth (web-auth token exchange).
/// The app's own API keys (from .env) are used — no custom keys.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});
  @override
  ConsumerState<LoginScreen> createState() =>
      _LoginScreenState();
}

class _LoginScreenState
    extends ConsumerState<LoginScreen> {
  WebAuthHandshake? _handshake;
  bool _busy = false;
  String? _error;

  Future<void> _beginWebAuth() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final handshake = await ref
          .read(authRepositoryProvider.notifier)
          .beginWebAuth();
      setState(() => _handshake = handshake);
      final uri = Uri.parse(handshake.url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri,
            mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _completeWebAuth() async {
    final handshake = _handshake;
    if (handshake == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(authRepositoryProvider.notifier)
          .completeWebAuth(handshake.token);
      if (mounted) context.go('/home');
    } catch (e) {
      setState(() => _error =
          'Not approved yet — approve in the browser, then retry.\n$e');
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authRepositoryProvider);
    return Center(
      child: ConstrainedBox(
        constraints:
            const BoxConstraints(maxWidth: 480),
        child: ListView(
          shrinkWrap: true,
          padding:
              const EdgeInsets.all(LwSpacing.xl),
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [
                  Theme.of(context).colorScheme.primary,
                  Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.55),
                ]),
                borderRadius:
                    BorderRadius.circular(18),
              ),
              child: const Icon(
                  LwIcons.disc3,
                  color: Colors.white,
                  size: 30),
            ),
            const SizedBox(height: LwSpacing.lg),
            const Text('Connect Last.fm',
                style: LwType.display),
            const SizedBox(height: 6),
            const Text(
              'Sync scrobbles, taste profile and discovery feed. '
              'You can also continue as guest with charts only.',
              style: LwType.body,
            ),
            const SizedBox(height: LwSpacing.lg),
            if (_error != null)
              Container(
                padding:
                    const EdgeInsets.all(LwSpacing.sm),
                decoration: BoxDecoration(
                  color: LwColors.danger
                      .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(
                      LwRadius.sm),
                ),
                child: Text(_error!,
                    style: LwType.caption.copyWith(
                        color: LwColors.danger)),
              ),
            if (_error != null)
              const SizedBox(height: LwSpacing.md),
            FilledButton.icon(
              onPressed:
                  _busy ? null : _beginWebAuth,
              icon: const Icon(LwIcons.globe,
                  size: 16),
              label: Text(_handshake == null
                  ? 'Approve in browser'
                  : 'Restart approval'),
            ),
            if (_handshake != null) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed:
                    _busy ? null : _completeWebAuth,
                icon: const Icon(LwIcons.check,
                    size: 16),
                label: const Text(
                    'I approved — finish sign-in'),
              ),
            ],
            const SizedBox(height: LwSpacing.lg),
            TextButton(
              onPressed: () => context.go('/home'),
              child: const Text(
                  'Continue as guest (charts only)'),
            ),
            if (auth.status == AuthStatus.signingIn ||
                _busy)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: LinearProgressIndicator(),
              ),
          ],
        ),
      ),
    );
  }
}
