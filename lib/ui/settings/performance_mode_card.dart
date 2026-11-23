import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n/app_localizations.dart';
import '../../features/performance/performance_controller.dart';
import '../theme/tokens.dart';

/// Minimal, localized, polished Performance Mode card for Settings -> General.
///
/// Default state is compact (~60px). Expanding displays the lag explainer
/// and active/planned optimizations checklist with localized titles and
/// dynamic headers reflecting whether Performance Mode is ON or OFF.
class PerformanceModeCard extends ConsumerStatefulWidget {
  const PerformanceModeCard({super.key});

  @override
  ConsumerState<PerformanceModeCard> createState() => _PerformanceModeCardState();
}

class _PerformanceModeCardState extends ConsumerState<PerformanceModeCard> {
  bool _expanded = false;

  // Clean success green that stays distinct even when the user accent is red.
  static const _successGreen = Color(0xFF107C41);

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final stroke = theme.resources.cardStrokeColorDefault;
    final isPerfOn = ref.watch(performanceModeProvider);
    final isModest = ref.watch(isModestHardwareProvider);
    final optimizations = ref.watch(performanceOptimizationsProvider);
    final l10n = context.l10n;

    return Container(
      decoration: BoxDecoration(
        color: theme.resources.cardBackgroundFillColorDefault,
        border: Border.all(color: stroke),
        borderRadius: BorderRadius.circular(WaveRadius.floating),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Main compact row
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: isPerfOn
                        ? _successGreen.withValues(alpha: 0.15)
                        : theme.resources.subtleFillColorSecondary,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    FluentIcons.speed_high,
                    size: 18,
                    color: isPerfOn ? _successGreen : waveTextSecondary(context),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            l10n.performanceMode,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (isModest) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: theme.resources.subtleFillColorSecondary,
                                border: Border.all(
                                  color: stroke,
                                  width: 0.8,
                                ),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                l10n.performanceModeRecommended,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w500,
                                  color: waveTextSecondary(context),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        isPerfOn
                            ? l10n.performanceModeDescOn
                            : l10n.performanceModeDescOff,
                        style: TextStyle(
                          fontSize: 12,
                          color: isPerfOn
                              ? _successGreen
                              : waveTextSecondary(context),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                ToggleSwitch(
                  checked: isPerfOn,
                  onChanged: (val) {
                    ref
                        .read(performanceModeProvider.notifier)
                        .setPerformanceMode(val);
                  },
                ),
              ],
            ),
          ),

          // Minimal Expand / Collapse bar
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _expanded = !_expanded),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: theme.resources.subtleFillColorTertiary.withValues(alpha: 0.3),
                borderRadius: BorderRadius.vertical(
                  bottom: Radius.circular(_expanded ? 0 : WaveRadius.floating),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _expanded ? FluentIcons.chevron_up : FluentIcons.chevron_down,
                    size: 11,
                    color: waveTextSecondary(context),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _expanded
                        ? 'Hide optimization details'
                        : (isPerfOn
                            ? 'View active optimizations'
                            : 'View details & optimizations'),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: waveTextSecondary(context),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Expanded Drawer (only when user clicks)
          if (_expanded) ...[
            Divider(style: DividerThemeData(horizontalMargin: EdgeInsets.zero)),

            // Explainer
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.resources.subtleFillColorSecondary,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: stroke, width: 0.5),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          FluentIcons.info,
                          size: 13,
                          color: waveTextSecondary(context),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          l10n.performanceModeWhyLagTitle,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      l10n.performanceModeWhyLagBody,
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.45,
                        color: waveTextSecondary(context),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Dynamic Checklist Header: ACTIVE OPTIMIZATIONS (if ON) vs WHAT WILL BE OPTIMIZED (if OFF)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        isPerfOn
                            ? l10n.performanceModeOptimizationsActive
                            : l10n.performanceModeOptimizationsPlanned,
                        style: TextStyle(
                          fontSize: 10.5,
                          letterSpacing: 0.5,
                          fontWeight: FontWeight.w700,
                          color: isPerfOn
                              ? _successGreen
                              : waveTextSecondary(context),
                        ),
                      ),
                      if (isPerfOn) ...[
                        const SizedBox(width: 6),
                        Container(
                          width: 6,
                          height: 6,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: _successGreen,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    isPerfOn
                        ? l10n.performanceModeOptimizationsActiveSub
                        : l10n.performanceModeOptimizationsPlannedSub,
                    style: TextStyle(
                      fontSize: 11,
                      color: waveTextSecondary(context),
                    ),
                  ),
                  const SizedBox(height: 10),
                  for (final opt in optimizations) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Icon(
                              isPerfOn
                                  ? FluentIcons.check_mark
                                  : FluentIcons.radio_bullet,
                              size: 13,
                              color: isPerfOn
                                  ? _successGreen
                                  : waveTextSecondary(context).withValues(alpha: 0.4),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  opt.title,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: isPerfOn
                                        ? waveTextPrimary(context)
                                        : waveTextSecondary(context),
                                  ),
                                ),
                                const SizedBox(height: 1),
                                Text(
                                  opt.subtitle,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: waveTextSecondary(context),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (isPerfOn) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: _successGreen.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                opt.impact,
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w500,
                                  color: _successGreen,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
