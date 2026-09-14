import 'package:fluent_ui/fluent_ui.dart';

import '../theme/tokens.dart';
import 'buttons.dart' show LWTooltip, WaveGhostButton, WavePrimaryButton;

/// WinUI-inspired command surface for music collections.
///
/// Renders primary actions (Play / Shuffle / Download) as Fluent
/// buttons plus an overflow [DropDownButton] for secondary commands,
/// matching the spec: "icons, compact labels where useful, overflow
/// menu for secondary commands". Never giant cards — a single compact
/// row that wraps on narrow widths.
///
/// Usage:
/// ```dart
/// WaveCommandBar(
///   onPlay: ...,
///   onShuffle: ...,
///   onDownload: ...,
///   overflowItems: [...],
/// )
/// ```
class WaveCommandBar extends StatelessWidget {
  final VoidCallback? onPlay;
  final VoidCallback? onShuffle;
  final VoidCallback? onDownload;
  final String playLabel;
  final List<MenuFlyoutItemBase> overflowItems;
  final List<Widget> trailing;
  const WaveCommandBar({
    super.key,
    this.onPlay,
    this.onShuffle,
    this.onDownload,
    this.playLabel = 'Play',
    this.overflowItems = const [],
    this.trailing = const [],
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: WaveSpacing.x4,
      runSpacing: WaveSpacing.x4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (onPlay != null)
          WavePrimaryButton(
            label: playLabel,
            icon: FluentIcons.play,
            onPressed: onPlay,
          ),
        if (onShuffle != null)
          WaveGhostButton(
            label: 'Shuffle',
            icon: FluentIcons.switcher_start_end,
            onPressed: onShuffle,
          ),
        if (onDownload != null)
          WaveGhostButton(
            label: 'Download',
            icon: FluentIcons.download,
            onPressed: onDownload,
          ),
        if (overflowItems.isNotEmpty)
          LWTooltip(
            message: 'More actions',
            child: SizedBox(
              width: WaveDensity.hitArea,
              height: 32,
              child: DropDownButton(
                items: overflowItems,
                buttonBuilder: (context, onOpen) => Button(
                  onPressed: onOpen,
                  child: const Icon(FluentIcons.more, size: 14),
                ),
              ),
            ),
          ),
        ...trailing,
      ],
    );
  }
}

/// Compact library toolbar: sort + filter + view toggle slot.
///
/// Used by Library / Playlists / Albums / Artists headers so sort,
/// filter and view controls share one Fluent pattern instead of ad-hoc
/// DropDownButtons scattered per page.
class WaveLibraryToolbar extends StatelessWidget {
  final Widget? sortSlot;
  final Widget? viewSlot;
  final Widget? filterSlot;
  const WaveLibraryToolbar({
    super.key,
    this.sortSlot,
    this.viewSlot,
    this.filterSlot,
  });

  @override
  Widget build(BuildContext context) {
    if (sortSlot == null && viewSlot == null && filterSlot == null) {
      return const SizedBox.shrink();
    }
    return Row(
      children: [
        ?filterSlot,
        const Spacer(),
        if (sortSlot != null) ...[
          sortSlot!,
          if (viewSlot != null) const SizedBox(width: 8),
        ],
        ?viewSlot,
      ],
    );
  }
}
