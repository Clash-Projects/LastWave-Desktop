import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

import '../../core/audio/stream_models.dart';
import '../../features/player/playback_service.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';
import 'artwork.dart';
import 'buttons.dart' show LWTooltip;
import 'menus.dart';

// two_dimensional_scrollables evaluation (Agent 6):
// NOT added. The table scrolls on one axis only (vertical); columns are
// flex-proportioned and collapse responsively (Album <1000px, Quality
// <800px) instead of scrolling horizontally. super_sliver_list (already in
// pubspec) covers virtualization for 10k+ row lists. A 2-D table would add
// sticky-column complexity with no product need — revisit only if a
// spreadsheet-style view (frozen first column + horizontal scroll) is asked.

/// Sort direction for a header tap cycle: asc → desc → asc …
enum WaveSortDir { asc, desc }

/// Canonical reusable desktop music table.
///
/// ```
/// # / Title (art + title + artist) / Artist / Album / Quality / Added / Duration
/// ```
///
/// - Virtualized via [SuperSliverList] (standalone) or [SuperListView]
///   (shrink-wrapped embed) — never a giant [Column].
/// - Header tap sorts when a `*SortOf` callback is provided (arrow indicator).
/// - Responsive: Album hides <1000px, Quality hides <800px.
/// - Keyboard: Up/Down move focus, Enter plays, Space toggles selection
///   (or play/pause when not selectable), Delete removes where applicable.
/// - Mouse: hover wash + play overlay on art + hover-only like/more,
///   single tap focuses/selects, double-click plays, right-click menu.
/// - Playing row: animated [WaveEqDots] + accent title; durations tabular.
///
/// Home / Discover / Collections render their track lists through this so
/// density, truncation and keyboard behaviour stay identical everywhere.
class WaveDesktopTable<T extends Object> extends ConsumerStatefulWidget {
  final List<T> items;
  final String Function(T item) keyOf;
  final String Function(T item) titleOf;
  final String Function(T item) subtitleOf;
  final String Function(T item) albumOf;
  final String Function(T item) artworkOf;
  final PlayableTrack Function(T item) playableOf;

  /// Display strings. Quality/date columns render only when provided.
  final String Function(T item)? durationOf;
  final String Function(T item)? qualityOf;
  final String Function(T item)? dateAddedOf;

  /// Sort values. A header cell is sortable only when its callback != null.
  final Comparable Function(T item)? titleSortOf;
  final Comparable Function(T item)? artistSortOf;
  final Comparable Function(T item)? albumSortOf;
  final Comparable Function(T item)? durationSortOf;
  final Comparable Function(T item)? dateAddedSortOf;

  final bool Function(T item)? isCurrent;
  final bool Function(T item)? isPlaying;
  final bool Function(T item)? isLiked;
  final Future<void> Function(T item)? onToggleLike;

  /// Play the row at [index]. Single tap only focuses — pass
  /// [playOnSingleTap] to also play on single tap (e.g. search results).
  final void Function(int index) onPlay;
  final bool playOnSingleTap;
  final String? removeLabel;
  final void Function(int index)? onRemove;

  final List<MenuFlyoutItemBase> Function(WidgetRef ref, T item)? menuBuilder;
  final bool showHeader;
  final bool showLike;
  final bool showArtistColumn;

  /// Multi-select: Ctrl/Meta-click toggles, Shift-click extends a range.
  final bool selectable;
  final Set<String>? selectedKeys;
  final void Function(Set<String> selected)? onSelectionChanged;

  /// Embed mode (e.g. 5-row search section): shrink-wrapped, no own scroll.
  final bool shrinkWrap;
  final ScrollController? scrollController;
  final Widget? empty;

  const WaveDesktopTable({
    super.key,
    required this.items,
    required this.keyOf,
    required this.titleOf,
    required this.subtitleOf,
    required this.albumOf,
    required this.artworkOf,
    required this.playableOf,
    required this.onPlay,
    this.durationOf,
    this.qualityOf,
    this.dateAddedOf,
    this.titleSortOf,
    this.artistSortOf,
    this.albumSortOf,
    this.durationSortOf,
    this.dateAddedSortOf,
    this.isCurrent,
    this.isPlaying,
    this.isLiked,
    this.onToggleLike,
    this.playOnSingleTap = false,
    this.removeLabel,
    this.onRemove,
    this.menuBuilder,
    this.showHeader = true,
    this.showLike = true,
    this.showArtistColumn = true,
    this.selectable = false,
    this.selectedKeys,
    this.onSelectionChanged,
    this.shrinkWrap = false,
    this.scrollController,
    this.empty,
  });

  @override
  ConsumerState<WaveDesktopTable<T>> createState() =>
      _WaveDesktopTableState<T>();
}

class _WaveDesktopTableState<T extends Object>
    extends ConsumerState<WaveDesktopTable<T>> {
  final FocusNode _focus = FocusNode();
  final ListController _listController = ListController();
  int _hover = -1;
  int _focusIndex = -1;
  int _anchor = -1;
  Set<String> _internalSelected = {};
  int _sortCol = -1; // 0 title, 1 artist, 2 album, 3 duration, 4 added
  WaveSortDir _sortDir = WaveSortDir.asc;

  @override
  void dispose() {
    _focus.dispose();
    _listController.dispose();
    super.dispose();
  }

  Set<String> get _selected =>
      widget.selectedKeys ?? _internalSelected;

  void _setSelected(Set<String> next) {
    if (widget.selectedKeys == null) {
      setState(() => _internalSelected = next);
    }
    widget.onSelectionChanged?.call(next);
  }

  List<int> get _order {
    final order = List<int>.generate(widget.items.length, (i) => i);
    if (_sortCol < 0) return order;
    Comparable Function(T)? fn;
    switch (_sortCol) {
      case 0:
        fn = widget.titleSortOf;
      case 1:
        fn = widget.artistSortOf;
      case 2:
        fn = widget.albumSortOf;
      case 3:
        fn = widget.durationSortOf;
      case 4:
        fn = widget.dateAddedSortOf;
    }
    if (fn == null) return order;
    final capture = fn;
    final dir = _sortDir;
    order.sort((a, b) {
      final c = capture(widget.items[a]).compareTo(
        capture(widget.items[b]) as dynamic,
      );
      return dir == WaveSortDir.asc ? c : -c;
    });
    return order;
  }

  void _cycleSort(int col) {
    setState(() {
      if (_sortCol != col) {
        _sortCol = col;
        _sortDir = WaveSortDir.asc;
      } else {
        _sortDir = _sortDir == WaveSortDir.asc
            ? WaveSortDir.desc
            : WaveSortDir.asc;
      }
    });
  }

  void _moveFocus(int delta) {
    if (widget.items.isEmpty) return;
    final order = _order;
    var pos = order.indexOf(_focusIndex);
    pos = (pos + delta).clamp(0, order.length - 1);
    final next = order[pos];
    setState(() => _focusIndex = next);
    final sc = widget.scrollController;
    if (!widget.shrinkWrap && sc != null) {
      _listController.animateToItem(
        index: widget.showHeader ? next + 1 : next,
        scrollController: sc,
        alignment: 0.5,
        duration: (_) => const Duration(milliseconds: 140),
        curve: (_) => Curves.easeOutCubic,
      );
    }
  }

  void _onRowTap(int index, {required bool ctrl, required bool shift}) {
    _focus.requestFocus();
    if (widget.selectable && (ctrl || shift)) {
      final next = Set<String>.of(_selected);
      final order = _order;
      if (shift && _anchor >= 0) {
        final a = order.indexOf(_anchor);
        final b = order.indexOf(index);
        final lo = a < b ? a : b;
        final hi = a < b ? b : a;
        for (var i = lo; i <= hi; i++) {
          next.add(widget.keyOf(widget.items[order[i]]));
        }
      } else {
        final k = widget.keyOf(widget.items[index]);
        if (next.contains(k)) {
          next.remove(k);
        } else {
          next.add(k);
        }
        _anchor = index;
      }
      _setSelected(next);
      setState(() => _focusIndex = index);
      return;
    }
    setState(() {
      _focusIndex = index;
      _anchor = index;
      if (widget.selectable) _internalSelected = _selected;
    });
    if (widget.selectable) _setSelected({widget.keyOf(widget.items[index])});
    if (widget.playOnSingleTap) widget.onPlay(index);
  }

  KeyEventResult _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.arrowDown) {
      _moveFocus(1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      _moveFocus(-1);
      return KeyEventResult.handled;
    }
    if (_focusIndex < 0 ||
        _focusIndex >= widget.items.length) {
      return KeyEventResult.ignored;
    }
    if (k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter) {
      widget.onPlay(_focusIndex);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.space) {
      if (widget.selectable) {
        _onRowTap(_focusIndex, ctrl: true, shift: false);
      } else {
        ref.read(playbackServiceProvider.notifier).toggle();
      }
      return KeyEventResult.handled;
    }
    if ((k == LogicalKeyboardKey.delete ||
            k == LogicalKeyboardKey.backspace) &&
        widget.onRemove != null) {
      widget.onRemove!(_focusIndex);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) {
      return widget.empty ?? const SizedBox.shrink();
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        // Responsive: collapse secondary columns instead of h-scrolling.
        final showAlbum = w >= 1000;
        final showQuality =
            widget.qualityOf != null && w >= 800;
        final showAdded = widget.dateAddedOf != null && w >= 1100;
        final showArtist =
            widget.showArtistColumn && w >= 640;

        Widget list;
        if (widget.shrinkWrap) {
          list = SuperListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount:
                _order.length + (widget.showHeader ? 1 : 0),
            itemBuilder: (context, i) => _buildSliverChild(
              i,
              showAlbum: showAlbum,
              showQuality: showQuality,
              showAdded: showAdded,
              showArtist: showArtist,
            ),
          );
        } else {
          list = CustomScrollView(
            controller: widget.scrollController,
            slivers: [
              if (widget.showHeader)
                SliverToBoxAdapter(
                  child: _HeaderRow(
                    sortCol: _sortCol,
                    sortDir: _sortDir,
                    onSort: _cycleSort,
                    sortableTitle: widget.titleSortOf != null,
                    sortableArtist: widget.artistSortOf != null,
                    sortableAlbum:
                        widget.albumSortOf != null && showAlbum,
                    sortableDuration:
                        widget.durationSortOf != null,
                    sortableAdded:
                        widget.dateAddedSortOf != null && showAdded,
                    showAlbum: showAlbum,
                    showQuality: showQuality,
                    showAdded: showAdded,
                    showArtist: showArtist,
                  ),
                ),
              SuperSliverList.builder(
                listController: _listController,
                itemCount: _order.length,
                itemBuilder: (context, i) =>
                    _buildRow(
                      _order[i],
                      showAlbum: showAlbum,
                      showQuality: showQuality,
                      showAdded: showAdded,
                      showArtist: showArtist,
                    ),
              ),
            ],
          );
        }

        // Shrink-wrap path renders the header as the first list child.
        return Focus(
          focusNode: _focus,
          onKeyEvent: (_, e) => _onKey(e),
          child: list,
        );
      },
    );
  }

  Widget _buildSliverChild(
    int i, {
    required bool showAlbum,
    required bool showQuality,
    required bool showAdded,
    required bool showArtist,
  }) {
    if (widget.showHeader && i == 0) {
      return _HeaderRow(
        sortCol: _sortCol,
        sortDir: _sortDir,
        onSort: _cycleSort,
        sortableTitle: widget.titleSortOf != null,
        sortableArtist: widget.artistSortOf != null,
        sortableAlbum: widget.albumSortOf != null && showAlbum,
        sortableDuration: widget.durationSortOf != null,
        sortableAdded: widget.dateAddedSortOf != null && showAdded,
        showAlbum: showAlbum,
        showQuality: showQuality,
        showAdded: showAdded,
        showArtist: showArtist,
      );
    }
    final index = _order[widget.showHeader ? i - 1 : i];
    return _buildRow(
      index,
      showAlbum: showAlbum,
      showQuality: showQuality,
      showAdded: showAdded,
      showArtist: showArtist,
    );
  }

  Widget _buildRow(
    int index, {
    required bool showAlbum,
    required bool showQuality,
    required bool showAdded,
    required bool showArtist,
  }) {
    final item = widget.items[index];
    final current = widget.isCurrent?.call(item) ?? false;
    final playing = widget.isPlaying?.call(item) ?? false;
    return _TableRow<T>(
      index: index,
      hovered: _hover == index,
      focused: _focusIndex == index,
      selected: _selected.contains(widget.keyOf(item)),
      current: current,
      playing: playing,
      title: widget.titleOf(item),
      subtitle: widget.subtitleOf(item),
      artist: showArtist ? widget.subtitleOf(item) : '',
      showArtistColumn: showArtist,
      album: showAlbum ? widget.albumOf(item) : '',
      showAlbum: showAlbum,
      quality: showQuality ? widget.qualityOf!(item) : '',
      showQuality: showQuality,
      dateAdded: showAdded ? widget.dateAddedOf!(item) : '',
      showAdded: showAdded,
      duration: widget.durationOf?.call(item) ?? '',
      artworkUrl: widget.artworkOf(item),
      showLike: widget.showLike,
      liked: widget.isLiked?.call(item) ?? false,
      onHover: (v) => setState(
        () => _hover = v ? index : -1,
      ),
      onTap: ({required bool ctrl, required bool shift}) =>
          _onRowTap(index, ctrl: ctrl, shift: shift),
      onDoubleTap: () => widget.onPlay(index),
      onPlayOverlay: () => widget.onPlay(index),
      onToggleLike: widget.onToggleLike == null
          ? null
          : () => widget.onToggleLike!(item),
      menuItems: () =>
          widget.menuBuilder?.call(ref, item) ??
          waveTrackMenuItems(
            ref: ref,
            playable: widget.playableOf(item),
            title: widget.titleOf(item),
            artist: widget.subtitleOf(item),
            artworkUrl: widget.artworkOf(item),
            removeLabel: widget.removeLabel,
            onRemove: widget.onRemove == null
                ? null
                : () => widget.onRemove!(index),
          ),
    );
  }
}

class _HeaderRow extends StatelessWidget {
  final int sortCol;
  final WaveSortDir sortDir;
  final void Function(int col) onSort;
  final bool sortableTitle;
  final bool sortableArtist;
  final bool sortableAlbum;
  final bool sortableDuration;
  final bool sortableAdded;
  final bool showAlbum;
  final bool showQuality;
  final bool showAdded;
  final bool showArtist;
  const _HeaderRow({
    required this.sortCol,
    required this.sortDir,
    required this.onSort,
    required this.sortableTitle,
    required this.sortableArtist,
    required this.sortableAlbum,
    required this.sortableDuration,
    this.sortableAdded = false,
    required this.showAlbum,
    required this.showQuality,
    required this.showAdded,
    required this.showArtist,
  });

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final style = WaveType.overline.copyWith(
      fontSize: 9.5,
      color: dark ? WaveColors.textTertiary : WaveColors.lightTextTertiary,
    );
    Widget cell(
      String label,
      int col,
      bool sortable, {
      int flex = 3,
      double? width,
      bool numeric = false,
    }) {
      final active = sortCol == col;
      final inner = Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: numeric
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style.copyWith(
                color: active
                    ? waveAccent(context)
                    : style.color,
              ),
            ),
          ),
          if (active)
            Padding(
              padding: const EdgeInsets.only(left: 3),
              child: Icon(
                sortDir == WaveSortDir.asc
                    ? WaveIcons.sortUp
                    : WaveIcons.sortDown,
                size: 10,
                color: waveAccent(context),
              ),
            ),
        ],
      );
      final content = sortable
          ? _HeaderTap(
              onTap: () => onSort(col),
              child: inner,
            )
          : inner;
      if (width != null) {
        return SizedBox(width: width, child: content);
      }
      return Expanded(flex: flex, child: content);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          const SizedBox(width: 30),
          const SizedBox(width: WaveDensity.trackArt),
          const SizedBox(width: 12),
          cell('TITLE', 0, sortableTitle, flex: 5),
          if (showArtist) cell('ARTIST', 1, sortableArtist),
          if (showAlbum) cell('ALBUM', 2, sortableAlbum),
          if (showQuality)
            cell('QUALITY', -1, false, width: 64),
          if (showAdded) cell('ADDED', 4, sortableAdded, width: 92),
          const SizedBox(width: 60),
          cell('DURATION', 3, sortableDuration,
              width: 44, numeric: true),
        ],
      ),
    );
  }
}

class _HeaderTap extends StatefulWidget {
  final VoidCallback onTap;
  final Widget child;
  const _HeaderTap({required this.onTap, required this.child});
  @override
  State<_HeaderTap> createState() => _HeaderTapState();
}

class _HeaderTapState extends State<_HeaderTap> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Opacity(
          opacity: _hover ? 1 : 0.85,
          child: widget.child,
        ),
      ),
    );
  }
}

class _TableRow<T extends Object> extends StatelessWidget {
  final int index;
  final bool hovered;
  final bool focused;
  final bool selected;
  final bool current;
  final bool playing;
  final String title;
  final String subtitle;
  final String artist;
  final bool showArtistColumn;
  final String album;
  final bool showAlbum;
  final String quality;
  final bool showQuality;
  final String dateAdded;
  final bool showAdded;
  final String duration;
  final String artworkUrl;
  final bool showLike;
  final bool liked;
  final void Function(bool) onHover;
  final void Function({required bool ctrl, required bool shift}) onTap;
  final VoidCallback onDoubleTap;
  final VoidCallback onPlayOverlay;
  final VoidCallback? onToggleLike;
  final List<MenuFlyoutItemBase> Function() menuItems;
  const _TableRow({
    required this.index,
    required this.hovered,
    required this.focused,
    required this.selected,
    required this.current,
    required this.playing,
    required this.title,
    required this.subtitle,
    required this.artist,
    required this.showArtistColumn,
    required this.album,
    required this.showAlbum,
    required this.quality,
    required this.showQuality,
    required this.dateAdded,
    required this.showAdded,
    required this.duration,
    required this.artworkUrl,
    required this.showLike,
    required this.liked,
    required this.onHover,
    required this.onTap,
    required this.onDoubleTap,
    required this.onPlayOverlay,
    required this.onToggleLike,
    required this.menuItems,
  });

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);
    final tertiary =
        dark ? WaveColors.textTertiary : WaveColors.lightTextTertiary;

    Color bg;
    if (selected) {
      bg = accent.withValues(alpha: 0.10);
    } else if (hovered || focused) {
      bg = (dark ? Colors.white : Colors.black)
          .withValues(alpha: 0.05);
    } else {
      bg = Colors.transparent;
    }

    final row = MouseRegion(
      onEnter: (_) => onHover(true),
      onExit: (_) => onHover(false),
      child: GestureDetector(
        onTapDown: (d) {
          final keys = HardwareKeyboard.instance.logicalKeysPressed;
          final ctrl = keys.contains(LogicalKeyboardKey.controlLeft) ||
              keys.contains(LogicalKeyboardKey.controlRight) ||
              keys.contains(LogicalKeyboardKey.metaLeft) ||
              keys.contains(LogicalKeyboardKey.metaRight);
          final shift = keys.contains(LogicalKeyboardKey.shiftLeft) ||
              keys.contains(LogicalKeyboardKey.shiftRight);
          onTap(ctrl: ctrl, shift: shift);
        },
        onDoubleTap: onDoubleTap,
        child: Container(
          height: WaveDensity.trackRow,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(WaveRadius.tiny),
            border: focused
                ? Border.all(
                    color: WaveColors.accentDim, width: WaveState.focusRing)
                : selected
                    ? Border.all(
                        color: accent.withValues(alpha: 0.35), width: 1)
                    : Border.all(color: Colors.transparent),
          ),
          child: Row(
            children: [
              // 30px gutter: number → play on hover → animated EQ when playing.
              SizedBox(
                width: 30,
                child: Center(
                  child: playing
                      ? const WaveEqDots()
                      : hovered
                          ? GestureDetector(
                              onTap: onPlayOverlay,
                              child: Icon(
                                WaveIcons.play,
                                size: 14,
                                color: dark
                                    ? WaveColors.textPrimary
                                    : WaveColors
                                        .lightTextPrimary,
                              ),
                            )
                          : Text(
                              (index + 1).toString().padLeft(2, '0'),
                              style: WaveType.meta.copyWith(
                                fontSize: 12,
                                fontFeatures: const [
                                  FontFeature.tabularFigures()
                                ],
                                color: current ? accent : tertiary,
                              ),
                              textAlign: TextAlign.center,
                            ),
                ),
              ),
              // 40px art, radius 4, hover play overlay.
              _ArtPlay(
                url: artworkUrl,
                title: title,
                artist: artist,
                hovered: hovered,
                playing: playing,
                onPlay: onPlayOverlay,
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 5,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: WaveType.trackTitle.copyWith(
                        color: current
                            ? accent
                            : (dark
                                ? WaveColors.textPrimary
                                : WaveColors.lightTextPrimary),
                      ),
                    ),
                    Text(
                      subtitle,
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
              if (showArtistColumn)
                Expanded(
                  flex: 3,
                  child: Text(
                    artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: WaveType.meta.copyWith(color: tertiary),
                  ),
                ),
              if (showAlbum)
                Expanded(
                  flex: 3,
                  child: Text(
                    album,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: WaveType.meta.copyWith(color: tertiary),
                  ),
                ),
              if (showQuality)
                SizedBox(
                  width: 64,
                  child: quality.isEmpty
                      ? const SizedBox.shrink()
                      : Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: dark
                                  ? WaveColors.outline
                                  : WaveColors.lightOutline,
                            ),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(
                            quality,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: WaveType.meta.copyWith(
                              fontSize: 10.5,
                              color: dark
                                  ? WaveColors.textSecondary
                                  : WaveColors
                                      .lightTextSecondary,
                            ),
                          ),
                        ),
                ),
              if (showAdded)
                SizedBox(
                  width: 92,
                  child: Text(
                    dateAdded,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: WaveType.meta.copyWith(color: tertiary),
                  ),
                ),
              // Hover-only like + more.
              AnimatedOpacity(
                duration: WaveMotion.fast,
                opacity: (hovered || current || liked) ? 1 : 0,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (showLike && onToggleLike != null)
                      _HoverGlyph(
                        tooltip: liked ? 'Unlike' : 'Like',
                        icon: liked ? WaveIcons.likedFill : WaveIcons.liked,
                        active: liked,
                        onTap: onToggleLike!,
                      ),
                    _HoverGlyph(
                      tooltip: 'More',
                      icon: WaveIcons.more,
                      menuItems: menuItems(),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 44,
                child: Text(
                  duration,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: WaveType.meta.copyWith(
                    fontFeatures: const [
                      FontFeature.tabularFigures()
                    ],
                    color: tertiary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return WaveContextMenu(items: menuItems, child: row);
  }
}

class _ArtPlay extends StatelessWidget {
  final String url;
  final String title;
  final String artist;
  final bool hovered;
  final bool playing;
  final VoidCallback onPlay;
  const _ArtPlay({
    required this.url,
    this.title = '',
    this.artist = '',
    required this.hovered,
    required this.playing,
    required this.onPlay,
  });
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPlay,
      child: Stack(
        children: [
          WaveArtwork(
            url: url,
            size: WaveDensity.trackArt,
            radius: 4,
            title: title,
            artist: artist,
            label: title,
          ),
          if (hovered || playing)
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(
                    alpha: playing ? 0.35 : 0.5,
                  ),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: playing
                    ? const Center(child: WaveEqDots.light())
                    : const Icon(
                        WaveIcons.play,
                        size: 15,
                        color: Colors.white,
                      ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Animated 3-bar playing indicator in the accent colour.
class WaveEqDots extends StatefulWidget {
  final bool light;
  const WaveEqDots({super.key}) : light = false;
  const WaveEqDots.light({super.key}) : light = true;
  @override
  State<WaveEqDots> createState() => _WaveEqDotsState();
}

class _WaveEqDotsState extends State<WaveEqDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 840),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color =
        widget.light ? Colors.white : waveAccent(context);
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        double h(int i) {
          final phase = (_c.value * 2 * math.pi) + (i * 1.85);
          final norm = (math.sin(phase) + 1.0) / 2.0;
          return 3.0 + norm * 9.0;
        }
        return SizedBox(
          width: 22,
          height: 12,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < 3; i++) ...[
                Container(width: 2.5, height: h(i), color: color),
                if (i < 2) const SizedBox(width: 2),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _HoverGlyph extends StatefulWidget {
  final String tooltip;
  final IconData icon;
  final bool active;
  final VoidCallback? onTap;
  final List<MenuFlyoutItemBase>? menuItems;
  const _HoverGlyph({
    required this.tooltip,
    required this.icon,
    this.active = false,
    this.onTap,
    this.menuItems,
  });
  @override
  State<_HoverGlyph> createState() => _HoverGlyphState();
}

class _HoverGlyphState extends State<_HoverGlyph> {
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
    final glyph = Container(
      width: 30,
      height: 36,
      color: Colors.transparent,
      child: Center(
        child: AnimatedScale(
          scale: _hover ? 1.15 : 1.0,
          duration: WaveMotion.fast,
          curve: Curves.easeOutCubic,
          child: Icon(widget.icon, size: 14, color: color),
        ),
      ),
    );
    final hovered = MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: glyph,
    );
    if (widget.menuItems != null) {
      return LWTooltip(
        message: widget.tooltip,
        child: DropDownButton(
          items: widget.menuItems!,
          buttonBuilder: (context, onOpen) => GestureDetector(
            onTap: onOpen,
            child: hovered,
          ),
        ),
      );
    }
    return LWTooltip(
      message: widget.tooltip,
      child: GestureDetector(
        onTap: widget.onTap,
        child: hovered,
      ),
    );
  }
}
