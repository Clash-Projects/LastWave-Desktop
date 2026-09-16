import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../theme/wave_icons.dart';

import '../../core/audio/stream_models.dart';
import '../../features/downloads/download_manager.dart';
import '../../features/player/playback_service.dart';
import '../components/artwork.dart';
import '../components/buttons.dart' show LWTooltip;
import '../components/menus.dart';
import '../theme/haze.dart';
import '../theme/tokens.dart';

/// Contextual queue — slides from right, 360px, disappears fully.
///
/// Header: Queue 18px + UP NEXT count + Clear. NOW PLAYING 44px accent row.
/// Reorderable 48px rows: drag handle visible on hover but always
/// accessible (low-opacity idle), hover X remove, right-click menu
/// (Play next, Go to album/artist, Download, Add to playlist, Remove).
class WaveQueuePanel extends ConsumerWidget {
  final VoidCallback? onClose;
  final bool embedded;
  const WaveQueuePanel({super.key, required this.onClose, this.embedded = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = waveIsDark(context);
    final queue = ref.watch(
      playbackServiceProvider.select((s) => s.queue),
    );
    final index = ref.watch(
      playbackServiceProvider.select((s) => s.currentIndex),
    );
    final notifier = ref.read(playbackServiceProvider.notifier);
    if (queue.isEmpty) {
      return _Shell(
        onClose: onClose,
        embedded: embedded,
        child: WaveQueueEmpty(onBrowse: () => context.go('/home')),
      );
    }
    final current =
        index >= 0 && index < queue.length ? queue[index] : null;
    final upcoming = index >= 0
        ? queue.sublist((index + 1).clamp(0, queue.length))
        : queue;

    return _Shell(
      onClose: onClose,
      embedded: embedded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
            child: Text('Queue',
                style: WaveType.pageTitle.copyWith(fontSize: 18)),
          ),
          if (current != null) ...[
            const SizedBox(height: 10),
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
            const SizedBox(height: 6),
            _NowRow(track: current, queueIndex: index),
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 10),
              child: Container(height: 1, color: waveDivider(context)),
            ),
          ],
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Text(
                  'UP NEXT · ${upcoming.length}',
                  style: WaveType.overline.copyWith(
                    fontSize: 9,
                    color: dark
                        ? WaveColors.textTertiary
                        : WaveColors.lightTextTertiary,
                  ),
                ),
                const Spacer(),
                LWTooltip(
                  message: upcoming.isEmpty
                      ? 'Nothing to clear'
                      : 'Clear up next',
                  child: HyperlinkButton(
                    onPressed: upcoming.isEmpty
                        ? null
                        : notifier.clearUpcoming,
                    child: Text(
                      'Clear',
                      style: WaveType.label.copyWith(fontSize: 11),
                    ),
                  ),
                ),
              ],
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

class WaveQueueEmpty extends StatelessWidget {
  final VoidCallback onBrowse;
  const WaveQueueEmpty({super.key, required this.onBrowse});
  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: dark
                    ? WaveColors.surfaceOverlay
                    : WaveColors.lightOverlay,
                border: Border.all(
                  color: dark
                      ? WaveColors.outlineSoft
                      : WaveColors.lightOutline,
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
            FilledButton(
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
  final VoidCallback? onClose;
  final Widget child;
  final bool embedded;
  const _Shell({required this.onClose, required this.child, this.embedded = false});
  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    // Haze Level 2 — contextual panel translucency; rows stay crisp
    // (no per-row blur, bounded 360px region only).
    final body = Column(
      children: [
        if (!embedded)
          Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding: const EdgeInsets.only(top: 8, right: 8),
              child: _CloseGlyph(onTap: onClose ?? () {}),
            ),
          ),
        Expanded(child: child),
      ],
    );
    if (embedded) return body;
    return WaveHaze(
      level: LwHazeLevel.l2,
      base: dark ? WaveColors.background : WaveColors.lightBackground,
      border: Border(left: BorderSide(color: waveDivider(context))),
      shadow: const [
        BoxShadow(
          color: Color(0x73000000),
          blurRadius: 32,
          offset: Offset(-12, 0),
        ),
      ],
      child: SizedBox(
        width: WaveDensity.contextPanel,
        child: body,
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
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: _hover
                  ? (waveIsDark(context)
                          ? const Color(0xFFFFFFFF)
                          : const Color(0xFF000000))
                      .withValues(alpha: WaveState.hoverAlpha)
                  : Colors.transparent,
              borderRadius:
                  BorderRadius.circular(WaveRadius.controls),
            ),
            child: Icon(
              FluentIcons.chrome_close,
              size: 12,
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
  const _QueueRow({
    super.key,
    required this.track,
    required this.queueIndex,
    required this.dragIndex,
  });
  @override
  ConsumerState<_QueueRow> createState() => _QueueRowState();
}

class _QueueRowState extends ConsumerState<_QueueRow> {
  bool _hover = false;

  List<MenuFlyoutItemBase> _menuItems(WidgetRef ref) {
    final notifier = ref.read(playbackServiceProvider.notifier);
    final t = widget.track;
    return [
      MenuFlyoutItem(
        leading: const Icon(WaveIcons.queue, size: 15),
        text: const Text('Play next'),
        onPressed: () => notifier.playNext(t),
      ),
      MenuFlyoutItem(
        leading: const Icon(WaveIcons.albums, size: 15),
        text: const Text('Go to album'),
        onPressed: t.album.isEmpty
            ? null
            : () => context.go(
                '/search?q=${Uri.encodeComponent(t.album)}'),
      ),
      MenuFlyoutItem(
        leading: const Icon(WaveIcons.artists, size: 15),
        text: const Text('Go to artist'),
        onPressed: () => context.go(
            '/artist/${Uri.encodeComponent(t.artist)}'),
      ),
      const MenuFlyoutSeparator(),
      MenuFlyoutItem(
        leading: const Icon(WaveIcons.downloadAction, size: 15),
        text: const Text('Download'),
        onPressed: () => ref
            .read(downloadManagerProvider.notifier)
            .downloadTrack(
              title: t.title,
              artist: t.artist,
              album: t.album,
              artworkUrl: t.artworkUrl,
            ),
      ),
      MenuFlyoutItem(
        leading: const Icon(WaveIcons.addTo, size: 15),
        text: const Text('Add to playlist'),
        onPressed: () => showWaveAddToPlaylist(context, ref,
            title: t.title,
            artist: t.artist,
            artworkUrl: t.artworkUrl,
            videoId: t.videoId),
      ),
      const MenuFlyoutSeparator(),
      MenuFlyoutItem(
        leading: const Icon(WaveIcons.delete, size: 15),
        text: const Text('Remove'),
        onPressed: () => notifier.removeAt(widget.queueIndex),
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
        onTap: () => notifier.seekToQueueItem(widget.queueIndex),
        onDoubleTap: () => notifier.seekToQueueItem(widget.queueIndex),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          color: _hover
              ? (dark ? Colors.white : Colors.black)
                  .withValues(alpha: WaveState.hoverAlpha)
              : Colors.transparent,
          child: Row(
            children: [
              // Drag handle: low-opacity idle (still visible/keyboard
              // reachable) → full opacity on hover.
              LWTooltip(
                message: 'Drag to reorder',
                child: ReorderableDragStartListener(
                  index: widget.dragIndex,
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
              if (_hover)
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
          Button(
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


