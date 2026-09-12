import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'icons.dart';

import 'tokens.dart';

/// Reusable LastWave desktop components: section headers, tiles,
/// cards, badges, skeletons, empty states.
class SectionHeader extends StatelessWidget {
  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;
  const SectionHeader({
    super.key,
    required this.title,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(title,
            style: LwType.headline.copyWith(
                color: LwColors.textPrimary, fontSize: 17)),
        const Spacer(),
        if (actionLabel != null)
          TextButton(
            onPressed: onAction,
            style: TextButton.styleFrom(
              foregroundColor: LwColors.textSecondary,
              textStyle: LwType.label,
              padding: const EdgeInsets.symmetric(
                  horizontal: LwSpacing.sm, vertical: LwSpacing.xxs),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(actionLabel!),
          ),
      ],
    );
  }
}

class Artwork extends StatelessWidget {
  final String url;
  final double size;
  final double radius;
  final IconData fallbackIcon;
  const Artwork({
    super.key,
    required this.url,
    this.size = 48,
    this.radius = LwRadius.sm,
    this.fallbackIcon = LwIcons.disc3,
  });

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: LwColors.surfaceOverlay,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Icon(fallbackIcon,
          size: size * 0.42, color: LwColors.textTertiary),
    );
    if (url.isEmpty) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: CachedNetworkImage(
        imageUrl: url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        memCacheWidth: (size * 2).round(),
        placeholder: (_, _) => fallback,
        errorWidget: (_, _, _) => fallback,
      ),
    );
  }
}

class TrackTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final String artworkUrl;
  final String badge;
  final String trailing;
  final bool playing;
  final VoidCallback? onTap;
  final VoidCallback? onPlay;
  final VoidCallback? onMore;
  const TrackTile({
    super.key,
    required this.title,
    required this.subtitle,
    this.artworkUrl = '',
    this.badge = '',
    this.trailing = '',
    this.playing = false,
    this.onTap,
    this.onPlay,
    this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: onTap ?? onPlay,
      borderRadius: BorderRadius.circular(LwRadius.sm),
      hoverColor: Colors.white.withValues(alpha: 0.04),
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: LwSpacing.sm, vertical: LwSpacing.xs - 2),
        child: Row(
          children: [
            Artwork(url: artworkUrl, size: 44),
            const SizedBox(width: LwSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: LwType.title.copyWith(
                      fontSize: 13.5,
                      color: playing
                          ? accent
                          : LwColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: LwType.caption.copyWith(
                              color: LwColors.textSecondary),
                        ),
                      ),
                      if (badge.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        QualityBadge(label: badge),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            if (trailing.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: LwSpacing.sm),
                child: Text(trailing,
                    style: LwType.caption
                        .copyWith(color: LwColors.textTertiary)),
              ),
            if (onMore != null)
              IconButton(
                onPressed: onMore,
                icon: const Icon(LwIcons.moreHorizontal, size: 16),
                color: LwColors.textTertiary,
                hoverColor: Colors.white.withValues(alpha: 0.06),
                constraints: const BoxConstraints(
                    minWidth: 32, minHeight: 32),
                padding: EdgeInsets.zero,
              ),
          ],
        ),
      ),
    );
  }
}

class QualityBadge extends StatelessWidget {
  final String label;
  const QualityBadge({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    final isHiRes = label == 'HI-RES';
    final color = isHiRes
        ? LwColors.hiRes
        : label.contains('LOSSLESS')
            ? LwColors.losslessGreen
            : LwColors.textTertiary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.55)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: LwType.micro.copyWith(fontSize: 8.5, color: color),
      ),
    );
  }
}

class MediaCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final String artworkUrl;
  final double width;
  final VoidCallback? onTap;
  final VoidCallback? onPlay;
  const MediaCard({
    super.key,
    required this.title,
    required this.subtitle,
    this.artworkUrl = '',
    this.width = 156,
    this.onTap,
    this.onPlay,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: InkWell(
        onTap: onTap ?? onPlay,
        borderRadius: BorderRadius.circular(LwRadius.md),
        hoverColor: Colors.white.withValues(alpha: 0.04),
        child: Padding(
          padding: const EdgeInsets.all(LwSpacing.xs),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                children: [
                  Artwork(
                      url: artworkUrl,
                      size: width - LwSpacing.md,
                      radius: LwRadius.sm),
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: _HoverPlayButton(onPlay: onPlay ?? onTap),
                  ),
                ],
              ),
              const SizedBox(height: LwSpacing.xs),
              Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: LwType.title.copyWith(fontSize: 12.5)),
              Text(subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: LwType.caption
                      .copyWith(color: LwColors.textSecondary)),
            ],
          ),
        ),
      ),
    );
  }
}

class _HoverPlayButton extends StatefulWidget {
  final VoidCallback? onPlay;
  const _HoverPlayButton({this.onPlay});
  @override
  State<_HoverPlayButton> createState() => _HoverPlayButtonState();
}

class _HoverPlayButtonState extends State<_HoverPlayButton> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedOpacity(
        opacity: _hover ? 1 : 0.85,
        duration: LwMotion.fast,
        child: Material(
          color: accent,
          shape: const CircleBorder(),
          child: InkWell(
            onTap: widget.onPlay,
            customBorder: const CircleBorder(),
            child: const Padding(
              padding: EdgeInsets.all(7),
              child: Icon(LwIcons.play,
                  size: 14, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}

class SkeletonBox extends StatefulWidget {
  final double width;
  final double height;
  final double radius;
  const SkeletonBox({
    super.key,
    required this.width,
    required this.height,
    this.radius = LwRadius.sm,
  });
  @override
  State<SkeletonBox> createState() => _SkeletonBoxState();
}

class _SkeletonBoxState extends State<SkeletonBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1200))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: LwColors.surfaceOverlay.withValues(
              alpha: 0.45 + _c.value * 0.3),
          borderRadius: BorderRadius.circular(widget.radius),
        ),
      ),
    );
  }
}

class SkeletonRow extends StatelessWidget {
  final int count;
  const SkeletonRow({super.key, this.count = 6});
  @override
  Widget build(BuildContext context) {
    return Column(
      children: List.generate(
        count,
        (_) => const Padding(
          padding: EdgeInsets.symmetric(
              horizontal: LwSpacing.sm, vertical: 5),
          child: Row(
            children: [
              SkeletonBox(width: 44, height: 44),
              SizedBox(width: LwSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SkeletonBox(width: 180, height: 12),
                    SizedBox(height: 6),
                    SkeletonBox(width: 120, height: 10),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(LwSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: LwColors.surfaceRaised,
                borderRadius:
                    BorderRadius.circular(LwRadius.lg),
                border:
                    Border.all(color: LwColors.outlineSoft),
              ),
              child: Icon(icon,
                  size: 28, color: LwColors.textTertiary),
            ),
            const SizedBox(height: LwSpacing.md),
            Text(title, style: LwType.title),
            const SizedBox(height: 4),
            Text(subtitle,
                textAlign: TextAlign.center,
                style: LwType.caption
                    .copyWith(color: LwColors.textSecondary)),
            if (actionLabel != null) ...[
              const SizedBox(height: LwSpacing.md),
              FilledButton(
                onPressed: onAction,
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
