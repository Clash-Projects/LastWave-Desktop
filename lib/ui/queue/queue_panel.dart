import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../theme/wave_icons.dart';

import '../../app/track_actions.dart';
import '../../core/audio/stream_models.dart';
import '../../features/downloads/download_manager.dart';
import '../../features/player/playback_service.dart';
import '../components/artwork.dart';
import '../components/buttons.dart' show LWTooltip, WaveButton, WaveFilledButton, WaveLink;
import '../components/inputs.dart';
import '../components/menus.dart';
import '../navigation/wave_nav.dart';
import '../theme/tokens.dart';
import 'queue_actions.dart';

/// Session-only. Closing the app clears it; it is not written to SQLite.
final queueLockedProvider = StateProvider<bool>((_) => false);

/// Contextual queue — slides from right, 360px, disappears fully.
///
/// Header: Queue 18px + Add to playlist + inline Close + UP NEXT + Lock + Clear + filter.
/// NOW PLAYING 44px accent row. Reorderable 48px rows: drag handle visible on
/// hover (locked while filtered), hover X remove, right-click menu.
class WaveQueuePanel extends ConsumerStatefulWidget {
  final VoidCallback? onClose;
  final bool embedded;
  const WaveQueuePanel({super.key, required this.onClose, this.embedded = false});

  @override
  ConsumerState<WaveQueuePanel> createState() => _WaveQueuePanelState();
}

class _WaveQueuePanelState extends ConsumerState<WaveQueuePanel> {
  final TextEditingController _filterController = TextEditingController();
  String _filterQuery = '';
  QueueSaveResult? _savedResult;
  Timer? _savedBannerTimer;

  @override
  void dispose() {
    _filterController.dispose();
    _savedBannerTimer?.cancel();
    super.dispose();
  }

  void _clearFilter() {
    _filterController.clear();
    setState(() => _filterQuery = '');
  }

  Future<void> _saveQueue(List<PlayableTrack> visibleTracks) async {
    final res = await showWaveSaveQueuePlaylist(context, ref, visibleTracks);
    if (!mounted || res == null) return;
    _savedBannerTimer?.cancel();
    setState(() => _savedResult = res);
    _savedBannerTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) setState(() => _savedResult = null);
    });
  }

  Future<void> _clearUpcoming(
    List<PlayableTrack> upcoming,
    String? currentKey,
  ) async {
    ref.read(queueClearUndoProvider.notifier).recordCleared(
          upcoming,
          expectedCurrentKey: currentKey,
        );
    await ref.read(playbackServiceProvider.notifier).clearUpcoming();
    if (!mounted) return;
    if (_filterQuery.isNotEmpty) {
      _clearFilter();
    }
  }

  Future<void> _undoClear() async {
    final snap = ref.read(queueClearUndoProvider.notifier).takeForUndo();
    if (snap == null) return;
    await ref.read(playbackServiceProvider.notifier).restoreClearedUpcoming(
          snap.tracks,
          expectedCurrentKey: snap.expectedCurrentKey,
        );
  }

  Widget _buildHeader(BuildContext context, List<PlayableTrack> visibleTracks) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        widget.embedded ? 12 : 8,
        widget.embedded ? 16 : 8,
        2,
      ),
      child: Row(
        children: [
          Text('Queue', style: WaveType.pageTitle.copyWith(fontSize: 18)),
          const SizedBox(width: 8),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: LWTooltip(
                message: 'Save queue to a new or existing playlist',
                child: WaveLink(
                  onPressed: visibleTracks.isEmpty
                      ? null
                      : () => _saveQueue(visibleTracks),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(WaveIcons.addTo, size: 12),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          'Add to playlist',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: WaveType.label.copyWith(fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (!widget.embedded) ...[
            const SizedBox(width: 4),
            _CloseGlyph(onTap: widget.onClose ?? () {}),
          ],
        ],
      ),
    );
  }

  Widget _buildSavedBanner(BuildContext context, QueueSaveResult res) {
    final dark = waveIsDark(context);
    final green = dark ? WaveColors.success : const Color(0xFF1E7E45);
    final unit = res.addedCount == 1 ? 'track' : 'tracks';
    final msg = res.createdNew
        ? 'Saved "${res.playlist.title}" · ${res.addedCount} $unit'
        : res.addedCount > 0
            ? 'Added ${res.addedCount} to "${res.playlist.title}"'
            : 'Already in "${res.playlist.title}"';

    return _QueueBanner(
      icon: WaveIcons.check,
      iconColor: green,
      backgroundColor: WaveColors.success.withValues(alpha: dark ? 0.13 : 0.12),
      borderColor: WaveColors.success.withValues(alpha: dark ? 0.32 : 0.42),
      message: msg,
      actionLabel: 'Open',
      onAction: () => context.go('/playlists/${res.playlist.id}'),
      onDismiss: () => setState(() => _savedResult = null),
    );
  }

  Widget _buildUndoBar(BuildContext context, QueueClearUndoState undo) {
    final count = undo.tracks.length;
    return _QueueBanner(
      icon: WaveIcons.history,
      iconColor: waveAccent(context),
      backgroundColor: waveSurfaceOverlay(context),
      borderColor: waveOutline(context),
      message: 'Cleared $count track${count == 1 ? '' : 's'}',
      actionLabel: 'Undo (${undo.secondsLeft}s)',
      onAction: _undoClear,
      onDismiss: () => ref.read(queueClearUndoProvider.notifier).dismiss(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    ref.listen<String?>(
      playbackServiceProvider.select((s) => s.current?.queueKey),
      (prev, next) {
        if (prev != next) {
          ref.read(queueClearUndoProvider.notifier).expireIfTrackChanged(next);
        }
      },
    );

    final queue = ref.watch(
      playbackServiceProvider.select((s) => s.queue),
    );
    final index = ref.watch(
      playbackServiceProvider.select((s) => s.currentIndex),
    );
    final notifier = ref.read(playbackServiceProvider.notifier);
    final locked = ref.watch(queueLockedProvider);
    final undo = ref.watch(queueClearUndoProvider);

    if (queue.isEmpty) {
      return _Shell(
        embedded: widget.embedded,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(context, const []),
            if (_savedResult != null)
              _buildSavedBanner(context, _savedResult!),
            if (undo != null) _buildUndoBar(context, undo),
            Expanded(
              child: WaveQueueEmpty(onBrowse: () => context.go('/home')),
            ),
          ],
        ),
      );
    }

    final current =
        index >= 0 && index < queue.length ? queue[index] : null;
    final upcoming = index >= 0
        ? queue.sublist((index + 1).clamp(0, queue.length))
        : queue;
    final visibleTracks = visibleQueueTracks(queue, index);
    final isFiltering = _filterQuery.trim().isNotEmpty;
    final filtered = filterUpcomingTracks(queue, index, _filterQuery);

    return _Shell(
      embedded: widget.embedded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(context, visibleTracks),
          if (_savedResult != null) _buildSavedBanner(context, _savedResult!),
          if (current != null) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'NOW PLAYING',
                style: WaveType.overline.copyWith(
                  fontSize: 9,
                  color: dark
                      ? WaveColors.textTertiary
                      : WaveColors.lightTextTertiary,
                ),
              ),
            ),
            const SizedBox(height: 5),
            _NowRow(track: current, queueIndex: index),
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 7),
              child: Container(height: 1, color: waveDivider(context)),
            ),
          ],
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    isFiltering
                        ? 'UP NEXT · ${filtered.length} OF ${upcoming.length}'
                        : 'UP NEXT · ${upcoming.length}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: WaveType.overline.copyWith(
                      fontSize: 9,
                      color: dark
                          ? WaveColors.textTertiary
                          : WaveColors.lightTextTertiary,
                    ),
                  ),
                ),
                const Spacer(),
                LWTooltip(
                  message: locked
                      ? 'Unlock reorder and remove'
                      : 'Lock reorder and remove',
                  child: WaveLink(
                    onPressed: () => ref
                        .read(queueLockedProvider.notifier)
                        .state = !locked,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          locked ? FluentIcons.lock : FluentIcons.unlock,
                          size: 12,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          locked ? 'Unlock' : 'Lock',
                          style: WaveType.label.copyWith(fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                LWTooltip(
                  message: locked
                      ? 'Queue is locked'
                      : upcoming.isEmpty
                          ? 'Nothing to clear'
                          : 'Clear up next',
                  child: WaveLink(
                    onPressed: locked || upcoming.isEmpty
                        ? null
                        : () => _clearUpcoming(upcoming, current?.queueKey),
                    child: Text(
                      'Clear',
                      style: WaveType.label.copyWith(fontSize: 11),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (undo != null) _buildUndoBar(context, undo),
          if (upcoming.isNotEmpty || isFiltering)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
              child: TextBox(
                decoration: waveInputDecoration(),
                controller: _filterController,
                placeholder: 'Filter up next…',
                padding: const EdgeInsets.fromLTRB(8, 5, 6, 5),
                style: WaveType.meta,
                placeholderStyle: WaveType.meta.copyWith(
                  color: dark
                      ? WaveColors.textTertiary
                      : WaveColors.lightTextTertiary,
                ),
                prefix: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(
                    WaveIcons.search,
                    size: 12,
                    color: dark
                        ? WaveColors.textTertiary
                        : WaveColors.lightTextTertiary,
                  ),
                ),
                suffix: _filterQuery.isNotEmpty
                    ? LWTooltip(
                        message: 'Clear filter',
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: _clearFilter,
                            child: const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 8),
                              child: Icon(WaveIcons.close, size: 10),
                            ),
                          ),
                        ),
                      )
                    : null,
                suffixMode: OverlayVisibilityMode.always,
                onChanged: (v) => setState(() => _filterQuery = v),
              ),
            ),
          const SizedBox(height: 4),
          Expanded(
            child: upcoming.isEmpty
                ? Center(
                    child: Text(
                      'Queue ends here.',
                      style: WaveType.meta.copyWith(
                        color: dark
                            ? WaveColors.textTertiary
                            : WaveColors.lightTextTertiary,
                      ),
                    ),
                  )
                : filtered.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'No upcoming tracks match "${_filterQuery.trim()}".',
                                textAlign: TextAlign.center,
                                style: WaveType.meta.copyWith(
                                  color: dark
                                      ? WaveColors.textTertiary
                                      : WaveColors.lightTextTertiary,
                                ),
                              ),
                              const SizedBox(height: 8),
                              WaveButton(
                                onPressed: _clearFilter,
                                child: const Text('Clear filter'),
                              ),
                            ],
                          ),
                        ),
                      )
                    : (locked || isFiltering)
                        ? ListView.builder(
                            itemCount: filtered.length,
                            itemBuilder: (context, i) {
                              final item = filtered[i];
                              return _QueueRow(
                                key: ValueKey(
                                  'q:${item.track.queueKey}:${item.queueIndex}',
                                ),
                                track: item.track,
                                queueIndex: item.queueIndex,
                                dragIndex: i,
                                locked: locked,
                                reorderDisabledReason: isFiltering && !locked
                                    ? 'Clear filter to reorder'
                                    : null,
                              );
                            },
                          )
                        : ReorderableListView.builder(
                            buildDefaultDragHandles: false,
                            itemCount: upcoming.length,
                            // onReorderItem hands over post-removal coordinates;
                            // moveInQueue expects classic onReorder coordinates,
                            // so shift back up when moving down.
                            onReorderItem: (oldI, newI) {
                              final r = newI > oldI ? newI + 1 : newI;
                              final oldQueue = index + 1 + oldI;
                              final newQueue = index + 1 + r;
                              notifier.moveInQueue(oldQueue, newQueue);
                            },
                            itemBuilder: (context, i) {
                              final queueIndex = index + 1 + i;
                              final t = upcoming[i];
                              return _QueueRow(
                                key: ValueKey('q:${t.queueKey}:$queueIndex'),
                                track: t,
                                queueIndex: queueIndex,
                                dragIndex: i,
                              );
                            },
                          ),
          ),
        ],
      ),
    );
  }
}

class _QueueBanner extends StatefulWidget {
  final IconData icon;
  final Color iconColor;
  final Color backgroundColor;
  final Color borderColor;
  final String message;
  final String actionLabel;
  final VoidCallback onAction;
  final VoidCallback onDismiss;

  const _QueueBanner({
    required this.icon,
    required this.iconColor,
    required this.backgroundColor,
    required this.borderColor,
    required this.message,
    required this.actionLabel,
    required this.onAction,
    required this.onDismiss,
  });

  @override
  State<_QueueBanner> createState() => _QueueBannerState();
}

class _QueueBannerState extends State<_QueueBanner> {
  bool _closeHover = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
      child: Container(
        constraints: const BoxConstraints(minHeight: 32),
        padding: const EdgeInsets.fromLTRB(10, 4, 6, 4),
        decoration: BoxDecoration(
          color: widget.backgroundColor,
          borderRadius: WaveRadius.controlsRadius,
          border: Border.all(color: widget.borderColor),
        ),
        child: Row(
          children: [
            Icon(widget.icon, size: 13, color: widget.iconColor),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                widget.message,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: WaveType.meta.copyWith(
                  fontSize: 11.5,
                  color: waveTextPrimary(context),
                ),
              ),
            ),
            const SizedBox(width: 6),
            WaveLink(
              style: const ButtonStyle(
                padding: WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                ),
              ),
              onPressed: widget.onAction,
              child: Text(
                widget.actionLabel,
                style: WaveType.label.copyWith(fontSize: 11.5),
              ),
            ),
            const SizedBox(width: 2),
            LWTooltip(
              message: 'Dismiss',
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                onEnter: (_) => setState(() => _closeHover = true),
                onExit: (_) => setState(() => _closeHover = false),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onDismiss,
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: _closeHover
                          ? waveHoverWash(context)
                          : Colors.transparent,
                      borderRadius: WaveRadius.tinyRadius,
                    ),
                    child: Icon(
                      WaveIcons.close,
                      size: 9,
                      color: waveTextSecondary(context),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class WaveQueueEmpty extends StatelessWidget {
  final VoidCallback onBrowse;
  const WaveQueueEmpty({super.key, required this.onBrowse});
  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: waveSurfaceOverlay(context),
                border: Border.all(
                  color: dark
                      ? waveOutlineSoft(context)
                      : waveOutline(context),
                ),
              ),
              child: Icon(
                WaveIcons.queue,
                size: 22,
                color: dark
                    ? WaveColors.textTertiary
                    : WaveColors.lightTextTertiary,
              ),
            ),
            const SizedBox(height: 12),
            Text('Queue is empty',
                style: WaveType.sectionTitle.copyWith(fontSize: 15)),
            const SizedBox(height: 4),
            Text(
              'Play something to get started',
              style: WaveType.meta.copyWith(
                color: dark
                    ? WaveColors.textSecondary
                    : WaveColors.lightTextSecondary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            WaveFilledButton(
              onPressed: onBrowse,
              child: const Text('Browse music'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Shell extends StatelessWidget {
  final Widget child;
  final bool embedded;
  const _Shell({required this.child, this.embedded = false});
  @override
  Widget build(BuildContext context) {
    if (embedded) return child;
    // Haze Level 2 tonality WITHOUT the live backdrop readback. The
    // panel is a full-height overlay: a live BackdropFilter on it
    // re-samples the whole 360px×window-height region every time the
    // page beneath repaints (scroll, entrance motion, artwork fades).
    // Matches the TitleBar / SideRail / PlayerDock decision — static
    // tonal acrylic, same look, no per-frame GPU readback.
    // Fully opaque: nothing from the page may show through the panel.
    return DecoratedBox(
      decoration: BoxDecoration(
        // Raised, not background: under glass the page colour is clear.
        color: waveSurfaceRaised(context),
        border: Border(left: BorderSide(color: waveDivider(context))),
      ),
      child: SizedBox(
        width: WaveDensity.contextPanel,
        child: child,
      ),
    );
  }
}

class _CloseGlyph extends StatefulWidget {
  final VoidCallback onTap;
  const _CloseGlyph({required this.onTap});
  @override
  State<_CloseGlyph> createState() => _CloseGlyphState();
}

class _CloseGlyphState extends State<_CloseGlyph> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    return LWTooltip(
      message: 'Close (Esc)',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: _hover
                  ? waveHoverWash(context)
                  : Colors.transparent,
              borderRadius:
                  BorderRadius.circular(WaveRadius.controls),
            ),
            child: Icon(
              FluentIcons.chrome_close,
              size: 11,
              color: _hover
                  ? waveTextPrimary(context)
                  : waveTextTertiary(context),
            ),
          ),
        ),
      ),
    );
  }
}

class _NowRow extends ConsumerWidget {
  final PlayableTrack track;
  final int queueIndex;
  const _NowRow({required this.track, required this.queueIndex});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      constraints: const BoxConstraints(minHeight: 44),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          WaveArtwork(
            url: track.artworkUrl,
            size: 44,
            radius: WaveRadius.artwork,
            label: track.title,
            title: track.title,
            artist: track.artist,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: WaveType.trackTitle.copyWith(fontSize: 13)),
                Text(track.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: WaveType.meta),
              ],
            ),
          ),
          Icon(WaveIcons.queue,
              size: 15, color: waveTextTertiary(context)),
        ],
      ),
    );
  }
}

class _QueueRow extends ConsumerStatefulWidget {
  final PlayableTrack track;
  final int queueIndex;
  final int dragIndex;
  final bool locked;
  final String? reorderDisabledReason;
  const _QueueRow({
    super.key,
    required this.track,
    required this.queueIndex,
    required this.dragIndex,
    this.locked = false,
    this.reorderDisabledReason,
  });
  @override
  ConsumerState<_QueueRow> createState() => _QueueRowState();
}

class _QueueRowState extends ConsumerState<_QueueRow> {
  bool _hover = false;

  List<WaveMenuEntry> _menuItems(WidgetRef ref) {
    final notifier = ref.read(playbackServiceProvider.notifier);
    final t = widget.track;
    return [
      WaveMenuAction(
        leading: const Icon(WaveIcons.queue, size: 15),
        label: 'Play next',
        onPressed: () => notifier.playNext(t),
      ),
      WaveMenuAction(
        leading: const Icon(WaveIcons.albums, size: 15),
        label: 'Go to album',
        onPressed: () => goToAlbumOfTrack(
          ref,
          title: t.title,
          artist: t.artist,
          album: t.album,
        ),
      ),
      WaveMenuAction(
        leading: const Icon(WaveIcons.artists, size: 15),
        label: 'Go to artist',
        onPressed: () => waveOpen(
            context, '/artist/${Uri.encodeComponent(t.artist)}'),
      ),
      const WaveMenuSeparator(),
      WaveMenuAction(
        leading: const Icon(WaveIcons.downloadAction, size: 15),
        label: 'Download',
        onPressed: () => ref
            .read(downloadManagerProvider.notifier)
            .downloadTrack(
              title: t.title,
              artist: t.artist,
              album: t.album,
              artworkUrl: t.artworkUrl,
              videoId: t.videoId,
            ),
      ),
      WaveMenuAction(
        leading: const Icon(WaveIcons.addTo, size: 15),
        label: 'Add to playlist',
        onPressed: () => showWaveAddToPlaylist(context, ref,
            title: t.title,
            artist: t.artist,
            artworkUrl: t.artworkUrl,
            videoId: t.videoId,
            album: t.album,
            durationSeconds: t.duration.inSeconds),
      ),
      const WaveMenuSeparator(),
      WaveMenuAction(
        leading: const Icon(WaveIcons.delete, size: 15),
        label: 'Remove',
        onPressed: widget.locked
            ? null
            : () => notifier.removeAt(widget.queueIndex),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final notifier = ref.read(playbackServiceProvider.notifier);
    final row = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => notifier.seekToQueueItem(widget.queueIndex),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            color: _hover
                ? waveHoverWash(context)
                : Colors.transparent,
            borderRadius: WaveRadius.artworkRadius,
          ),
          child: Row(
            children: [
              // Drag handle: low-opacity idle (still visible/keyboard
              // reachable) → full opacity on hover. Hidden while locked
              // or filtered so the row cannot start an invalid reorder.
              if (widget.locked || widget.reorderDisabledReason != null)
                LWTooltip(
                  message: widget.reorderDisabledReason ?? 'Queue is locked',
                  child: Container(
                    width: 28,
                    height: 36,
                    color: Colors.transparent,
                    alignment: Alignment.center,
                    child: Icon(
                      widget.reorderDisabledReason != null
                          ? WaveIcons.search
                          : FluentIcons.lock,
                      size: 12,
                      color: (dark
                              ? WaveColors.textTertiary
                              : WaveColors.lightTextTertiary)
                          .withValues(alpha: 0.7),
                    ),
                  ),
                )
              else
                LWTooltip(
                  message: 'Drag to reorder',
                  child: ReorderableDragStartListener(
                    index: widget.dragIndex,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.move,
                      child: Container(
                        width: 28,
                        height: 36,
                        color: Colors.transparent,
                        child: Icon(
                          FluentIcons.gripper_bar_vertical,
                          size: 15,
                          color: _hover
                              ? (dark
                                  ? WaveColors.textSecondary
                                  : WaveColors.lightTextSecondary)
                              : (dark
                                      ? WaveColors.textTertiary
                                      : WaveColors.lightTextTertiary)
                                  .withValues(alpha: 0.45),
                        ),
                      ),
                    ),
                  ),
                ),
              const SizedBox(width: 4),
              WaveArtwork(
                url: widget.track.artworkUrl,
                size: 36,
                radius: WaveRadius.artwork,
                label: widget.track.title,
                title: widget.track.title,
                artist: widget.track.artist,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(widget.track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: WaveType.trackTitle
                            .copyWith(fontSize: 12.5)),
                    Text(widget.track.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: WaveType.meta.copyWith(fontSize: 11.5)),
                  ],
                ),
              ),
              if (_hover && !widget.locked)
                LWTooltip(
                  message: 'Remove',
                  child: GestureDetector(
                    onTap: () =>
                        notifier.removeAt(widget.queueIndex),
                    child: Container(
                      width: 32,
                      height: 36,
                      color: Colors.transparent,
                      child: const Icon(FluentIcons.chrome_close, size: 12),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    return WaveContextMenu(
      items: () => _menuItems(ref),
      child: row,
    );
  }
}

/// Back-compat: narrow-window queue sheet + public body.
Future<void> showWaveQueueSheet(BuildContext context) {
  return showDialog(
    context: context,
    barrierDismissible: true,
    builder: (context) {
      final contentW = MediaQuery.sizeOf(context).width;
      // Same clamp as the overlay (280–360, never >90% of content).
      final w = (360.0).clamp(280.0, (contentW * 0.9).clamp(180.0, 360.0));
      return ContentDialog(
        title: const Text('Queue'),
        constraints: const BoxConstraints(maxWidth: 440),
        content: SizedBox(
          width: w.toDouble(),
          height: 520,
          child: WaveQueuePanel(onClose: () => Navigator.of(context).pop()),
        ),
        actions: [
          WaveButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    },
  );
}

class QueueBodyPublic extends ConsumerWidget {
  final bool embedded;
  const QueueBodyPublic({super.key, this.embedded = false});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return WaveQueuePanel(onClose: null, embedded: embedded);
  }
}
