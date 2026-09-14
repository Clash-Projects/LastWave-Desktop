import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design_system/components.dart';
import '../design_system/icons.dart';
import '../design_system/tokens.dart';
import 'artwork.dart';
import 'quality_badge.dart';

/// A context-menu entry for track/album rows and cards.
class TrackMenuItem {
  final String label;
  final IconData icon;
  final bool destructive;
  final VoidCallback onSelected;
  final List<TrackMenuItem> children;
  const TrackMenuItem({
    required this.label,
    required this.icon,
    this.destructive = false,
    required this.onSelected,
    this.children = const [],
  });

  LwMenuItem get asLw => LwMenuItem(
      label: label,
      icon: icon,
      destructive: destructive,
      onSelected: onSelected);
}

/// Editorial ledger track row (52px): index · artwork · title ledger ·
/// meta · contextual actions.
///
/// Replaces the old 60px boxed row. Hierarchy is typographic and
/// columnar — readable even in monochrome. Position ticks never rebuild
/// this; only identity/metadata changes do.
class TrackTile extends StatefulWidget {
  final String title;
  final String subtitle;
  final String? album;
  final String artworkUrl;
  final String badge;
  final String? duration;
  final String? trailing;
  final int? index;
  final String? meta;
  final bool playing;
  final bool selected;
  final bool showLike;
  final bool isLiked;
  final VoidCallback? onToggleLike;
  final VoidCallback? onTap;
  final VoidCallback? onPlay;
  final List<TrackMenuItem> menu;
  final Widget? leadingDrag;

  const TrackTile({
    super.key,
    required this.title,
    required this.subtitle,
    this.album,
    this.artworkUrl = '',
    this.badge = '',
    this.duration,
    this.trailing,
    this.index,
    this.meta,
    this.playing = false,
    this.selected = false,
    this.showLike = false,
    this.isLiked = false,
    this.onToggleLike,
    this.onTap,
    this.onPlay,
    this.menu = const [],
    this.leadingDrag,
  });

  @override
  State<TrackTile> createState() => _TrackTileState();
}

class _TrackTileState extends State<TrackTile> {
  bool _hover = false;
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  String? get _meta {
    if (widget.meta != null) return widget.meta;
    if (widget.duration != null) return widget.duration;
    return widget.trailing;
  }

  void _openMenu() {
    final box = context.findRenderObject() as RenderBox?;
    final at = box == null
        ? Offset.zero
        : box.localToGlobal(
            Offset(box.size.width - 40, box.size.height));
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final dark = Theme.of(context).brightness == Brightness.dark;
    showMenu(
      context: context,
      position: RelativeRect.fromRect(
          Rect.fromPoints(at, at), Offset.zero & overlay.size),
      color: dark ? LwColors.surfaceRaised : LwColors.lightSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LwRadius.md),
        side: BorderSide(
            color:
                dark ? LwColors.outline : LwColors.lightOutline),
      ),
      items: [
        for (final m in widget.menu)
          PopupMenuItem(
            onTap: m.onSelected,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(m.icon, size: 14),
                const SizedBox(width: LwSpacing.sm),
                Text(m.label, style: LwType.body),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final action = widget.onTap ?? widget.onPlay;
    final showActions =
        _hover || _focus.hasFocus || widget.playing || widget.isLiked;
    final meta = _meta;

    final row = MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: Focus(
        focusNode: _focus,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.enter ||
                  event.logicalKey == LogicalKeyboardKey.space)) {
            action?.call();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: AnimatedContainer(
          duration: LwMotion.fast,
          curve: LwMotion.standard,
          height: LwDensity.ledgerRow,
          decoration: BoxDecoration(
            color: widget.selected
                ? accent.withValues(alpha: 0.12)
                : _hover
                    ? (dark
                        ? Colors.white.withValues(alpha: 0.045)
                        : Colors.black.withValues(alpha: 0.04))
                    : Colors.transparent,
            borderRadius:
                BorderRadius.circular(LwRadius.sm),
            border: _focus.hasFocus
                ? Border.all(
                    color: accent.withValues(alpha: 0.5))
                : Border.all(color: Colors.transparent),
          ),
          child: InkWell(
            onTap: action,
            borderRadius:
                BorderRadius.circular(LwRadius.sm),
            hoverColor: Colors.transparent,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: LwSpacing.sm),
              child: Row(
                children: [
                  if (widget.leadingDrag != null) ...[
                    widget.leadingDrag!,
                    const SizedBox(width: 4),
                  ],
                  // Index ledger column.
                  if (widget.index != null)
                    SizedBox(
                      width: 28,
                      child: widget.playing
                          ? const _EqDots()
                          : Text(
                              '${widget.index!}',
                              style: LwType.caption.copyWith(
                                color: dark
                                    ? LwColors.textTertiary
                                    : LwColors
                                        .lightTextTertiary,
                                fontFeatures: const [
                                  FontFeature
                                      .tabularFigures()
                                ],
                              ),
                              textAlign: TextAlign.center,
                            ),
                    )
                  else if (widget.playing)
                    const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: _EqDots(),
                    ),
                  Artwork(url: widget.artworkUrl, size: 40),
                  const SizedBox(width: LwSpacing.sm),
                  Expanded(
                    child: Column(
                      mainAxisAlignment:
                          MainAxisAlignment.center,
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: LwType.title.copyWith(
                            fontSize: 13,
                            color: widget.playing
                                ? accent
                                : (dark
                                    ? LwColors.textPrimary
                                    : LwColors
                                        .lightTextPrimary),
                          ),
                        ),
                        const SizedBox(height: 1),
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                [
                                  widget.subtitle,
                                  if ((widget.album ?? '')
                                      .isNotEmpty)
                                    widget.album!,
                                ].join(' • '),
                                maxLines: 1,
                                overflow:
                                    TextOverflow.ellipsis,
                                style: LwType.caption
                                    .copyWith(
                                        fontSize: 12,
                                        color: dark
                                            ? LwColors
                                                .textSecondary
                                            : LwColors
                                                .lightTextSecondary),
                              ),
                            ),
                            if (widget
                                .badge.isNotEmpty) ...[
                              const SizedBox(width: 6),
                              QualityBadge(
                                  label: widget.badge),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (meta != null && meta.isNotEmpty)
                    SizedBox(
                      width: 88,
                      child: Text(meta,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right,
                          style: LwType.caption.copyWith(
                              color: dark
                                  ? LwColors.textTertiary
                                  : LwColors
                                      .lightTextTertiary,
                              fontFeatures: const [
                                FontFeature
                                    .tabularFigures()
                              ])),
                    ),
                  AnimatedOpacity(
                    opacity: showActions ? 1 : 0,
                    duration: LwMotion.fast,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.showLike)
                          LwIconButton(
                            tooltip: widget.isLiked
                                ? 'Unlike'
                                : 'Like',
                            icon: Icon(
                              LucideIcons.heart,
                              size: 15,
                              color: widget.isLiked
                                  ? accent
                                  : null,
                            ),
                            onPressed:
                                widget.onToggleLike,
                          ),
                        if (widget.menu.isNotEmpty)
                          LwIconButton(
                            tooltip: 'More',
                            icon: const Icon(
                              LucideIcons.moreHorizontal,
                              size: 16,
                            ),
                            onPressed: _openMenu,
                          )
                        else
                          const SizedBox(width: 32),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    if (widget.menu.isEmpty) return row;
    return LwContextMenuRegion(
      items: widget.menu.map((m) => m.asLw).toList(),
      child: row,
    );
  }
}

class _EqDots extends StatefulWidget {
  const _EqDots();
  @override
  State<_EqDots> createState() => _EqDotsState();
}

class _EqDotsState extends State<_EqDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 840))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    if (!LwMotionScope.motionOK(context)) {
      return SizedBox(
        width: 28,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (final h in [12.0, 9.0, 11.0])
              Container(
                  width: 2.5, height: h, color: accent),
          ].expand((w) => [w, const SizedBox(width: 2)]).toList()
            ..removeLast(),
        ),
      );
    }
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        double h(int i) =>
            [12.0, 9.0, 11.0][i] *
            (0.45 + 0.55 * ((_c.value + i * 0.33) % 1.0));
        return SizedBox(
          width: 28,
          height: 12,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < 3; i++) ...[
                Container(
                    width: 2.5, height: h(i), color: accent),
                if (i < 2) const SizedBox(width: 2),
              ],
            ],
          ),
        );
      },
    );
  }
}
