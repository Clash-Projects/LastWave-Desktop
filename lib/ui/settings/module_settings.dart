import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/plugins/module_manager.dart';
import '../../l10n/app_language.dart';
import '../components/buttons.dart';
import '../theme/tokens.dart';
import 'settings_search.dart';

/// Settings → Sources: local `.lwp` modules beside HTTP addon URLs.
class ModuleSettings extends ConsumerWidget {
  const ModuleSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(shellStringsProvider);
    final modules = ref.watch(moduleListProvider);
    return SettingsTarget(
      id: 'sources.modules',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(strings('modules'), style: WaveType.sectionTitle),
          const SizedBox(height: 6),
          Text(
            strings('modulesHint'),
            style: WaveType.meta.copyWith(color: waveTextSecondary(context)),
          ),
          const SizedBox(height: 10),
          modules.when(
            loading: () => const ProgressRing(),
            error: (error, _) => Text('$error'),
            data: (list) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (list.isEmpty)
                  Text(
                    'No modules installed.',
                    style: WaveType.meta.copyWith(
                      color: waveTextTertiary(context),
                    ),
                  ),
                for (final module in list)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                module.manifest.name.isEmpty
                                    ? module.manifest.id
                                    : module.manifest.name,
                                style: WaveType.trackTitle,
                              ),
                              Text(
                                '${module.manifest.id} · ${module.manifest.version}',
                                style: WaveType.meta.copyWith(
                                  color: waveTextSecondary(context),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Text(strings('moduleEnabled')),
                        const SizedBox(width: 8),
                        ToggleSwitch(
                          checked: module.enabled,
                          onChanged: (value) async {
                            await ref
                                .read(moduleManagerProvider)
                                .setEnabled(module.manifest.id, value);
                            ref.invalidate(moduleListProvider);
                          },
                        ),
                        const SizedBox(width: 8),
                        WaveButton(
                          onPressed: () async {
                            await ref
                                .read(moduleManagerProvider)
                                .remove(module.manifest.id);
                            ref.invalidate(moduleListProvider);
                          },
                          child: Text(strings('moduleRemove')),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          WaveFilledButton(
            onPressed: () async {
              final picked = await FilePicker.pickFile(
                dialogTitle: strings('moduleInstall'),
                type: FileType.custom,
                allowedExtensions: const ['lwp'],
              );
              final path = picked?.path;
              if (path == null || path.isEmpty) return;
              final result =
                  await ref.read(moduleManagerProvider).installFile(path);
              ref.invalidate(moduleListProvider);
              if (!context.mounted) return;
              await showDialog<void>(
                context: context,
                builder: (context) => ContentDialog(
                  title: Text(
                    result.ok ? strings('moduleInstall') : strings('modules'),
                  ),
                  content: Text(
                    result.ok
                        ? (result.module?.manifest.name ?? 'Installed')
                        : result.error,
                  ),
                  actions: [
                    WaveFilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('OK'),
                    ),
                  ],
                ),
              );
            },
            child: Text(strings('moduleInstall')),
          ),
        ],
      ),
    );
  }
}
