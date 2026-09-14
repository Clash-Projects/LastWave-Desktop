import 'package:fluent_ui/fluent_ui.dart';

import '../theme/tokens.dart';
import '../theme/wave_icons.dart';
import 'artwork.dart';
import 'buttons.dart' show LWTooltip;

/// Artwork-led collection header.
///
/// Layout (distinct from the old kicker/ledger CollectionHeader):
/// [160-200px art with ambient ring] [title block: overline, 22px title,
/// meta line, action row: primary Play + ghost Shuffle + sort/filter slot
/// + overflow]. Responsive: stacks vertically under 720px.
class WaveCollectionHero extends StatelessWidget {
  final String overline;
  final String title;
  final String meta;
  final String artworkUrl;
  final IconData fallbackIcon;
  final double artworkSize;
  final List<Widget> primaryActions;
  final List<MenuFlyoutItemBase> overflowItems;
  final Widget? trailing;
  const WaveCollectionHero({
    super.key,
    required this.overline,
    required this.title,
    required this.meta,
    this.artworkUrl = '',
    this.fallbackIcon = WaveIcons.music,
    this.artworkSize = 168,
    this.primaryActions = const [],
    this.overflowItems = const [],
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    // Unconditional canonical artwork: WaveArtwork handles '' via the
    // tonal fallback (label initials), so no flat generic placeholder.
    final art = WaveArtwork(
      url: artworkUrl,
      size: artworkSize,
      radius: WaveRadius.artwork,
      label: title,
    );

    Widget textBlock() => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              overline.toUpperCase(),
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
            const SizedBox(height: 4),
            Text(
              meta,
              style: WaveType.meta.copyWith(
                color: dark
                    ? WaveColors.textSecondary
                    : WaveColors.lightTextSecondary,
              ),
            ),
            const SizedBox(height: WaveSpacing.x8),
            Wrap(
              spacing: WaveSpacing.x4,
              runSpacing: WaveSpacing.x4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ...primaryActions,
                if (overflowItems.isNotEmpty)
                  DropDownButton(
                    placement: FlyoutPlacementMode.bottomRight,
                    items: overflowItems,
                    buttonBuilder: (context, onOpen) => LWTooltip(
                      message: 'More actions',
                      child: SizedBox(
                        width: WaveDensity.hitArea,
                        height: 32,
                        child: Button(
                          onPressed: onOpen,
                          child: const Icon(
                            FluentIcons.more,
                            size: 15,
                          ),
                        ),
                      ),
                    ),
                  ),
                if (trailing != null) trailing!,
              ],
            ),
          ],
        );

    // Content-aware (rail-aware) stacking: LayoutBuilder sees the real
    // content width, unlike MediaQuery window width (+200 rail error).
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 720;
        if (narrow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              art,
              const SizedBox(height: WaveSpacing.x8),
              textBlock(),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            art,
            const SizedBox(width: WaveSpacing.x16),
            Expanded(child: textBlock()),
          ],
        );
      },
    );
  }
}

/// Compact filter bar: Fluent TextBox + optional count + sort slot.
class WaveFilterBar extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final String hint;
  final String? countLabel;
  final Widget? sortSlot;
  const WaveFilterBar({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.hint,
    this.countLabel,
    this.sortSlot,
  });

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 560;
        return Row(
          children: [
            Expanded(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 300),
                child: TextBox(
                  controller: controller,
                  placeholder: hint,
                  prefix: Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Icon(
                      FluentIcons.search,
                      size: 15,
                      color: dark
                          ? WaveColors.textTertiary
                          : WaveColors.lightTextTertiary,
                    ),
                  ),
                  onChanged: onChanged,
                ),
              ),
            ),
            if (countLabel != null && !compact) ...[
              const SizedBox(width: WaveSpacing.x8),
              Flexible(
                child: Text(
                  countLabel!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: WaveType.meta.copyWith(
                    color: dark
                        ? WaveColors.textTertiary
                        : WaveColors.lightTextTertiary,
                  ),
                ),
              ),
            ],
            const Spacer(),
            if (sortSlot != null) Flexible(child: sortSlot!),
          ],
        );
      },
    );
  }
}

/// Page header used by non-collection pages (search, settings…).
class WavePageHeader extends StatelessWidget {
  final String overline;
  final String title;
  final String? subtitle;
  final Widget? action;
  const WavePageHeader({
    super.key,
    required this.overline,
    required this.title,
    this.subtitle,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                overline.toUpperCase(),
                style: WaveType.overline.copyWith(
                  color: waveAccent(context),
                ),
              ),
              const SizedBox(height: 2),
              Text(title, style: WaveType.pageTitle),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  style: WaveType.body.copyWith(
                    color: dark
                        ? WaveColors.textSecondary
                        : WaveColors.lightTextSecondary,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (action != null) action!,
      ],
    );
  }
}


