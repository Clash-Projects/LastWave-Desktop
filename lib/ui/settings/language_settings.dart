import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/prefs.dart';
import '../../l10n/app_language.dart';
import '../components/select.dart';
import '../theme/tokens.dart';
import 'settings_search.dart';

/// Settings → General language dropdown.
class LanguageSettings extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const LanguageSettings({super.key, required this.onUpdate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(shellStringsProvider);
    final tag = ref.watch(appLanguageTagProvider);
    final current = AppLanguage.fromTag(tag);
    return SettingsTarget(
      id: 'general.language',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(strings('language'), style: WaveType.sectionTitle),
          const SizedBox(height: 6),
          WaveSelect<AppLanguage>(
            expanded: true,
            value: current,
            options: [
              for (final language in AppLanguage.selectable)
                WaveSelectOption(
                  value: language,
                  label: language.nativeName,
                ),
            ],
            onChanged: (language) async {
              await onUpdate((p) => p.setAppLanguageTag(language.tag));
              ref.read(appLanguageTagProvider.notifier).state = language.tag;
            },
          ),
          const SizedBox(height: 6),
          Text(
            strings('languageHint'),
            style: WaveType.meta.copyWith(color: waveTextSecondary(context)),
          ),
        ],
      ),
    );
  }
}
