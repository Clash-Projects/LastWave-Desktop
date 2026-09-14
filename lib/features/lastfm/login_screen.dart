import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design_system/components.dart';
import '../../design_system/icons.dart';
import '../../design_system/tokens.dart';
import 'auth_repository.dart';

/// Editorial connect ledger: centered masthead + inline steps.
/// Replaces boxed shad card with flat ledger hierarchy.
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
          'Not approved yet — approve in the browser, then retry.');
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final accent = Theme.of(context).colorScheme.primary;
    return Center(
      child: ConstrainedBox(
        constraints:
            const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding:
              const EdgeInsets.all(LwSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: accent.withValues(
                      alpha: 0.12),
                  borderRadius: BorderRadius.circular(
                      LwRadius.md),
                ),
                child: Icon(
                    LucideIcons.audioWaveform,
                    color: accent,
                    size: 22),
              ),
              const SizedBox(height: LwSpacing.md),
              const EdKicker('System · Account'),
              const Text('Connect Last.fm',
                  style: LwType.display),
              const SizedBox(height: 4),
              Text(
                  'Sync scrobbles, taste profile and discovery feed. Sign-in is required.',
                  style: LwType.body.copyWith(
                      color: dark
                          ? LwColors.textSecondary
                          : LwColors
                              .lightTextSecondary)),
              const SizedBox(height: LwSpacing.md),
              if (_error != null)
                Container(
                  padding: const EdgeInsets.all(
                      LwSpacing.sm),
                  decoration: BoxDecoration(
                    color: LwColors.danger
                        .withValues(alpha: 0.1),
                    borderRadius:
                        BorderRadius.circular(
                            LwRadius.sm),
                    border: Border.all(
                        color: LwColors.danger
                            .withValues(alpha: 0.4)),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                          LucideIcons.circleAlert,
                          size: 15,
                          color: LwColors.danger),
                      const SizedBox(
                          width: LwSpacing.xs),
                      Expanded(
                          child: Text(_error!,
                              style:
                                  LwType.caption)),
                    ],
                  ),
                ),
              if (_error != null)
                const SizedBox(height: LwSpacing.sm),
              Row(
                children: [
                  Expanded(
                    child: LwButton(
                      onPressed:
                          _busy ? null : _beginWebAuth,
                      leading: _busy
                          ? const SizedBox(
                              width: 15,
                              height: 15,
                              child:
                                  CircularProgressIndicator(
                                      strokeWidth: 2))
                          : const Icon(
                              LucideIcons.globe,
                              size: 15),
                      child: Text(_handshake ==
                              null
                          ? 'Approve in browser'
                          : 'Restart approval'),
                    ),
                  ),
                ],
              ),
              if (_handshake != null) ...[
                const SizedBox(
                    height: LwSpacing.xs),
                Row(
                  children: [
                    Expanded(
                      child: LwButton.outline(
                        onPressed: _busy
                            ? null
                            : _completeWebAuth,
                        leading: const Icon(
                            LucideIcons.badgeCheck,
                            size: 15),
                        child: const Text(
                            'I approved — finish sign-in'),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: LwSpacing.xs),
            ],
          ),
        ),
      ),
    );
  }
}
