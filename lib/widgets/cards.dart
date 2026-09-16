import 'package:fluent_ui/fluent_ui.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../ui/components/artwork.dart';
import '../ui/components/buttons.dart';
import '../ui/components/menus.dart';
import '../ui/theme/tokens.dart';
import 'track_tile.dart';

/// Thin shims over `lib/ui/components` (Wave shelf cards).
///
/// Constructors are kept for call-site compatibility; all presentation
/// uses [WaveArtwork], [WaveContextMenu], Wave type/spacing/motion tokens
/// and lucide glyphs. No `LwColors` / `LwRadius` here.

List<MenuFlyoutItemBase> _flyoutFrom(List<TrackMenuItem> menu) => [
      for (final m in menu)
        if (m.children.isEmpty)
          MenuFlyoutItem(
            leading: Icon(m.icon, size: 13),
            text: Text(m.label),
            onPressed: () => m.onSelected(),
          )
        else
          MenuFlyoutSubItem(
            leading: Icon(m.icon, size: 13),
            text: Text(m.label),
            items: (context) => _flyoutFrom(m.children),
          ),
    ];

/// Editorial rail tile (168px): full-bleed artwork, caption below,
/// centered play veil on hover.
class MediaCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final String artworkUrl;
  final double width;
  final int staggerIndex;
  final VoidCallback? onTap;
  final VoidCallback? onPlay;
  final List<TrackMenuItem> menu;
  const MediaCard({
    super.key,
    required this.title,
    required this.subtitle,
    this.artworkUrl = '',
    this.width = 168,
    this.staggerIndex = 0,
    this.onTap,
    this.onPlay,
    this.menu = const [],
  });

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final tile = SizedBox(
      width: width,
      child: _HoverPlayCard(
        artworkUrl: artworkUrl,
        size: width,
        title: title,
        artist: subtitle,
        onPlay: onPlay ?? onTap,
      ),
    );
    final captioned = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        tile,
        const SizedBox(height: WaveSpacing.x4),
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: WaveType.trackTitle.copyWith(
            fontSize: 13,
            color: dark
                ? WaveColors.textPrimary
                : WaveColors.lightTextPrimary,
          ),
        ),
        Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: WaveType.meta.copyWith(
            fontSize: 12,
            color: dark
                ? WaveColors.textSecondary
                : WaveColors.lightTextSecondary,
          ),
        ),
      ],
    );
    final tapped = MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap ?? onPlay,
        child: captioned,
      ),
    );
    if (menu.isEmpty) return tapped;
    return WaveContextMenu(
      items: () => _flyoutFrom(menu),
      child: tapped,
    );
  }
}

class _HoverPlayCard extends StatefulWidget {
  final String artworkUrl;
  final double size;
  final String title;
  final String artist;
  final VoidCallback? onPlay;
  const _HoverPlayCard({
    required this.artworkUrl,
    required this.size,
    this.title = '',
    this.artist = '',
    this.onPlay,
  });

  @override
  State<_HoverPlayCard> createState() => _HoverPlayCardState();
}

class _HoverPlayCardState extends State<_HoverPlayCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Stack(
        children: [
          WaveArtwork(
            url: widget.artworkUrl,
            size: widget.size,
            radius: WaveRadius.artwork,
            title: widget.title,
            artist: widget.artist,
            label: widget.title,
          ),
          Positioned.fill(
            child: AnimatedOpacity(
              opacity: _hover ? 1 : 0,
              duration: WaveMotion.fast,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.42),
                  borderRadius: WaveRadius.artworkRadius,
                ),
                child: Center(
                  child: LWPlaybackButton(
                    playing: false,
                    primary: true,
                    tooltip: 'Play',
                    onPressed: widget.onPlay,
                  ),
                ),
              ),
            ),
          ),
          ],
        ),
      );
  }
}

/// Editorial artist tile: centered circle, name, optional rank chip.
class ArtistCard extends StatelessWidget {
  final String name;
  final String artworkUrl;
  final int staggerIndex;
  final int? rank;
  final VoidCallback? onTap;
  const ArtistCard({
    super.key,
    required this.name,
    this.artworkUrl = '',
    this.staggerIndex = 0,
    this.rank,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: 148,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                children: [
                  WaveArtwork.circle(
                    url: artworkUrl,
                    size: 112,
                    label: name,
                    title: name,
                    artist: name,
                  ),
                  if (rank != null)
                    Positioned(
                      left: 0,
                      top: 0,
                      child: WaveChip(label: '#$rank'),
                    ),
                ],
              ),
              const SizedBox(height: WaveSpacing.x4),
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: WaveType.trackTitle.copyWith(
                  fontSize: 13,
                  color: dark
                      ? WaveColors.textPrimary
                      : WaveColors.lightTextPrimary,
                ),
              ),
              Text(
                'Artist',
                style: WaveType.meta.copyWith(
                  fontSize: 11.5,
                  color: dark
                      ? WaveColors.textTertiary
                      : WaveColors.lightTextTertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact quick-pick tile: artwork + stacked text + hover play.
class QuickPickTile extends StatefulWidget {
  final String title;
  final String subtitle;
  final String artworkUrl;
  final bool playing;
  final VoidCallback? onTap;
  final List<TrackMenuItem> menu;
  const QuickPickTile({
    super.key,
    required this.title,
    required this.subtitle,
    this.artworkUrl = '',
    this.playing = false,
    this.onTap,
    this.menu = const [],
  });

  @override
  State<QuickPickTile> createState() => _QuickPickTileState();
}

class _QuickPickTileState extends State<QuickPickTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final accent = waveAccent(context);
    final dark = waveIsDark(context);
    final tile = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: WaveMotion.fast,
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
            borderRadius: WaveRadius.floatingRadius,
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
                    size: 44,
                    radius: WaveRadius.artwork,
                    title: widget.title,
                    artist: widget.subtitle,
                    label: widget.title,
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
                              ? LucideIcons.audioLines
                              : LucideIcons.play,
                          size: 16,
                          color: widget.playing
                              ? accent
                              : Colors.white,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: WaveSpacing.x8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: WaveType.trackTitle.copyWith(
                        fontSize: 12.5,
                        color: widget.playing
                            ? accent
                            : (dark
                                ? WaveColors.textPrimary
                                : WaveColors.lightTextPrimary),
                      ),
                    ),
                    Text(
                      widget.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: WaveType.meta.copyWith(
                        fontSize: 11.5,
                        color: dark
                            ? WaveColors.textSecondary
                            : WaveColors.lightTextSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (widget.menu.isEmpty) return tile;
    return WaveContextMenu(
      items: () => _flyoutFrom(widget.menu),
      child: tile,
    );
  }
}
