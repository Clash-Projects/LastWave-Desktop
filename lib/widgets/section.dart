import 'package:fluent_ui/fluent_ui.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../design_system/components.dart' show LwMenuItem;
import '../ui/components/artwork.dart';
import '../ui/components/hero.dart';
import '../ui/components/shelf.dart';
import '../ui/theme/tokens.dart';

/// Thin shims over `lib/ui/components` (Wave headers).
///
/// Constructors are kept for call-site compatibility; presentation uses
/// [LWSectionHeader], [WaveCollectionHero], [WaveFilterBar] and Wave
/// tokens. No `LwColors` / `LwRadius` here.

List<MenuFlyoutItemBase> _flyoutFromLw(List<LwMenuItem> overflow) => [
      for (final m in overflow)
        MenuFlyoutItem(
          leading: Icon(m.icon, size: 13),
          text: Text(m.label),
          onPressed: () => m.onSelected(),
        ),
    ];

/// Section header: kicker + title + subtitle + text action.
class SectionHeader extends StatelessWidget {
  final String title;
  final String? kicker;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;
  const SectionHeader({
    super.key,
    required this.title,
    this.kicker,
    this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        LWSectionHeader(
          title: title,
          overline: kicker,
          actionLabel: actionLabel,
          onAction: onAction,
        ),
        if (subtitle != null && subtitle!.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            subtitle!,
            style: WaveType.meta.copyWith(
              color: dark
                  ? WaveColors.textSecondary
                  : WaveColors.lightTextSecondary,
            ),
          ),
        ],
      ],
    );
  }
}

/// Collection masthead: artwork + overline + title + meta + actions
/// (primary filled, rest in overflow). Delegates to [WaveCollectionHero].
class CollectionHeader extends StatelessWidget {
  final String kicker;
  final String title;
  final String meta;
  final String artworkUrl;
  final bool roundArtwork;
  final IconData fallbackIcon;
  final List<Widget> primaryActions;
  final List<LwMenuItem> overflow;
  final double artworkSize;
  const CollectionHeader({
    super.key,
    required this.kicker,
    required this.title,
    this.meta = '',
    this.artworkUrl = '',
    this.roundArtwork = false,
    this.fallbackIcon = LucideIcons.disc3,
    this.primaryActions = const [],
    this.overflow = const [],
    this.artworkSize = 144,
  });

  @override
  Widget build(BuildContext context) {
    if (!roundArtwork) {
      return WaveCollectionHero(
        overline: kicker,
        title: title,
        meta: meta,
        artworkUrl: artworkUrl,
        fallbackIcon: fallbackIcon,
        artworkSize: artworkSize,
        primaryActions: primaryActions,
        overflowItems: _flyoutFromLw(overflow),
      );
    }
    final dark = waveIsDark(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        WaveArtwork.circle(url: artworkUrl, size: artworkSize),
        const SizedBox(width: WaveSpacing.x16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                kicker.toUpperCase(),
                style: WaveType.overline.copyWith(
                  color: waveAccent(context),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: WaveType.pageTitle,
              ),
              if (meta.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  meta,
                  style: WaveType.meta.copyWith(
                    color: dark
                        ? WaveColors.textSecondary
                        : WaveColors.lightTextSecondary,
                  ),
                ),
              ],
              if (primaryActions.isNotEmpty ||
                  overflow.isNotEmpty) ...[
                const SizedBox(height: WaveSpacing.x4),
                Wrap(
                  spacing: WaveSpacing.x4,
                  runSpacing: WaveSpacing.x4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    ...primaryActions,
                    if (overflow.isNotEmpty)
                      DropDownButton(
                        items: _flyoutFromLw(overflow),
                        buttonBuilder: (context, onOpen) =>
                            Button(
                          onPressed: onOpen,
                          child: const Icon(
                            LucideIcons.ellipsis,
                            size: 14,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Compact filter bar: search field + count + trailing slot.
/// Delegates to [WaveFilterBar].
class LedgerFilterBar extends StatelessWidget {
  final TextEditingController? controller;
  final ValueChanged<String>? onChanged;
  final String hint;
  final String? countLabel;
  final Widget? trailing;
  const LedgerFilterBar({
    super.key,
    this.controller,
    this.onChanged,
    this.hint = 'Filter…',
    this.countLabel,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return WaveFilterBar(
      controller: controller ?? TextEditingController(),
      onChanged: onChanged ?? (_) {},
      hint: hint,
      countLabel: countLabel,
      sortSlot: trailing,
    );
  }
}
