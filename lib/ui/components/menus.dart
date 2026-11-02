import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../app/track_actions.dart';
import '../../core/audio/artist_parser.dart';
import '../../core/audio/stream_models.dart';
import '../../features/downloads/download_manager.dart';
import '../../features/home/home_providers.dart';
import '../../features/library/playlists.dart';
import '../../features/player/playback_service.dart';
import '../../features/search/shared_providers.dart';
import '../app_shell/wave_hotkeys.dart';
import '../collections/playlist_dialogs.dart';
import '../navigation/wave_nav.dart';
import '../theme/tokens.dart';
import 'buttons.dart' show LWTooltip, WaveButton, WaveFilledButton;

/// Snappy flyout entrance shared by every DropDownButton/menu in the
/// app. Same slide-from-edge language as fluent's default, compressed
/// into the first ~55% of the 167ms controller (≈90ms) plus a fast
/// fade — the full-length slide reads as lag on click. Pass as
/// `transitionBuilder:` on DropDownButton, or mirror with an explicit
/// 90ms `transitionDuration` on direct `showFlyout` calls.
Widget fastFlyoutTransition(
  BuildContext context,
  Animation<double> animation,
  FlyoutPlacementMode placementMode,
  Widget flyout,
) {
  if (animation.isCompleted || animation.isDismissed) return flyout;
  if (animation.status == AnimationStatus.reverse) {
    return FadeTransition(opacity: animation, child: flyout);
  }
  final textDirection = Directionality.of(context);
  final begin = switch (placementMode) {
    FlyoutPlacementMode.topCenter ||
    FlyoutPlacementMode.topLeft ||
    FlyoutPlacementMode.topRight =>
      const Offset(0, 1),
    _ => const Offset(0, -1),
  };
  const fast = Interval(0.0, 0.55, curve: Curves.easeOutCubic);
  return ClipRect(
    child: FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: fast),
      child: SlideTransition(
        textDirection: textDirection,
        position: Tween<Offset>(begin: begin, end: Offset.zero).animate(
          CurvedAnimation(parent: animation, curve: fast),
        ),
        child: flyout,
      ),
    ),
  );
}

/// Menu data model for [WaveFlyoutPanel].
///
/// Labels are plain strings (not Text widgets) so rows can enforce
/// single-line ellipsis inside the fixed-width panel. Carries no layout
/// of its own — rendering is owned by the panel.
sealed class WaveMenuEntry {
  const WaveMenuEntry();
}

/// One tappable row. `onPressed == null` renders disabled.
class WaveMenuAction extends WaveMenuEntry {
  final Widget? leading;
  final String label;
  final String? hint;
  final VoidCallback? onPressed;
  const WaveMenuAction({
    this.leading,
    required this.label,
    this.hint,
    this.onPressed,
  });
}

/// Horizontal divider.
class WaveMenuSeparator extends WaveMenuEntry {
  const WaveMenuSeparator();
}

/// Hover-cascade nested menu (e.g. "Add to playlist").
class WaveMenuSubmenu extends WaveMenuEntry {
  final Widget? leading;
  final String label;
  final List<WaveMenuEntry> Function() items;
  const WaveMenuSubmenu({
    this.leading,
    required this.label,
    required this.items,
  });
}

/// Single Fluent menu source for every track row / card / hero.
///
/// One builder produces [WaveMenuEntry] lists rendered by
/// [WaveFlyoutPanel] (right-click menus). Plugin DropDownButtons keep
/// their own inline item lists and are unaffected.
List<WaveMenuEntry> waveTrackMenuItems({
  required BuildContext context,
  required WidgetRef ref,
  required String title,
  required String artist,
  String artworkUrl = '',
  String videoId = '',
  String album = '',
  int durationSeconds = 0,
  PlayableTrack? playable,
  String? removeLabel,
  VoidCallback? onRemove,
}) {
  final player = ref.read(playbackServiceProvider.notifier);
  final track = playable ??
      PlayableTrack(
        title: title,
        artist: artist,
        album: album,
        artworkUrl: artworkUrl,
        videoId: videoId,
        duration: Duration(seconds: durationSeconds),
      );
  final library = ref.read(playlistRepositoryProvider.notifier);
  final liked = library.likedKeys().contains(track.queueKey);
  final playlists = ref.read(playlistRepositoryProvider);
  final downloads = ref.read(downloadManagerProvider.notifier);

  StoredTrack stored() => StoredTrack(
        name: title,
        artist: artist,
        artworkUrl: artworkUrl,
        videoId: track.videoId,
        album: album,
        durationSeconds: durationSeconds,
      );

  final items = <WaveMenuEntry>[
    WaveMenuAction(
      leading: const Icon(FluentIcons.play, size: 15),
      label: 'Play',
      hint: 'Enter',
      onPressed: () =>
          player.play(track, sourceLabel: 'Context menu'),
    ),
    WaveMenuAction(
      leading: const Icon(FluentIcons.add, size: 15),
      label: 'Play next',
      onPressed: () => player.playNext(track),
    ),
    WaveMenuAction(
      leading: const Icon(FluentIcons.list, size: 15),
      label: 'Add to queue',
      onPressed: () => player.addToQueue(track),
    ),
    const WaveMenuSeparator(),
    WaveMenuAction(
      leading: Icon(
        liked ? FluentIcons.heart_fill : FluentIcons.heart,
        size: 15,
      ),
      label: liked ? 'Unlike' : 'Like',
      onPressed: () => library.toggleLiked(stored()),
    ),
    WaveMenuAction(
      leading: const Icon(FluentIcons.download, size: 15),
      label: 'Download',
      hint: 'Ctrl+D',
      onPressed: () => downloads.downloadTrack(
        title: title,
        artist: artist,
        artworkUrl: artworkUrl,
      ),
    ),
  ];
  items.add(
    waveAddToPlaylistEntry(
      context: context,
      ref: ref,
      playlists: playlists,
      track: stored(),
    ),
  );
  items.add(const WaveMenuSeparator());
  items.add(
    WaveMenuAction(
      leading: const Icon(FluentIcons.album, size: 15),
      label: 'Go to album',
      onPressed: () => goToAlbumOfTrack(
        ref,
        title: title,
        artist: artist,
        album: track.album,
      ),
    ),
  );
  final artistList = splitArtistCredits(artist).toList();
  if (artistList.length > 1) {
    for (final a in artistList) {
      items.add(
        WaveMenuAction(
          leading: const Icon(FluentIcons.microphone, size: 15),
          label: 'Go to $a',
          onPressed: () => waveOpen(
              ref.context, '/artist/${Uri.encodeComponent(a)}'),
        ),
      );
    }
  } else if (artistList.isNotEmpty) {
    items.add(
      WaveMenuAction(
        leading: const Icon(FluentIcons.microphone, size: 15),
        label: 'Go to ${artistList.first}',
        onPressed: () => waveOpen(
            ref.context, '/artist/${Uri.encodeComponent(artistList.first)}'),
      ),
    );
  }
  items.add(const WaveMenuSeparator());
  final link = trackShareLink(track);
  items.add(
    WaveMenuAction(
      leading: const Icon(FluentIcons.link, size: 15),
      label: 'Copy link',
      onPressed: link == null
          ? null
          : () => _copyText(context, link, 'Link copied'),
    ),
  );
  items.add(
    WaveMenuAction(
      leading: const Icon(FluentIcons.copy, size: 15),
      label: 'Copy title and artist',
      onPressed: () => _copyText(
        context,
        '$title — $artist',
        'Title and artist copied',
      ),
    ),
  );
  items.add(
    WaveMenuAction(
      leading: const Icon(FluentIcons.info, size: 15),
      label: 'Properties',
      onPressed: () {
        final snap = ref.read(playbackServiceProvider);
        final origin = trackMediaOrigin(
          track: track,
          downloadPath: downloads.localPathFor(title, artist),
        );
        final same = _samePlayingTrack(snap.current, track);
        final stream = same ? snap.stream : null;
        var quality = _qualityLabel(stream, snap.bitrateKbps);
        if ((quality == null || quality.isEmpty) &&
            track.playbackMimeType.isNotEmpty) {
          quality = track.playbackMimeType;
        }
        var path = origin.path;
        final streamUrl = stream?.url ?? '';
        if ((path == null || path.isEmpty) && streamUrl.startsWith('file:')) {
          path = Uri.tryParse(streamUrl)?.toFilePath();
        }
        final duration = track.duration > Duration.zero
            ? track.duration
            : (same ? snap.duration : Duration.zero);
        showWaveTrackProperties(
          context,
          title: title,
          artist: artist,
          album: track.album,
          artworkUrl: artworkUrl,
          duration: duration,
          sourceKind: origin.kind,
          quality: quality,
          path: path,
        );
      },
    ),
  );
  if (removeLabel != null && onRemove != null) {
    items.add(const WaveMenuSeparator());
    items.add(
      WaveMenuAction(
        leading: const Icon(FluentIcons.delete, size: 15),
        label: removeLabel,
        hint: 'Del',
        onPressed: onRemove,
      ),
    );
  }
  items.add(const WaveMenuSeparator());
  items.add(
    WaveMenuAction(
      leading: const Icon(FluentIcons.blocked, size: 15),
      label: "Don't recommend",
      onPressed: () {
        try {
          ref
              .read(databaseProvider)
              .addExclusion(name: title, artist: artist);
          // Recommendations rebuild without it on next load.
          ref.invalidate(feedProvider);
        } catch (_) {}
      },
    ),
  );
  return items;
}

/// YouTube Music watch URL when [PlayableTrack.videoId] is set.
/// Otherwise the local playback path. Null when neither exists.
String? trackShareLink(PlayableTrack track) {
  if (track.videoId.isNotEmpty) {
    return 'https://music.youtube.com/watch?v=${track.videoId}';
  }
  if (track.playbackUrl.isNotEmpty) return track.playbackUrl;
  return null;
}

/// Local file, download, or stream, plus a filesystem path when the
/// bytes are already on disk.
({String kind, String? path}) trackMediaOrigin({
  required PlayableTrack track,
  String? downloadPath,
}) {
  final playback = track.playbackUrl;
  final playbackIsFile = playback.isNotEmpty && File(playback).existsSync();
  final downloaded = downloadPath != null &&
      downloadPath.isNotEmpty &&
      File(downloadPath).existsSync();
  if (playbackIsFile &&
      (!downloaded || !_sameFilePath(playback, downloadPath))) {
    return (kind: 'Local file', path: playback);
  }
  if (downloaded) return (kind: 'Download', path: downloadPath);
  if (playbackIsFile) return (kind: 'Local file', path: playback);
  return (kind: 'Stream', path: null);
}

bool _samePlayingTrack(PlayableTrack? current, PlayableTrack track) {
  if (current == null) return false;
  return current.queueKey == track.queueKey &&
      current.videoId == track.videoId &&
      current.playbackUrl == track.playbackUrl;
}

bool _sameFilePath(String a, String b) => p.equals(a, b);

String? _qualityLabel(ResolvedStream? stream, int snapshotBitrate) {
  if (stream == null) return null;
  final parts = <String>[];
  if (stream.qualityBadge.isNotEmpty) parts.add(stream.qualityBadge);
  if (stream.audioCodec.isNotEmpty) parts.add(stream.audioCodec);
  final kbps = snapshotBitrate > 0 ? snapshotBitrate : stream.bitrateKbps;
  if (kbps > 0) parts.add('$kbps kbps');
  if (parts.isEmpty) return null;
  return parts.join(' · ');
}

String formatTrackDuration(Duration duration) {
  if (duration <= Duration.zero) return 'Unknown';
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:$seconds';
  }
  return '$minutes:$seconds';
}

void _copyText(BuildContext context, String text, String message) {
  Clipboard.setData(ClipboardData(text: text));
  displayInfoBar(
    context,
    builder: (context, close) => InfoBar(
      title: Text(message),
      severity: InfoBarSeverity.success,
      onClose: close,
    ),
  );
}

/// Track properties dialog (Fluent ContentDialog).
Future<void> showWaveTrackProperties(
  BuildContext context, {
  required String title,
  required String artist,
  String album = '',
  String artworkUrl = '',
  Duration duration = Duration.zero,
  String sourceKind = 'Stream',
  String? quality,
  String? path,
}) {
  final rows = <(String, String)>[
    ('Title', title),
    ('Artist', artist),
    if (album.isNotEmpty) ('Album', album),
    ('Duration', formatTrackDuration(duration)),
    ('Source', sourceKind),
    if (quality != null && quality.isNotEmpty) ('Quality', quality),
    if (path != null && path.isNotEmpty) ('Path', path),
  ];
  return showDialog(
    context: context,
    builder: (context) => ContentDialog(
      title: const Text('Properties'),
      constraints: const BoxConstraints(maxWidth: 440),
      content: SizedBox(
        width: double.infinity,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) const SizedBox(height: 14),
              Text(
                rows[i].$1,
                style: WaveType.meta.copyWith(
                  color: waveTextSecondary(context),
                ),
              ),
              const SizedBox(height: 3),
              SelectableText(
                rows[i].$2,
                style: WaveType.body.copyWith(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  height: 1.35,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        WaveFilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

/// Opaque fixed-width menu surface replacing plugin [MenuFlyout] /
/// [FlyoutContent] for our popups.
///
/// WHY: plugin MenuFlyout wraps content in IntrinsicWidth (an uncached
/// bottom-up measurement of the whole subtree on every open — the
/// RenderPhysicalModel/ClipPath/CustomPaint intrinsics cascade from the
/// profiles) plus an Acrylic/PhysicalModel shell. This panel sizes by
/// top-down constraints instead (stretch inside a fixed max width: O(n),
/// cached, nothing to measure) with an opaque surface + cacheable
/// BoxShadows. Rows are [WaveMenuRow], which keeps the plugin's item
/// metrics (14px label, 16px leading, muted 12px trailing note) but derives
/// its radius from the panel corner, so hover/selected fills stay
/// concentric with the rounded surface instead of reading as square plates
/// cut against it ([FlyoutListTile] hard-codes a 4px radius).
class WaveFlyoutPanel extends StatefulWidget {
  final List<WaveMenuEntry>? entries;
  final Widget? child;
  final double maxWidth;
  final double? maxHeight;
  const WaveFlyoutPanel.items({
    super.key,
    required this.entries,
    this.maxWidth = 280,
    this.maxHeight,
  }) : child = null;
  const WaveFlyoutPanel.child({
    super.key,
    required this.child,
    this.maxWidth = 280,
    this.maxHeight,
  }) : entries = null;
  @override
  State<WaveFlyoutPanel> createState() => _WaveFlyoutPanelState();
}

class _WaveFlyoutPanelState extends State<WaveFlyoutPanel> {
  int _highlight = -1;
  _WaveSubmenuRowState? _openSubmenu;
  final Map<int, GlobalKey<_WaveSubmenuRowState>> _subKeys = {};
  final Map<int, GlobalKey> _rowKeys = {};
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    // The cascaded submenu is an OverlayPortal child of its row, so it
    // goes away with the parent; nothing to close here.
    super.dispose();
  }

  /// Indices of keyboard-focusable rows (actions + submenus, no dividers).
  List<int> get _actionable => [
        for (var i = 0; i < (widget.entries?.length ?? 0); i++)
          if (widget.entries![i] is WaveMenuAction ||
              widget.entries![i] is WaveMenuSubmenu)
            i,
      ];

  void _moveHighlight(int dir) {
    final stops = _actionable;
    if (stops.isEmpty) return;
    setState(() {
      final at = stops.indexOf(_highlight);
      _highlight = at < 0
          ? (dir > 0 ? stops.first : stops.last)
          : stops[(at + dir) % stops.length];
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final key = _rowKeys[_highlight];
      final ctx = key?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.5,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  void _closeSubmenu() {
    final sub = _openSubmenu;
    if (sub == null) return;
    _openSubmenu = null;
    sub.close();
  }

  void _activate(BuildContext context, int index) {
    final entry = widget.entries![index];
    if (entry is WaveMenuSubmenu) {
      _subKeys[index]?.currentState?.openNow();
    } else if (entry is WaveMenuAction) {
      final onPressed = entry.onPressed;
      if (onPressed == null) return;
      Navigator.of(context).maybePop();
      onPressed();
    }
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
      _moveHighlight(1);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
      _moveHighlight(-1);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.enter &&
        _highlight >= 0 &&
        widget.entries != null &&
        _highlight < widget.entries!.length) {
      _activate(context, _highlight);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    Widget body;
    if (widget.child != null) {
      body = widget.child!;
    } else {
      final rows = <Widget>[];
      for (var i = 0; i < widget.entries!.length; i++) {
        final entry = widget.entries![i];
        final rowKey = _rowKeys.putIfAbsent(i, () => GlobalKey());
        if (entry is WaveMenuSeparator) {
          // Same spec as the plugin separator: 5px bottom pad, zero-margin
          // divider. Built inline — the plugin's is not a Widget.
          rows.add(KeyedSubtree(
            key: rowKey,
            child: const Padding(
              padding: EdgeInsetsDirectional.only(bottom: 5, top: 5),
              child: Divider(
                style: DividerThemeData(
                    horizontalMargin: EdgeInsetsDirectional.zero),
              ),
            ),
          ));
        } else if (entry is WaveMenuSubmenu) {
          rows.add(_WaveSubmenuRow(
            key: _subKeys.putIfAbsent(
                i, () => GlobalKey<_WaveSubmenuRowState>()),
            entry: entry,
            highlighted: i == _highlight,
            onOpened: (c) {
              if (_openSubmenu != null && _openSubmenu != c) {
                _openSubmenu!.close();
              }
              _openSubmenu = c;
            },
          ));
        } else if (entry is WaveMenuAction) {
          final onPressed = entry.onPressed;
          rows.add(MouseRegion(
            key: rowKey,
            opaque: false,
            onEnter: (_) => _closeSubmenu(),
            child: WaveMenuRow(
              selected: i == _highlight,
              icon: entry.leading,
              text: Text(
                entry.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: entry.hint == null
                  ? null
                  : Text(entry.hint!,
                      style: const TextStyle(fontSize: 11)),
              onPressed: onPressed == null
                  ? null
                  : () {
                      Navigator.of(context).maybePop();
                      onPressed();
                    },
            ),
          ));
        }
      }
      body = Scrollbar(
        controller: _scrollController,
        interactive: true,
        // Desktop ScrollBehavior would add its own Scrollbar on top of the
        // explicit one above (doubled bars), so switch the implicit one off.
        child: ScrollConfiguration(
          behavior:
              ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: SingleChildScrollView(
            controller: _scrollController,
            physics: const ClampingScrollPhysics(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: rows,
            ),
          ),
        ),
      );
    }

    final screenH = MediaQuery.maybeSizeOf(context)?.height ?? 600;
    final effectiveMaxHeight = widget.maxHeight ?? math.min(screenH * 0.65, 380.0);

    final panel = Container(
      decoration: BoxDecoration(
        color: theme.menuColor,
        borderRadius: WaveRadius.menuRadius,
        // The pearl theme has no value step left above a card
        // (`lightSurface == lightSurfaceRaised`), so a menu opened over one
        // has nothing but its shadow to separate it — the same hairline the
        // command palette carries gives it an edge again.
        border: Border.all(color: waveDivider(context)),
        boxShadow: WaveElevation.flyout(theme.brightness == Brightness.dark),
      ),
      child: ClipRRect(
        borderRadius: WaveRadius.menuRadius,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: widget.maxWidth,
            maxHeight: effectiveMaxHeight,
          ),
          child: Padding(
            // [WaveMenuRow.inset]: keeps row fills clear of the panel's
            // rounded edge, and is what the row radius is measured against.
            padding: const EdgeInsetsDirectional.all(WaveMenuRow.inset),
            child: body,
          ),
        ),
      ),
    );

    if (widget.entries == null) return panel;
    // Nav scope: Up/Down stay local while the menu has focus so the
    // global volume shortcuts yield to menu keyboard navigation.
    // (Space stays global: it toggles playback even with a menu open.)
    return WaveKeyNavScope(
      consumeUpDown: true,
      child: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: panel,
      ),
    );
  }
}

/// One tappable menu row, drawn by the app instead of the plugin's
/// [FlyoutListTile].
///
/// WHY: [FlyoutListTile] hard-codes `BorderRadius.circular(4)` for its
/// hover/selected fill and its focus ring. Inside a panel whose own corner
/// is `WaveRadius.menu`, the first and last rows then read as square plates
/// cut against the rounded surface. This row keeps the plugin's metrics
/// (14px label, 16px leading, muted 12px trailing note) and derives its
/// radius from [inset] — `WaveRadius.menu` − 4 = [WaveRadius.controls] — so
/// the highlight stays concentric with the panel.
class WaveMenuRow extends StatelessWidget {
  /// Gap the panel keeps around its rows ([WaveFlyoutPanel] padding). Row
  /// radius = panel radius − this, which is what keeps them concentric.
  static const double inset = 4;

  final Widget text;
  final Widget? icon;
  final Widget? trailing;
  final VoidCallback? onPressed;

  /// Renders the hovered fill (keyboard highlight / current selection).
  final bool selected;

  const WaveMenuRow({
    super.key,
    required this.text,
    this.icon,
    this.trailing,
    this.onPressed,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    assert(debugCheckHasFluentTheme(context));
    return HoverButton(
      onPressed: onPressed,
      builder: (context, states) {
        final theme = FluentTheme.of(context);
        // Selected rows wear the hover fill, like the plugin's.
        final effective = selected ? {WidgetState.hovered} : states;
        final foreground = ButtonThemeData.buttonForegroundColor(
          context,
          effective,
        );
        return FocusBorder(
          focused: states.isFocused,
          renderOutside: true,
          style: FocusThemeData(borderRadius: WaveRadius.controlsRadius),
          child: Container(
            decoration: BoxDecoration(
              color: ButtonThemeData.uncheckedInputColor(
                theme,
                effective,
                transparentWhenNone: true,
              ),
              borderRadius: WaveRadius.controlsRadius,
            ),
            padding: const EdgeInsetsDirectional.only(
              top: 6,
              bottom: 6,
              start: 12,
              end: 10,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 10),
                    child: IconTheme.merge(
                      data: IconThemeData(size: 16, color: foreground),
                      child: icon!,
                    ),
                  ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsetsDirectional.only(end: 10),
                    child: DefaultTextStyle.merge(
                      style: TextStyle(
                        fontSize: 14,
                        letterSpacing: -0.15,
                        color: foreground,
                      ),
                      child: text,
                    ),
                  ),
                ),
                if (trailing != null)
                  DefaultTextStyle.merge(
                    style: TextStyle(
                      fontSize: 12,
                      // Meta tier, not `controlStrokeColorDefault`: that's a
                      // *border* colour (~1.1:1 on the menu surface), which
                      // made shortcut hints like "Ctrl+K" nearly invisible.
                      // `textTertiary` is the app's 4.8:1 meta token.
                      color: waveTextTertiary(context),
                      height: 0.7,
                    ),
                    child: trailing!,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Cascading submenu row: same [WaveMenuRow] visuals as actions, opens
/// a nested [WaveFlyoutPanel] on hover (250ms) or tap/click/Enter.
class _WaveSubmenuRow extends StatefulWidget {
  final WaveMenuSubmenu entry;
  final bool highlighted;
  final ValueChanged<_WaveSubmenuRowState> onOpened;
  const _WaveSubmenuRow({
    super.key,
    required this.entry,
    required this.highlighted,
    required this.onOpened,
  });

  @override
  State<_WaveSubmenuRow> createState() => _WaveSubmenuRowState();
}

class _WaveSubmenuRowState extends State<_WaveSubmenuRow> {
  // The submenu is an OverlayPortal child of its row, NOT a second route:
  // a second route either needs a barrier (which swallows the parent's
  // hover/clicks) or has none (outside clicks then pop only the top route
  // and Windows beeps on the swallowed click). In the parent's own overlay
  // entry, the parent's barrier handles outside clicks and Esc as usual.
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  Timer? _hoverTimer;
  bool _flipLeft = false;

  bool get isOpen => _portal.isShowing;

  @override
  void dispose() {
    _hoverTimer?.cancel();
    super.dispose();
  }

  void close() {
    _hoverTimer?.cancel();
    if (_portal.isShowing) _portal.hide();
  }

  void openNow() {
    _hoverTimer?.cancel();
    if (_portal.isShowing) return;
    // Flip to the left when the submenu (max 280 wide) would run off screen.
    final box = context.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      final right = box.localToGlobal(Offset(box.size.width, 0)).dx;
      final screenW = MediaQuery.sizeOf(context).width;
      _flipLeft = right + 284 > screenW;
    }
    _portal.show();
    widget.onOpened(this);
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: (context) => Align(
          alignment: Alignment.topLeft,
          child: CompositedTransformFollower(
            link: _link,
            showWhenUnlinked: false,
            targetAnchor:
                _flipLeft ? Alignment.topLeft : Alignment.topRight,
            followerAnchor:
                _flipLeft ? Alignment.topRight : Alignment.topLeft,
            offset: Offset(_flipLeft ? -2 : 2, -WaveMenuRow.inset),
            child: WaveFlyoutPanel.items(entries: widget.entry.items()),
          ),
        ),
        child: _row(),
      ),
    );
  }

  Widget _row() {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        _hoverTimer?.cancel();
        _hoverTimer = Timer(
          const Duration(milliseconds: 250),
          openNow,
        );
      },
      onExit: (_) => _hoverTimer?.cancel(),
      child: WaveMenuRow(
        selected: widget.highlighted,
        icon: widget.entry.leading,
        text: Text(
          widget.entry.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: const Icon(FluentIcons.chevron_right, size: 12),
        onPressed: openNow,
      ),
    );
  }
}

/// Right-click region opening a [WaveFlyoutPanel] at the cursor.
class WaveContextMenu extends StatefulWidget {
  final List<WaveMenuEntry> Function() items;
  final Widget child;
  const WaveContextMenu({
    super.key,
    required this.items,
    required this.child,
  });
  @override
  State<WaveContextMenu> createState() => _WaveContextMenuState();
}

class _WaveContextMenuState extends State<WaveContextMenu> {
  final _controller = FlyoutController();
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _open() {
    if (widget.items().isEmpty) return;
    _controller.showFlyout(
      barrierColor: Colors.transparent,
      placementMode: FlyoutPlacementMode.auto,
      transitionDuration: const Duration(milliseconds: 90),
      transitionBuilder: fastFlyoutTransition,
      builder: (context) => WaveFlyoutPanel.items(
        entries: widget.items(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FlyoutTarget(
      controller: _controller,
      child: GestureDetector(
        // On release, like native Windows menus: opening on press leaves the
        // right button held under the new menu, and Flutter sends no hover
        // events while a button is down, so rows only lit up after a focus.
        onSecondaryTapUp: (_) => _open(),
        onLongPressStart: (_) => _open(),
        child: widget.child,
      ),
    );
  }
}

/// Canonical context-menu alias: [LWContextMenu] is [WaveContextMenu].
///
/// Right-click / long-press region opening a 7px Fluent menu flyout.
class LWContextMenu extends WaveContextMenu {
  const LWContextMenu({
    super.key,
    required super.items,
    required super.child,
  });
}

/// Button opening a [WaveFlyoutPanel]; the trigger keeps caller visuals
/// verbatim (replaces plugin DropDownButton, whose MenuFlyout pays the
/// IntrinsicWidth measurement on every open).
class WaveMenuButton extends StatefulWidget {
  final List<WaveMenuEntry> entries;
  final FlyoutPlacementMode placement;
  final Widget Function(BuildContext context, VoidCallback onOpen)
      buttonBuilder;
  const WaveMenuButton({
    super.key,
    required this.entries,
    required this.buttonBuilder,
    this.placement = FlyoutPlacementMode.auto,
  });
  @override
  State<WaveMenuButton> createState() => _WaveMenuButtonState();
}

class _WaveMenuButtonState extends State<WaveMenuButton> {
  final _controller = FlyoutController();
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _open() {
    if (widget.entries.isEmpty) return;
    _controller.showFlyout(
      barrierColor: Colors.transparent,
      placementMode: widget.placement,
      autoModeConfiguration: FlyoutAutoConfiguration(
        preferredMode: widget.placement,
      ),
      transitionDuration: const Duration(milliseconds: 90),
      transitionBuilder: fastFlyoutTransition,
      builder: (context) => WaveFlyoutPanel.items(
        entries: widget.entries,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FlyoutTarget(
      controller: _controller,
      child: widget.buttonBuilder(context, _open),
    );
  }
}

/// Overflow button opening a [WaveFlyoutPanel] below-right.
class WaveOverflowButton extends StatelessWidget {
  final String tooltip;
  final List<WaveMenuEntry> items;
  final IconData icon;
  const WaveOverflowButton({
    super.key,
    this.tooltip = 'More',
    required this.items,
    this.icon = FluentIcons.more,
  });

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    return LWTooltip(
      message: tooltip,
      child: WaveMenuButton(
        entries: items,
        placement: FlyoutPlacementMode.bottomRight,
        buttonBuilder: (context, onOpen) => SizedBox(
          width: WaveDensity.hitArea,
          height: WaveDensity.hitArea,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: IconButton(
            icon: Icon(
              icon,
              size: 15,
              color: dark
                  ? WaveColors.textSecondary
                  : WaveColors.lightTextSecondary,
            ),
            onPressed: onOpen,
          )),
        ),
      ),
    );
  }
}

/// "Add to playlist" cascade: one row per custom playlist, then the way to
/// make a new one.
///
/// Liked Songs is the repository's own row, not a place to file a track by
/// hand, so it never appears. The create row is what makes the cascade worth
/// opening on a fresh library: without it the submenu had no entries at all,
/// so hovering "Add to playlist" opened an empty panel and a new account had
/// no route into a playlist.
WaveMenuSubmenu waveAddToPlaylistEntry({
  required BuildContext context,
  required WidgetRef ref,
  required List<SavedPlaylist> playlists,
  required StoredTrack track,
}) {
  final library = ref.read(playlistRepositoryProvider.notifier);
  final userPlaylists =
      playlists.where((p) => !p.isLikedSongs).toList();
  return WaveMenuSubmenu(
    leading: const Icon(FluentIcons.list_mirrored, size: 15),
    label: 'Add to playlist',
    items: () => [
      for (final p in userPlaylists)
        WaveMenuAction(
          leading: const Icon(
            FluentIcons.list_mirrored,
            size: 15,
          ),
          label: p.title,
          onPressed: () => library.addTrack(p.id, track),
        ),
      if (userPlaylists.isNotEmpty) const WaveMenuSeparator(),
      WaveMenuAction(
        leading: const Icon(FluentIcons.add, size: 15),
        label: 'New playlist…',
        onPressed: () => showWaveAddToNewPlaylist(context, ref, track),
      ),
    ],
  );
}

/// Add-to-playlist picker dialog (Fluent ContentDialog).
Future<void> showWaveAddToPlaylist(
  BuildContext context,
  WidgetRef ref, {
  required String title,
  required String artist,
  String artworkUrl = '',
  String videoId = '',
  String album = '',
  int durationSeconds = 0,
}) async {
  final playlists = ref.read(playlistRepositoryProvider);
  if (playlists.isEmpty) return;
  final stored = StoredTrack(
    name: title,
    artist: artist,
    artworkUrl: artworkUrl,
    videoId: videoId,
    album: album,
    durationSeconds: durationSeconds,
  );
  // Liked Songs is not a target; a library with nothing else would otherwise
  // open a dialog of one Cancel button (the same empty dead end the track menu
  // had). The create row closes with -1 — ids are epoch millis, never negative.
  final userPlaylists = playlists.where((p) => !p.isLikedSongs).toList();
  final selected = await showDialog<int>(
    context: context,
    builder: (context) => ContentDialog(
      title: const Text('Add to playlist'),
      constraints: const BoxConstraints(maxWidth: 440),
      content: SizedBox(
        width: double.infinity,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final p in userPlaylists)
              ListTile.selectable(
                shape: RoundedRectangleBorder(
                  borderRadius: WaveRadius.controlsRadius,
                ),
                title: Text(p.title),
                subtitle: Text('${p.tracks.length} tracks'),
                leading: const Icon(
                  FluentIcons.list_mirrored,
                  size: 15,
                ),
                selectionMode: ListTileSelectionMode.single,
                selected: false,
                onPressed: () =>
                    Navigator.of(context).pop(p.id),
              ),
            if (userPlaylists.isEmpty)
              ListTile.selectable(
                shape: RoundedRectangleBorder(
                  borderRadius: WaveRadius.controlsRadius,
                ),
                title: const Text('New playlist…'),
                leading: const Icon(FluentIcons.add, size: 15),
                selectionMode: ListTileSelectionMode.single,
                selected: false,
                onPressed: () => Navigator.of(context).pop(-1),
              ),
          ],
        ),
      ),
      actions: [
        WaveButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
  if (selected == null) return;
  if (selected < 0) {
    if (context.mounted) await showWaveAddToNewPlaylist(context, ref, stored);
    return;
  }
  await ref.read(playlistRepositoryProvider.notifier).addTrack(selected, stored);
}

/// Like toggle helper for the new layer (no legacy toast host).
Future<bool> waveToggleLike(
  WidgetRef ref, {
  required String title,
  required String artist,
  String artworkUrl = '',
  String videoId = '',
  String album = '',
  int durationSeconds = 0,
}) {
  return ref.read(playlistRepositoryProvider.notifier).toggleLiked(
        StoredTrack(
          name: title,
          artist: artist,
          artworkUrl: artworkUrl,
          videoId: videoId,
          album: album,
          durationSeconds: durationSeconds,
        ),
      );
}
