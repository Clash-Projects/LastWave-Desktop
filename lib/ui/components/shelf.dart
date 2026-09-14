import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/tokens.dart';
import '../theme/wave_icons.dart';
import 'artwork.dart';
import 'menus.dart';

/// Canonical section header: optional overline + 15px title + count +
/// action link.
///
/// Hierarchy is typographic (no boxes): overline labels the group,
/// [WaveType.sectionTitle] names it, count is quiet meta, action is a
/// text link.
class LWSectionHeader extends StatelessWidget {
  final String title;
  final String? overline;
  final int? count;
  final String? actionLabel;
  final VoidCallback? onAction;
  const LWSectionHeader({
    super.key,
    required this.title,
    this.overline,
    this.count,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final tertiary =
        dark ? WaveColors.textTertiary : WaveColors.lightTextTertiary;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (overline != null && overline!.isNotEmpty)
                Text(
                  overline!.toUpperCase(),
                  style: WaveType.overline.copyWith(color: tertiary),
                ),
              if (overline != null && overline!.isNotEmpty)
                const SizedBox(height: 2),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: WaveType.sectionTitle,
                    ),
                  ),
                  if (count != null) ...[
                    const SizedBox(width: 6),
                    Text(
                      '$count',
                      style: WaveType.meta.copyWith(
                        color: tertiary,
                        fontFeatures: const [
                          FontFeature.tabularFigures()
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
        if (actionLabel != null && onAction != null)
          HyperlinkButton(
            onPressed: onAction,
            child: Text(
              actionLabel!,
              style: WaveType.label.copyWith(
                color: waveAccent(context),
              ),
            ),
          ),
      ],
    );
  }
}

/// Horizontal shelf with a distinct header (title + count + play-all).
///
/// Structurally different from the old uniform boxed rails: header owns
/// hierarchy, cards are artwork-led with hover play affordances.
class WaveShelf extends StatelessWidget {
  final String title;
  final String? subtitle;
  final int count;
  final VoidCallback? onPlayAll;
  final double cardWidth;
  final double height;
  final List<Widget> children;
  const WaveShelf({
    super.key,
    required this.title,
    this.subtitle,
    this.count = 0,
    this.onPlayAll,
    this.cardWidth = 160,
    this.height = 216,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: WaveType.sectionTitle),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: WaveType.meta.copyWith(
                        color: dark
                            ? WaveColors.textSecondary
                            : WaveColors.lightTextSecondary,
                      ),
                    ),
                ],
              ),
            ),
            if (count > 0)
              Text(
                '$count',
                style: WaveType.meta.copyWith(
                  color: dark
                      ? WaveColors.textTertiary
                      : WaveColors.lightTextTertiary,
                ),
              ),
            if (onPlayAll != null) ...[
              const SizedBox(width: WaveSpacing.x8),
              HyperlinkButton(
                onPressed: onPlayAll,
                child: Text(
                  'Play all',
                  style: WaveType.label.copyWith(color: accent),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: WaveSpacing.x8),
        SizedBox(
          height: height,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: children.length,
            separatorBuilder: (_, _) =>
                const SizedBox(width: WaveSpacing.x8),
            itemBuilder: (context, i) => SizedBox(
              width: cardWidth,
              child: children[i],
            ),
          ),
        ),
      ],
    );
  }
}

/// Artwork-led media card with centered hover play affordance.
class WaveMediaCard extends ConsumerStatefulWidget {
  final String title;
  final String subtitle;
  final String artworkUrl;
  final VoidCallback onTap;
  final VoidCallback? onPlay;
  final String titleFallback;
  final String artist;
  final String videoId;
  const WaveMediaCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.artworkUrl,
    required this.onTap,
    this.onPlay,
    this.titleFallback = '',
    this.artist = '',
    this.videoId = '',
  });

  @override
  ConsumerState<WaveMediaCard> createState() => _WaveMediaCardState();
}

class _WaveMediaCardState extends ConsumerState<WaveMediaCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);
    return WaveContextMenu(
      items: widget.artist.isEmpty && widget.videoId.isEmpty
          ? () => const []
          : () => waveTrackMenuItems(
                ref: ref,
                title: widget.artist.isEmpty
                    ? widget.title
                    : widget.titleFallback.isEmpty
                        ? widget.title
                        : widget.titleFallback,
                artist: widget.artist,
                artworkUrl: widget.artworkUrl,
                videoId: widget.videoId,
              ),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  WaveArtwork(
                    url: widget.artworkUrl,
                    size: 160,
                    radius: WaveRadius.artwork,
                  ),
                  Positioned.fill(
                    child: AnimatedOpacity(
                      duration: WaveMotion.fast,
                      opacity: _hover ? 1 : 0,
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: WaveRadius.artworkRadius,
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.55),
                            ],
                          ),
                        ),
                        child: Center(
                          child: GestureDetector(
                            onTap: widget.onPlay ?? widget.onTap,
                            child: Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: accent,
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black
                                        .withValues(alpha: 0.4),
                                    blurRadius: 12,
                                  ),
                                ],
                              ),
                              child: const Icon(
                                WaveIcons.play,
                                size: 18,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: WaveType.trackTitle.copyWith(
                  color: dark
                      ? WaveColors.textPrimary
                      : WaveColors.lightTextPrimary,
                ),
              ),
              Text(
                widget.subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: WaveType.meta.copyWith(
                  color: dark
                      ? WaveColors.textSecondary
                      : WaveColors.lightTextSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class WaveArtistCard extends StatelessWidget {
  final String name;
  final String artworkUrl;
  final int rank;
  final VoidCallback onTap;
  const WaveArtistCard({
    super.key,
    required this.name,
    required this.artworkUrl,
    required this.rank,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Stack(
            children: [
              WaveArtwork.circle(url: artworkUrl, size: 120),
              Positioned(
                left: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '#$rank',
                    style: WaveType.label.copyWith(
                      color: Colors.white,
                      fontSize: 11,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: WaveType.trackTitle.copyWith(
              color: dark
                  ? WaveColors.textPrimary
                  : WaveColors.lightTextPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact quick-access tile (48px art + stacked text + hover play).
class WaveQuickTile extends ConsumerStatefulWidget {
  final String title;
  final String subtitle;
  final String artworkUrl;
  final bool playing;
  final VoidCallback onTap;
  final List<MenuFlyoutItemBase> Function()? menuBuilder;
  const WaveQuickTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.artworkUrl,
    this.playing = false,
    required this.onTap,
    this.menuBuilder,
  });

  @override
  ConsumerState<WaveQuickTile> createState() => _WaveQuickTileState();
}

class _WaveQuickTileState extends ConsumerState<WaveQuickTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);
    final tile = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: WaveMotion.fast,
          height: 60,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: widget.playing
                ? accent.withValues(alpha: 0.14)
                : _hover
                    ? (dark ? Colors.white : Colors.black)
                        .withValues(alpha: WaveState.hoverAlpha)
                    : (dark
                        ? WaveColors.surface
                        : WaveColors.lightSurface),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: widget.playing
                  ? accent.withValues(alpha: 0.5)
                  : (dark
                      ? WaveColors.outlineSoft
                      : WaveColors.lightOutlineSoft),
            ),
          ),
          child: Row(
            children: [
              Stack(
                children: [
                  WaveArtwork(
                    url: widget.artworkUrl,
                    size: 48,
                    radius: WaveRadius.artwork,
                  ),
                  if (_hover || widget.playing)
                    Positioned.fill(
                      child: Container(
                        decoration: BoxDecoration(
                          color:
                              Colors.black.withValues(alpha: 0.5),
                          borderRadius: WaveRadius.artworkRadius,
                        ),
                        child: Icon(
                          widget.playing
                              ? WaveIcons.pause
                              : WaveIcons.play,
                          size: 16,
                          color: Colors.white,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: WaveType.trackTitle.copyWith(fontSize: 12.5),
                    ),
                    Text(
                      widget.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: WaveType.meta.copyWith(fontSize: 11.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (widget.menuBuilder == null) return tile;
    return WaveContextMenu(items: widget.menuBuilder!, child: tile);
  }
}



