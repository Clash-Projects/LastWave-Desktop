import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/feed/home_shelf_layout.dart';
import '../components/buttons.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

/// Reorder and hide the Home shelves. Order and the hidden set live in
/// SQLite `kv_store` (`home_shelf_layout`), not Prefs.
class WaveHomeLayoutPage extends ConsumerWidget {
  const WaveHomeLayoutPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final layout = ref.watch(homeShelfLayoutProvider);
    final notifier = ref.read(homeShelfLayoutProvider.notifier);
    final order = layout.order;
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 22, 28, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Edit home', style: WaveType.pageTitle.copyWith(fontSize: 24)),
          const SizedBox(height: 4),
          Text(
            'Show, hide, and reorder shelves. Reset restores the default order.',
            style: WaveType.meta.copyWith(color: waveTextSecondary(context)),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              WaveGhostButton(
                label: 'Reset',
                icon: WaveIcons.history,
                onPressed: notifier.reset,
              ),
              WavePrimaryButton(
                label: 'Done',
                icon: WaveIcons.back,
                onPressed: () => context.go('/home'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ReorderableListView.builder(
              buildDefaultDragHandles: false,
              itemCount: order.length,
              onReorderItem: notifier.reorder,
              itemBuilder: (context, index) {
                final id = order[index];
                final shown = !layout.hidden.contains(id);
                return ListTile(
                  key: ValueKey(id),
                  leading: ReorderableDragStartListener(
                    index: index,
                    child: const Padding(
                      padding: EdgeInsets.all(6),
                      child: Icon(FluentIcons.gripper_dots_vertical, size: 16),
                    ),
                  ),
                  title: Text(
                    HomeShelfCatalog.label(id),
                    style: WaveType.body.copyWith(
                      color: shown
                          ? null
                          : waveTextTertiary(context),
                    ),
                  ),
                  trailing: ToggleSwitch(
                    checked: shown,
                    onChanged: (_) => notifier.toggle(id),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
