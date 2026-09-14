import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/stream_models.dart';
import '../../features/library/playlists.dart';
import '../../features/player/playback_service.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';
import 'artwork.dart';
import 'buttons.dart' show LWTooltip;
import 'desktop_table.dart' show WaveEqDots;
import 'menus.dart';

export 'desktop_table.dart'
    show WaveDesktopTable, WaveSortDir, WaveEqDots;

/// Dense desktop song row.
///
/// New code should prefer [WaveDesktopTable] (desktop_table.dart) — one
/// virtualized, sortable, keyboard-navigable table shared by Search, Home,
/// Discover and Collections. This single-row widget stays for existing
/// consumers and renders one [WaveDesktopTable]-identical row.

/// Dense desktop song row.
///
/// `01  [cover]  Title / Artist   Album   ♡  …  5:14`
/// Hover: play replaces number, secondary actions appear.
/// Playing: small accent indicator. No borders around rows.
class WaveTrackRow extends ConsumerStatefulWidget {
  final String title;
  final String artist;
  final String album;
  final String artworkUrl;
  final String videoId;
  final PlayableTrack? playable;
  final int? index;
  final bool playing;
  final bool isCurrent;
  final String? meta;
  final String? duration;
  final String? removeLabel;
  final VoidCallback? onRemove;
  final VoidCallback? onTap;
  final bool showLike;
  const WaveTrackRow({
    super.key,
    required this.title,
    required this.artist,
    this.album = '',
    this.artworkUrl = '',
    this.videoId = '',
    this.playable,
    this.index,
    this.playing = false,
    this.isCurrent = false,
    this.meta,
    this.duration,
    this.removeLabel,
    this.onRemove,
    this.onTap,
    this.showLike = true,
  });

  @override
  ConsumerState<WaveTrackRow> createState() => _WaveTrackRowState();
}

class _WaveTrackRowState extends ConsumerState<WaveTrackRow> {
  bool _hover = false;
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _activate() {
    if (widget.onTap != null) {
      widget.onTap!();
      return;
    }
    final track = widget.playable ??
        PlayableTrack(
          title: widget.title,
          artist: widget.artist,
          album: widget.album,
          artworkUrl: widget.artworkUrl,
          videoId: widget.videoId,
        );
    ref.read(playbackServiceProvider.notifier).play(
          track,
          sourceLabel: 'Track list',
        );
  }

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);
    final liked = ref
        .watch(playlistRepositoryProvider.notifier)
        .likedKeys()
        .contains(
          (widget.playable?.queueKey) ??
              '${widget.title.toLowerCase()}|${widget.artist.toLowerCase()}',
        );

    final bg = widget.isCurrent
        ? accent.withValues(alpha: 0.0)
        : _hover
            ? (dark ? Colors.white : Colors.black)
                .withValues(alpha: WaveState.hoverAlpha)
            : Colors.transparent;

    final row = Focus(
      focusNode: _focus,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent) {
          if (event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.numpadEnter) {
            _activate();
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.delete &&
              widget.onRemove != null) {
            widget.onRemove!();
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: () {
            _focus.requestFocus();
            _activate();
          },
          onDoubleTap: _activate,
          child: AnimatedContainer(
            duration: WaveMotion.fast,
            height: WaveDensity.trackRow,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            color: bg,
            child: Row(
              children: [
                // Gutter: number → play on hover, equalizer when playing.
                SizedBox(
                  width: 30,
                  child: Center(
                    child: widget.playing
                        ? const WaveEqDots()
                        : _hover
                            ? Icon(
                                WaveIcons.play,
                                size: 14,
                                color: dark
                                    ? WaveColors.textPrimary
                                    : WaveColors.lightTextPrimary,
                              )
                            : Text(
                                widget.index != null
                                    ? widget.index!
                                        .toString()
                                        .padLeft(2, '0')
                                    : '',
                                style: WaveType.meta.copyWith(
                                  fontSize: 12,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures()
                                  ],
                                  color: widget.isCurrent
                                      ? accent
                                      : (dark
                                          ? WaveColors.textTertiary
                                          : WaveColors
                                              .lightTextTertiary),
                                ),
                                textAlign: TextAlign.center,
                              ),
                  ),
                ),
                WaveArtwork(
                  url: widget.artworkUrl,
                  videoId: widget.videoId,
                  size: WaveDensity.trackArt,
                  radius: 6,
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 5,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: WaveType.trackTitle.copyWith(
                          color: widget.isCurrent
                              ? accent
                              : (dark
                                  ? WaveColors.textPrimary
                                  : WaveColors.lightTextPrimary),
                        ),
                      ),
                      Text(
                        widget.artist,
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
                Expanded(
                  flex: 3,
                  child: widget.album.isEmpty
                      ? const SizedBox.shrink()
                      : Text(
                          widget.album,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: WaveType.meta.copyWith(
                            color: dark
                                ? WaveColors.textTertiary
                                : WaveColors.lightTextTertiary,
                          ),
                        ),
                ),
                // Secondary actions appear on hover / current.
                AnimatedOpacity(
                  duration: WaveMotion.fast,
                  opacity: (_hover ||
                          widget.isCurrent ||
                          liked)
                      ? 1
                      : 0,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.showLike)
                        _RowGlyph(
                          tooltip: liked ? 'Unlike' : 'Like',
                          icon: liked
                              ? WaveIcons.likedFill
                              : WaveIcons.liked,
                          active: liked,
                          onTap: () {
                            ref
                                .read(playlistRepositoryProvider
                                    .notifier)
                                .toggleLiked(
                                  StoredTrack(
                                    name: widget.title,
                                    artist: widget.artist,
                                    artworkUrl: widget.artworkUrl,
                                    videoId: widget.videoId,
                                  ),
                                );
                          },
                        ),
                      _RowGlyph(
                        tooltip: 'More',
                        icon: WaveIcons.more,
                        menuItems: waveTrackMenuItems(
                          ref: ref,
                          title: widget.title,
                          artist: widget.artist,
                          artworkUrl: widget.artworkUrl,
                          videoId: widget.videoId,
                          playable: widget.playable,
                          removeLabel: widget.removeLabel,
                          onRemove: widget.onRemove,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 44,
                  child: Text(
                    widget.duration ??
                        widget.meta ??
                        '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: WaveType.meta.copyWith(
                      fontFeatures: const [
                        FontFeature.tabularFigures()
                      ],
                      color: dark
                          ? WaveColors.textTertiary
                          : WaveColors.lightTextTertiary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    return WaveContextMenu(
      items: () => waveTrackMenuItems(
        ref: ref,
        title: widget.title,
        artist: widget.artist,
        artworkUrl: widget.artworkUrl,
        videoId: widget.videoId,
        playable: widget.playable,
        removeLabel: widget.removeLabel,
        onRemove: widget.onRemove,
      ),
      child: row,
    );
  }
}

class _RowGlyph extends StatefulWidget {
  final String tooltip;
  final IconData icon;
  final bool active;
  final VoidCallback? onTap;
  final List<MenuFlyoutItemBase>? menuItems;
  const _RowGlyph({
    required this.tooltip,
    required this.icon,
    this.active = false,
    this.onTap,
    this.menuItems,
  });
  @override
  State<_RowGlyph> createState() => _RowGlyphState();
}

class _RowGlyphState extends State<_RowGlyph> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final color = widget.active
        ? waveAccent(context)
        : _hover
            ? (dark
                ? WaveColors.textPrimary
                : WaveColors.lightTextPrimary)
            : (dark
                ? WaveColors.textTertiary
                : WaveColors.lightTextTertiary);
    if (widget.menuItems != null) {
      return LWTooltip(
        message: widget.tooltip,
        child: DropDownButton(
          items: widget.menuItems!,
          buttonBuilder: (context, onOpen) => MouseRegion(
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: GestureDetector(
              onTap: onOpen,
              child: AnimatedScale(
                scale: _hover ? 1.15 : 1.0,
                duration: WaveMotion.fast,
                curve: Curves.easeOutCubic,
                child: Container(
                  width: 30,
                  height: 36,
                  color: Colors.transparent,
                  child: Icon(widget.icon, size: 14, color: color),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return LWTooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedScale(
            scale: _hover ? 1.15 : 1.0,
            duration: WaveMotion.fast,
            curve: Curves.easeOutCubic,
            child: Container(
              width: 30,
              height: 36,
              color: Colors.transparent,
              child: Icon(widget.icon, size: 14, color: color),
            ),
          ),
        ),
      ),
    );
  }
}

class WaveTrackTableHeader extends StatelessWidget {
  final bool showAlbum;
  const WaveTrackTableHeader({super.key, this.showAlbum = true});
  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final style = WaveType.overline.copyWith(
      fontSize: 9.5,
      color: dark ? WaveColors.textTertiary : WaveColors.lightTextTertiary,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          const SizedBox(width: 30),
          const SizedBox(width: WaveDensity.trackArt),
          const SizedBox(width: 12),
          Expanded(flex: 5, child: Text('TITLE', style: style)),
          if (showAlbum)
            Expanded(flex: 3, child: Text('ALBUM', style: style)),
          const SizedBox(width: 100),
        ],
      ),
    );
  }
}
