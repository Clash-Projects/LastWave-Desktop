import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'buttons.dart';
import 'ambient.dart';
import '../theme/motion.dart';
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
          WaveLink(
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
/// Single-row horizontal carousel that lets its tiles lift on hover.
///
/// The lift is a ×1.03 scale plus a drop shadow reaching ~10px above the
/// cover (see [WaveMediaCard]). A plain `ListView` clips to its own
/// viewport, whose height *is* the tile height — so the tile sits flush
/// against the top edge and the whole lift gets shaved off along the
/// rail's top the moment the pointer enters. The cover then reads as
/// "cut off at the top" and the shadow plate as unrounded, worse on the
/// first rail of a page where there is nothing above to hide it.
///
/// This is `SizedBox(height:) > ListView.separated` with one change: the
/// clip keeps only the leading/trailing edges (off-screen tiles still
/// disappear) and leaves the vertical axis alone, so the lift survives.
/// It costs no layout: the overflow lands in the gap the section spacing
/// above the rail already leaves.
class WaveRail extends StatelessWidget {
  final double height;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final IndexedWidgetBuilder? separatorBuilder;
  final EdgeInsetsGeometry padding;
  final ScrollPhysics? physics;

  const WaveRail({
    super.key,
    required this.height,
    required this.itemCount,
    required this.itemBuilder,
    this.separatorBuilder,
    this.padding = EdgeInsets.zero,
    this.physics,
  });

  /// Kept outside the rail's left/right edges so the first and last
  /// tile's ×1.03 scale is not shaved either.
  static const _sideSlack = 6.0;

  @override
  Widget build(BuildContext context) {
    final list = separatorBuilder == null
        ? ListView.builder(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            padding: padding,
            physics: physics,
            itemCount: itemCount,
            itemBuilder: itemBuilder,
          )
        : ListView.separated(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            padding: padding,
            physics: physics,
            itemCount: itemCount,
            itemBuilder: itemBuilder,
            separatorBuilder: separatorBuilder!,
          );
    return SizedBox(
      height: height,
      child: ClipRect(clipper: const _RailClip(), child: list),
    );
  }
}

/// Clips [WaveRail] horizontally, but leaves a tile height of slack above
/// and below so the hover lift is never cut (finite, so the rect stays
/// safe for the engine's clip layer).
class _RailClip extends CustomClipper<Rect> {
  const _RailClip();

  @override
  Rect getClip(Size size) => Rect.fromLTRB(
        -WaveRail._sideSlack,
        -size.height,
        size.width + WaveRail._sideSlack,
        size.height * 2,
      );

  @override
  bool shouldReclip(covariant CustomClipper<Rect> oldClipper) => false;
}

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
              WaveLink(
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
        WaveRail(
          height: height,
          itemCount: children.length,
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          separatorBuilder: (_, _) =>
              const SizedBox(width: WaveSpacing.x8),
          // Staggered entrance per card (group-gated when the page
          // provides a WaveEntranceGroup).
          itemBuilder: (context, i) => WaveEntrance(
            index: i,
            rise: 10,
            child: SizedBox(
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
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);
    final seedColor = _hover
        ? (ref.watch(artworkSeedProvider(widget.artworkUrl)).valueOrNull ??
            const Color(0xFF232838))
        : const Color(0xFF232838);
    return WaveContextMenu(
      items: widget.artist.isEmpty && widget.videoId.isEmpty
          ? () => const []
          : () => waveTrackMenuItems(
                context: context,
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
        onExit: (_) => setState(() {
          _hover = false;
          _pressed = false;
        }),
        child: GestureDetector(
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AnimatedScale(
                scale: _pressed ? 0.97 : (_hover ? 1.03 : 1.0),
                duration: waveMotion(context, WaveMotion.fast),
                curve: Curves.easeOutCubic,
                child: AnimatedContainer(
                  duration: waveMotion(context, WaveMotion.normal),
                  curve: Curves.easeOutCubic,
                  decoration: BoxDecoration(
                    borderRadius: WaveRadius.artworkRadius,
                    boxShadow: [
                      if (_hover) ...[
                        ...WaveElevation.lift(dark),
                        BoxShadow(
                          color: seedColor.withValues(alpha: 0.20),
                          blurRadius: 16,
                          spreadRadius: 2,
                        ),
                      ],
                    ],
                  ),
                  child: Stack(
                    children: [
                      WaveArtwork(
                        url: widget.artworkUrl,
                        size: 160,
                        radius: WaveRadius.artwork,
                        title: widget.title,
                        artist: widget.artist,
                      ),
                      Positioned.fill(
                        child: AnimatedOpacity(
                          duration: waveMotion(context, WaveMotion.fast),
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
                              child: AnimatedScale(
                                scale: _hover ? 1.0 : 0.70,
                                duration: waveMotion(context, WaveMotion.fast),
                                curve: Curves.easeOutBack,
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
                                    child: Icon(
                                      WaveIcons.play,
                                      size: 18,
                                      color: onAccentFor(accent),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
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

class WaveQuickTile extends ConsumerStatefulWidget {
  final String title;
  final String subtitle;
  final String artworkUrl;
  final bool playing;
  final VoidCallback onTap;
  final List<WaveMenuEntry> Function()? menuBuilder;
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
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);
    final tile = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _pressed = false;
      }),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedScale(
          scale: _pressed ? 0.98 : (_hover ? 1.02 : 1.0),
          duration: waveMotion(context, WaveMotion.fast),
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: waveMotion(context, WaveMotion.fast),
            height: 60,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: widget.playing
                  ? accent.withValues(alpha: 0.14)
                  : _hover
                      ? waveHoverWash(context)
                      : (dark
                          ? WaveColors.surface
                          : WaveColors.lightSurface),
              borderRadius: WaveRadius.artworkRadius,
              border: Border.all(
                color: widget.playing
                    ? accent.withValues(alpha: 0.5)
                    : waveDivider(context),
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
      ),
    );
    if (widget.menuBuilder == null) return tile;
    return WaveContextMenu(items: widget.menuBuilder!, child: tile);
  }
}



