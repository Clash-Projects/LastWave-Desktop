import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../design_system/icons.dart';

import '../../design_system/tokens.dart';
import '../player/playback_service.dart';

class _Command {
  final String label;
  final String hint;
  final IconData icon;
  final void Function(BuildContext, WidgetRef) run;
  const _Command(this.label, this.hint, this.icon, this.run);
}

/// Ctrl+K command palette: navigation + transport + toggles.
Future<void> showCommandPalette(
    BuildContext context, WidgetRef ref) {
  final player = ref.read(playbackServiceProvider);
  final notifier =
      ref.read(playbackServiceProvider.notifier);
  final commands = [
    _Command('Go to Home', 'Navigate', LwIcons.home,
        (c, _) => c.go('/home')),
    _Command('Go to Search', 'Navigate', LwIcons.search,
        (c, _) => c.go('/search')),
    _Command('Go to Library', 'Navigate', LwIcons.library,
        (c, _) => c.go('/library')),
    _Command('Go to Liked Songs', 'Navigate', LwIcons.heart,
        (c, _) => c.go('/liked')),
    _Command('Go to Mix Lab', 'Navigate', LwIcons.wand2,
        (c, _) => c.go('/mixes')),
    _Command('Go to Downloads', 'Navigate', LwIcons.download,
        (c, _) => c.go('/downloads')),
    _Command('Go to Now Playing', 'Navigate',
        LwIcons.maximize2, (c, _) => c.go('/now')),
    _Command('Go to Lyrics', 'Navigate', LwIcons.mic,
        (c, _) => c.go('/lyrics')),
    _Command('Go to Settings', 'Navigate', LwIcons.settings,
        (c, _) => c.go('/settings')),
    if (player.current != null) ...[
      _Command(
          player.isPlaying ? 'Pause' : 'Play',
          'Transport',
          player.isPlaying
              ? LwIcons.pause
              : LwIcons.play,
          (_, _) => notifier.toggle()),
      _Command('Next track', 'Transport', LwIcons.skipForward,
          (_, _) => notifier.next()),
      _Command('Previous track', 'Transport',
          LwIcons.skipBack, (_, _) => notifier.previous()),
      _Command('Toggle shuffle', 'Transport', LwIcons.shuffle,
          (_, _) => notifier.toggleShuffle()),
      _Command('Cycle repeat', 'Transport', LwIcons.repeat,
          (_, _) => notifier.cycleRepeat()),
    ],
  ];
  return showDialog(
    context: context,
    builder: (context) =>
        _PaletteDialog(commands: commands),
  );
}

class _PaletteDialog extends ConsumerStatefulWidget {
  final List<_Command> commands;
  const _PaletteDialog({required this.commands});
  @override
  ConsumerState<_PaletteDialog> createState() =>
      _PaletteDialogState();
}

class _PaletteDialogState
    extends ConsumerState<_PaletteDialog> {
  String _query = '';
  int _selected = 0;

  @override
  Widget build(BuildContext context) {
    final filtered = widget.commands
        .where((c) =>
            c.label.toLowerCase().contains(_query.toLowerCase()))
        .toList();
    if (_selected >= filtered.length) _selected = 0;
    return Dialog(
      backgroundColor: LwColors.surfaceRaised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LwRadius.lg),
        side: const BorderSide(color: LwColors.outline),
      ),
      child: SizedBox(
        width: 520,
        height: 420,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(LwSpacing.sm),
              child: TextField(
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Type a command or search…',
                  prefixIcon: Icon(LwIcons.search, size: 16),
                  border: InputBorder.none,
                ),
                style: LwType.body,
                onChanged: (v) => setState(() {
                  _query = v;
                  _selected = 0;
                }),
                onSubmitted: (_) {
                  if (filtered.isNotEmpty) {
                    Navigator.of(context).pop();
                    filtered[_selected.clamp(
                            0, filtered.length - 1)]
                        .run(context, ref);
                  }
                },
              ),
            ),
            const Divider(
                height: 1, color: LwColors.outlineSoft),
            Expanded(
              child: ListView.builder(
                itemCount: filtered.length,
                itemBuilder: (context, i) {
                  final c = filtered[i];
                  final selected = i == _selected;
                  return Material(
                    color: selected
                        ? Colors.white
                            .withValues(alpha: 0.07)
                        : Colors.transparent,
                    child: InkWell(
                      onTap: () {
                        Navigator.of(context).pop();
                        c.run(context, ref);
                      },
                      onHover: (_) =>
                          setState(() => _selected = i),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: LwSpacing.md,
                            vertical: 10),
                        child: Row(
                          children: [
                            Icon(c.icon,
                                size: 15,
                                color: LwColors.textSecondary),
                            const SizedBox(
                                width: LwSpacing.sm),
                            Expanded(
                                child: Text(c.label,
                                    style: LwType.body)),
                            Text(c.hint,
                                style: LwType.caption.copyWith(
                                    color: LwColors
                                        .textTertiary)),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
