import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/audio/stream_models.dart';
import '../../features/downloads/download_manager.dart';
import '../../features/library/playlists.dart';
import '../../features/player/playback_service.dart';
import '../theme/tokens.dart';
import 'buttons.dart' show LWTooltip;

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

/// Single Fluent menu source for every track row / card / hero.
///
/// Replaces the old Material popup-menu items: one builder produces
/// Fluent [MenuFlyoutItemBase] lists consumed by DropDownButton and by
/// right-click GestureDetector flyouts.
List<MenuFlyoutItemBase> waveTrackMenuItems({
  required WidgetRef ref,
  required String title,
  required String artist,
  String artworkUrl = '',
  String videoId = '',
  PlayableTrack? playable,
  String? removeLabel,
  VoidCallback? onRemove,
}) {
  final player = ref.read(playbackServiceProvider.notifier);
  final track = playable ??
      PlayableTrack(
        title: title,
        artist: artist,
        artworkUrl: artworkUrl,
        videoId: videoId,
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
      );

  final items = <MenuFlyoutItemBase>[
    MenuFlyoutItem(
      leading: const Icon(FluentIcons.play, size: 15),
      text: const Text('Play'),
      trailing: const Text('Enter',
          style: TextStyle(fontSize: 11)),
      onPressed: () =>
          player.play(track, sourceLabel: 'Context menu'),
    ),
    MenuFlyoutItem(
      leading: const Icon(FluentIcons.add, size: 15),
      text: const Text('Play next'),
      onPressed: () => player.playNext(track),
    ),
    MenuFlyoutItem(
      leading: const Icon(FluentIcons.list, size: 15),
      text: const Text('Add to queue'),
      onPressed: () => player.addToQueue(track),
    ),
    const MenuFlyoutSeparator(),
    MenuFlyoutItem(
      leading: Icon(
        liked ? FluentIcons.heart_fill : FluentIcons.heart,
        size: 15,
      ),
      text: Text(liked ? 'Unlike' : 'Like'),
      onPressed: () => library.toggleLiked(stored()),
    ),
    MenuFlyoutItem(
      leading: const Icon(FluentIcons.download, size: 15),
      text: const Text('Download'),
      trailing: const Text('Ctrl+D',
          style: TextStyle(fontSize: 11)),
      onPressed: () => downloads.downloadTrack(
        title: title,
        artist: artist,
        artworkUrl: artworkUrl,
      ),
    ),
  ];
  if (playlists.isNotEmpty) {
    items.add(
      MenuFlyoutSubItem(
        leading: const Icon(FluentIcons.list_mirrored, size: 15),
        text: const Text('Add to playlist'),
        items: (context) => [
          for (final p in playlists)
            MenuFlyoutItem(
              leading: Icon(
                p.isLikedSongs
                    ? FluentIcons.heart
                    : FluentIcons.list_mirrored,
                size: 15,
              ),
              text: Text(p.title),
              onPressed: () => library.addTrack(p.id, stored()),
            ),
        ],
      ),
    );
  }
  items.add(const MenuFlyoutSeparator());
  items.add(
    MenuFlyoutItem(
      leading: const Icon(FluentIcons.album, size: 15),
      text: const Text('Go to album'),
      onPressed: () => ref.context.go(
          '/search?q=${Uri.encodeComponent(track.album.isNotEmpty ? track.album : title)}'),
    ),
  );
  items.add(
    MenuFlyoutItem(
      leading: const Icon(FluentIcons.microphone, size: 15),
      text: const Text('Go to artist'),
      onPressed: () => ref.context
          .go('/artist/${Uri.encodeComponent(artist)}'),
    ),
  );
  items.add(const MenuFlyoutSeparator());
  items.add(
    MenuFlyoutItem(
      leading: const Icon(FluentIcons.info, size: 15),
      text: const Text('Properties'),
      onPressed: () => showWaveTrackProperties(
        ref.context,
        title: title,
        artist: artist,
        artworkUrl: artworkUrl,
      ),
    ),
  );
  if (removeLabel != null && onRemove != null) {
    items.add(const MenuFlyoutSeparator());
    items.add(
      MenuFlyoutItem(
        leading: const Icon(FluentIcons.delete, size: 15),
        text: Text(removeLabel),
        trailing: const Text('Del',
            style: TextStyle(fontSize: 11)),
        onPressed: onRemove,
      ),
    );
  }
  return items;
}

/// Track properties dialog (Fluent ContentDialog).
Future<void> showWaveTrackProperties(
  BuildContext context, {
  required String title,
  required String artist,
  String artworkUrl = '',
}) {
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
            Text(title, style: WaveType.trackTitle),
            const SizedBox(height: 4),
            Text(artist, style: WaveType.body),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

/// Right-click region that opens a Fluent menu flyout at the cursor.
class WaveContextMenu extends StatefulWidget {
  final List<MenuFlyoutItemBase> Function() items;
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
      builder: (context) => MenuFlyout(
        items: widget.items(),
        shape: RoundedRectangleBorder(
          borderRadius: WaveRadius.menuRadius,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FlyoutTarget(
      controller: _controller,
      child: GestureDetector(
        onSecondaryTapDown: (_) => _open(),
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

/// Overflow button backed by a Fluent drop-down flyout.
class WaveOverflowButton extends StatelessWidget {
  final String tooltip;
  final List<MenuFlyoutItemBase> items;
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
      child: DropDownButton(
        placement: FlyoutPlacementMode.bottomRight,
        items: items,
        buttonBuilder: (context, onOpen) => SizedBox(
          width: WaveDensity.hitArea,
          height: WaveDensity.hitArea,
          child: IconButton(
            icon: Icon(
              icon,
              size: 15,
              color: dark
                  ? WaveColors.textSecondary
                  : WaveColors.lightTextSecondary,
            ),
            onPressed: onOpen,
          ),
        ),
      ),
    );
  }
}

/// Add-to-playlist picker dialog (Fluent ContentDialog).
Future<void> showWaveAddToPlaylist(
  BuildContext context,
  WidgetRef ref, {
  required String title,
  required String artist,
  String artworkUrl = '',
  String videoId = '',
}) async {
  final playlists = ref.read(playlistRepositoryProvider);
  if (playlists.isEmpty) return;
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
            for (final p in playlists)
              ListTile.selectable(
                title: Text(p.title),
                subtitle: Text('${p.tracks.length} tracks'),
                leading: Icon(
                  p.isLikedSongs
                      ? FluentIcons.heart
                      : FluentIcons.list_mirrored,
                  size: 15,
                ),
                selectionMode: ListTileSelectionMode.single,
                selected: false,
                onPressed: () =>
                    Navigator.of(context).pop(p.id),
              ),
          ],
        ),
      ),
      actions: [
        Button(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
  if (selected != null) {
    await ref.read(playlistRepositoryProvider.notifier).addTrack(
          selected,
          StoredTrack(
            name: title,
            artist: artist,
            artworkUrl: artworkUrl,
            videoId: videoId,
          ),
        );
  }
}

/// Like toggle helper for the new layer (no legacy toast host).
Future<bool> waveToggleLike(
  WidgetRef ref, {
  required String title,
  required String artist,
  String artworkUrl = '',
  String videoId = '',
}) {
  return ref.read(playlistRepositoryProvider.notifier).toggleLiked(
        StoredTrack(
          name: title,
          artist: artist,
          artworkUrl: artworkUrl,
          videoId: videoId,
        ),
      );
}
