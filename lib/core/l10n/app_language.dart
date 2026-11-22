import 'dart:ui';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/prefs.dart';

/// The 15 fully-localized languages of LastWave (parity with LastWave-Native)
/// plus System Default.
enum AppLanguage {
  system('system', 'System default', 'System default'),
  english('en', 'English', 'English'),
  turkish('tr', 'Turkish', 'Türkçe'),
  chineseSimplified('zh-CN', 'Chinese (Simplified)', '简体中文'),
  russian('ru', 'Russian', 'Русский'),
  portugueseBrazil('pt-BR', 'Portuguese (Brazil)', 'Português (Brasil)'),
  spanish('es', 'Spanish', 'Español'),
  indonesian('id', 'Indonesian', 'Bahasa Indonesia'),
  hindi('hi', 'Hindi', 'हिन्दी'),
  german('de', 'German', 'Deutsch'),
  french('fr', 'French', 'Français'),
  italian('it', 'Italian', 'Italiano'),
  japanese('ja', 'Japanese', '日本語'),
  korean('ko', 'Korean', '한국어'),
  arabic('ar', 'Arabic', 'العربية'),
  vietnamese('vi', 'Vietnamese', 'Tiếng Việt');

  final String tag;
  final String englishName;
  final String nativeDisplayName;

  const AppLanguage(this.tag, this.englishName, this.nativeDisplayName);

  /// Whether this language uses right-to-left script (Arabic).
  bool get isRtl => this == AppLanguage.arabic;

  /// Flutter locale corresponding to this language.
  /// Null for [AppLanguage.system] so Flutter automatically follows the OS locale.
  Locale? get locale => switch (this) {
        AppLanguage.system => null,
        AppLanguage.chineseSimplified => const Locale('zh', 'CN'),
        AppLanguage.portugueseBrazil => const Locale('pt', 'BR'),
        _ => Locale(tag),
      };

  /// The active effective [AppLanguage] resolved against the device locale if [system].
  /// Guaranteed to fall back to English if device locale lookup fails.
  AppLanguage get effectiveLanguage {
    if (this != AppLanguage.system) return this;
    try {
      final dev = PlatformDispatcher.instance.locale;
      final tagWithCountry = dev.countryCode != null && dev.countryCode!.isNotEmpty
          ? '${dev.languageCode}-${dev.countryCode}'
          : dev.languageCode;
      return fromTag(tagWithCountry);
    } catch (_) {
      return AppLanguage.english;
    }
  }

  /// InnerTube `hl` parameter mapped strictly from the Limusic supported whitelist.
  ///
  /// Limusic Innertube whitelist:
  /// `en, tr, zh-Hans, ru, pt-BR, es, id, de, fr, it, ja, ko, vi`.
  ///
  /// Non-Limusic languages (e.g. `hi`, `ar`) strictly fall back to `en` per requirement:
  /// "in innertube use only that languages which were listed in limusic".
  /// If anything fails, always returns original English US ('en') as fallback.
  String get innertubeHl {
    try {
      final effective = effectiveLanguage;
      return switch (effective) {
        AppLanguage.english => 'en',
        AppLanguage.turkish => 'tr',
        AppLanguage.chineseSimplified => 'zh-Hans',
        AppLanguage.russian => 'ru',
        AppLanguage.portugueseBrazil => 'pt-BR',
        AppLanguage.spanish => 'es',
        AppLanguage.indonesian => 'id',
        AppLanguage.german => 'de',
        AppLanguage.french => 'fr',
        AppLanguage.italian => 'it',
        AppLanguage.japanese => 'ja',
        AppLanguage.korean => 'ko',
        AppLanguage.vietnamese => 'vi',
        // Explicit fallback for non-Limusic languages or unsupported
        _ => 'en',
      };
    } catch (_) {
      return 'en';
    }
  }

  /// Normalizes any tag to a supported [AppLanguage].
  static AppLanguage fromTag(String? raw) {
    if (raw == null || raw.trim().isEmpty) return AppLanguage.system;
    final cleaned = raw.trim().replaceAll('_', '-');
    for (final e in values) {
      if (e.tag.toLowerCase() == cleaned.toLowerCase()) return e;
    }
    switch (cleaned.toLowerCase()) {
      case 'zh-hans':
      case 'zh-cn':
      case 'zh-sg':
      case 'zh':
        return AppLanguage.chineseSimplified;
      case 'in':
        return AppLanguage.indonesian;
      case 'pt':
      case 'pt-pt':
        return AppLanguage.portugueseBrazil;
    }
    final base = cleaned.split('-').first.toLowerCase();
    for (final e in values) {
      if (e.tag.toLowerCase() == base) return e;
    }
    return AppLanguage.system;
  }

  static const List<Locale> supportedLocales = [
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
    Locale('vi'),
  ];
}

/// Reactive provider for the active [AppLanguage].
final appLanguageProvider =
    StateNotifierProvider<AppLanguageNotifier, AppLanguage>((ref) {
  final prefs = ref.watch(prefsProvider);
  return AppLanguageNotifier(prefs);
});

class AppLanguageNotifier extends StateNotifier<AppLanguage> {
  final Prefs _prefs;
  AppLanguageNotifier(this._prefs)
      : super(AppLanguage.fromTag(_prefs.appLanguageTag));

  Future<void> setLanguage(AppLanguage language) async {
    if (state == language) return;
    state = language;
    await _prefs.setAppLanguageTag(language.tag);
  }
}
