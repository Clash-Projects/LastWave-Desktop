import 'package:fluent_ui/fluent_ui.dart';

import '../theme/tokens.dart';

/// Loading / empty / error states shared by every collection page.
///
/// Bounded, quiet, and never indefinite: loading shows a short ring +
/// label, empty shows icon + title + action, error shows an InfoBar +
/// retry. No full-page skeleton that stays visible forever.
class WaveLoading extends StatelessWidget {
  final String label;
  const WaveLoading({super.key, this.label = 'Loading…'});

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(WaveSpacing.x28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 28,
              height: 28,
              child: ProgressRing(strokeWidth: 3),
            ),
            const SizedBox(height: WaveSpacing.x8),
            Text(
              label,
              style: WaveType.meta.copyWith(
                color: dark
                    ? WaveColors.textTertiary
                    : WaveColors.lightTextTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class WaveEmpty extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;
  const WaveEmpty({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    // Editorial empty: small tonal visual (64px, 8px radius — never a
    // giant centred icon in black space) + title + subtitle + action.
    // Pages keep their header visible above this so header + state read
    // as one composition, not two separate messages.
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(WaveSpacing.x28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  borderRadius:
                      BorderRadius.circular(WaveRadius.artwork),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      (dark
                              ? Colors.white
                              : Colors.black)
                          .withValues(alpha: 0.08),
                      (dark
                              ? Colors.white
                              : Colors.black)
                          .withValues(alpha: 0.03),
                    ],
                  ),
                  border: Border.all(
                    color: dark
                        ? WaveColors.outlineSoft
                        : WaveColors.lightOutline,
                  ),
                ),
                child: Icon(
                  icon,
                  size: 24,
                  color: dark
                      ? WaveColors.textSecondary
                      : WaveColors.lightTextSecondary,
                ),
              ),
              const SizedBox(height: WaveSpacing.x8),
              Text(
                title,
                style: WaveType.sectionTitle.copyWith(fontSize: 16),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: WaveType.meta.copyWith(
                  color: dark
                      ? WaveColors.textSecondary
                      : WaveColors.lightTextSecondary,
                ),
                textAlign: TextAlign.center,
              ),
              if (actionLabel != null) ...[
                const SizedBox(height: WaveSpacing.x8),
                FilledButton(
                  onPressed: onAction,
                  child: Text(actionLabel!),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class WaveError extends StatelessWidget {
  final String title;
  final String message;
  final VoidCallback? onRetry;
  const WaveError({
    super.key,
    required this.title,
    required this.message,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(WaveSpacing.x16),
      child: InfoBar(
        title: Text(title),
        content: Text(message),
        severity: InfoBarSeverity.error,
        action: onRetry == null
            ? null
            : Button(
                onPressed: onRetry,
                child: const Text('Retry'),
              ),
      ),
    );
  }
}

/// Canonical empty-state alias: 52px circle icon + title + subtitle +
/// optional action. See [WaveEmpty].
class LWEmptyState extends WaveEmpty {
  const LWEmptyState({
    super.key,
    required super.icon,
    required super.title,
    required super.subtitle,
    super.actionLabel,
    super.onAction,
  });
}

/// Canonical loading-state alias. See [WaveLoading].
class LWLoadingState extends WaveLoading {
  const LWLoadingState({super.key, super.label});
}
