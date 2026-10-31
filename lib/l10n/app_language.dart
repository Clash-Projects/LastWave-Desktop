import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/storage/prefs.dart';
import 'shell_strings.dart';

/// In-app language. Tags match Android `AppLanguage`.
enum AppLanguage {
  system('system'),
  english('en'),
  turkish('tr'),
  chineseSimplified('zh-CN'),
  russian('ru'),
  portugueseBrazil('pt-BR'),
  spanish('es'),
  indonesian('id'),
  hindi('hi'),
  german('de'),
  french('fr'),
  italian('it'),
  japanese('ja'),
  korean('ko'),
  arabic('ar');

  final String tag;
  const AppLanguage(this.tag);

  /// Native name. Not translated — a reader looks for their own script.
  String get nativeName => switch (this) {
        AppLanguage.system => 'System default',
        AppLanguage.english => 'English',
        AppLanguage.turkish => 'Türkçe',
        AppLanguage.chineseSimplified => '简体中文',
        AppLanguage.russian => 'Русский',
        AppLanguage.portugueseBrazil => 'Português (Brasil)',
        AppLanguage.spanish => 'Español',
        AppLanguage.indonesian => 'Bahasa Indonesia',
        AppLanguage.hindi => 'हिन्दी',
        AppLanguage.german => 'Deutsch',
        AppLanguage.french => 'Français',
        AppLanguage.italian => 'Italiano',
        AppLanguage.japanese => '日本語',
        AppLanguage.korean => '한국어',
        AppLanguage.arabic => 'العربية',
      };

  /// Null follows the platform locale.
  Locale? get flutterLocale => switch (this) {
        AppLanguage.system => null,
        AppLanguage.english => const Locale('en'),
        AppLanguage.turkish => const Locale('tr'),
        AppLanguage.chineseSimplified => const Locale('zh', 'CN'),
        AppLanguage.russian => const Locale('ru'),
        AppLanguage.portugueseBrazil => const Locale('pt', 'BR'),
        AppLanguage.spanish => const Locale('es'),
        AppLanguage.indonesian => const Locale('id'),
        AppLanguage.hindi => const Locale('hi'),
        AppLanguage.german => const Locale('de'),
        AppLanguage.french => const Locale('fr'),
        AppLanguage.italian => const Locale('it'),
        AppLanguage.japanese => const Locale('ja'),
        AppLanguage.korean => const Locale('ko'),
        AppLanguage.arabic => const Locale('ar'),
      };

  static const selectable = AppLanguage.values;

  static const supportedLocales = <Locale>[
    Locale('en'),
    Locale('tr'),
    Locale('zh', 'CN'),
    Locale('ru'),
    Locale('pt', 'BR'),
    Locale('es'),
    Locale('id'),
    Locale('hi'),
    Locale('de'),
    Locale('fr'),
    Locale('it'),
    Locale('ja'),
    Locale('ko'),
    Locale('ar'),
  ];

  static AppLanguage fromTag(String? raw) {
    if (raw == null || raw.trim().isEmpty) return AppLanguage.system;
    final cleaned = raw.trim().replaceAll('_', '-');
    for (final lang in AppLanguage.values) {
      if (lang.tag.toLowerCase() == cleaned.toLowerCase()) return lang;
    }
    switch (cleaned.toLowerCase()) {
      case 'zh-hans':
      case 'zh-cn':
      case 'zh-sg':
        return AppLanguage.chineseSimplified;
      case 'in':
        return AppLanguage.indonesian;
      case 'zh-hant':
      case 'zh-tw':
      case 'zh-hk':
      case 'zh-mo':
      case 'iw':
      case 'he':
      case 'ji':
      case 'yi':
        return AppLanguage.system;
    }
    final base = cleaned.split('-').first.toLowerCase();
    for (final lang in AppLanguage.values) {
      if (lang.tag.toLowerCase() == base) return lang;
    }
    if (base == 'pt') return AppLanguage.portugueseBrazil;
    if (base == 'zh') return AppLanguage.chineseSimplified;
    return AppLanguage.system;
  }
}

/// Live tag. Settings writes this after prefs so the shell rebuilds
/// without waiting for a process restart.
final appLanguageTagProvider = StateProvider<String>((ref) {
  return ref.read(prefsProvider).appLanguageTag;
});

final shellStringsProvider = Provider<ShellStrings>((ref) {
  final tag = ref.watch(appLanguageTagProvider);
  final platform = WidgetsBinding.instance.platformDispatcher.locale;
  return ShellStrings.resolve(AppLanguage.fromTag(tag), platform);
});
