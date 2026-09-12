import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../design_system/icons.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../design_system/components.dart';
import '../../design_system/tokens.dart';
import '../player/playback_service.dart';
import '../lyrics/lyrics_view.dart';

/// Right-side contextual panel: Queue / Lyrics tabs (wide layout).
/// On smaller windows the same content opens as a side sheet.
class QueuePanel extends ConsumerStatefulWidget {
  const QueuePanel({super.key});
  @override
  ConsumerState<QueuePanel> createState() => _QueuePanelState();
}

class _QueuePanelState extends ConsumerState<QueuePanel>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final ItemScrollController _queueScroll =
      ItemScrollController();

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(playbackServiceProvider);
    final current = player.current;
    return Container(
      decoration: const BoxDecoration(
        color: LwColors.surface,
        border: Border(
            left: BorderSide(color: LwColors.outlineSoft)),
      ),
      child: Column(
        children: [
          TabBar(
            controller: _tabs,
            labelStyle: LwType.label,
            unselectedLabelColor: LwColors.textTertiary,
            labelColor: LwColors.textPrimary,
            indicatorColor:
                Theme.of(context).colorScheme.primary,
            indicatorSize: TabBarIndicatorSize.label,
            tabs: const [
              Tab(text: 'Queue'),
              Tab(text: 'Lyrics'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _QueueList(
                  scroll: _queueScroll,
                  onJumpToLyrics: () => _tabs.animateTo(1),
                ),
                current == null
                    ? const EmptyState(
                        icon: LwIcons.mic,
                        title: 'Nothing playing',
                        subtitle:
                            'Play something to see lyrics.',
                      )
                    : LyricsColumn(
                        key: ValueKey(current.queueKey),
                        track: current,
                      ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _QueueList extends ConsumerWidget {
  final ItemScrollController scroll;
  final VoidCallback onJumpToLyrics;
  const _QueueList({
    required this.scroll,
    required this.onJumpToLyrics,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playbackServiceProvider);
    final notifier =
        ref.read(playbackServiceProvider.notifier);
    final queue = player.queue;
    if (queue.isEmpty) {
      return const EmptyState(
        icon: LwIcons.listVideo,
        title: 'Queue is empty',
        subtitle: 'Search for music and press play.',
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scroll.isAttached &&
          player.currentIndex >= 0 &&
          player.currentIndex < queue.length) {
        scroll.jumpTo(index: player.currentIndex);
      }
    });
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: LwSpacing.md,
              vertical: LwSpacing.xs),
          child: Row(
            children: [
              Text('${queue.length} tracks',
                  style: LwType.caption.copyWith(
                      color: LwColors.textTertiary)),
              const Spacer(),
              TextButton(
                onPressed: notifier.clearUpcoming,
                style: TextButton.styleFrom(
                  foregroundColor: LwColors.textSecondary,
                  textStyle: LwType.label,
                  minimumSize: Size.zero,
                  tapTargetSize:
                      MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('Clear upcoming'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ScrollablePositionedList.builder(
            itemScrollController: scroll,
            itemCount: queue.length,
            itemBuilder: (context, i) {
              final t = queue[i];
              final isCurrent = i == player.currentIndex;
              return TrackTile(
                title: t.title,
                subtitle: t.artist,
                artworkUrl: t.artworkUrl,
                playing: isCurrent,
                onTap: () => notifier.seekToQueueItem(i),
                onMore: () => _queueItemMenu(
                    context, ref, i, isCurrent),
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _queueItemMenu(BuildContext context,
      WidgetRef ref, int index, bool isCurrent) async {
    final notifier =
        ref.read(playbackServiceProvider.notifier);
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(1000, 200, 0, 0),
      items: const [
        PopupMenuItem(
            value: 'play', child: Text('Play now')),
        PopupMenuItem(
            value: 'remove',
            child: Text('Remove from queue')),
      ],
    );
    if (choice == 'play') {
      await notifier.seekToQueueItem(index);
    } else if (choice == 'remove' && !isCurrent) {
      await notifier.removeAt(index);
    }
  }
}

Future<void> showQueueSheet(BuildContext context) {
  return showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Queue',
    pageBuilder: (context, _, _) => Align(
      alignment: Alignment.centerRight,
      child: Material(
        color: LwColors.surface,
        child: SizedBox(
          width: 360,
          height: double.infinity,
          child: SafeArea(child: const QueuePanel()),
        ),
      ),
    ),
    transitionBuilder: (context, anim, _, child) =>
        SlideTransition(
      position: Tween(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(
          parent: anim, curve: LwMotion.emphasized)),
      child: child,
    ),
  );
}
